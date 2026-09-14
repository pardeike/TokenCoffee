import CryptoKit
import Foundation

public struct LinkedUsageAccount: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let provider: String
    public let name: String
    public let email: String?
    public let plan: String?
    public let values: [LinkedUsageValue]
    public let cloudKey: String
    public let usesLegacyHistory: Bool
    public var requiresSignIn: Bool = false
}

public struct LinkedUsageDiagram: Identifiable, Sendable {
    public let accountID: UUID
    public let scopeID: String
    public let title: String
    public let snapshot: RateLimitSnapshot
    public let samples: [QuotaSample]
    public let capturedAt: Date
    public var syncMessage: String? = nil
    public var id: String { accountID.uuidString + ":" + scopeID }
}

/// Reads already-linked accounts. Official Claude credentials have exactly one
/// refresh owner; this service never rotates them or reads a default CLI profile.
public actor LinkedUsageService {
    private let root: URL
    private var registry: AccountRegistry
    private let secrets: any LinkedAccountSecrets
    private let http: any CodexHTTPClient
    private let historySync: (any LinkedHistorySync)?
    private var busy = false
    private var pending: PendingLogin?
    private struct PendingLogin {
        let id: UUID
        let target: ProbeAccount?
        let provider: ProbeAccount.Provider
        let codex: CodexNativeDeviceCode?
        let claude: ClaudeAccountOAuth.Pending?
    }

    public init(root: URL, historySync: (any LinkedHistorySync)? = nil) throws {
        try self.init(root: root, secrets: LinkedAccountKeychain(), http: LinkedAccountHTTP(), historySync: historySync)
    }

    init(root: URL, secrets: any LinkedAccountSecrets, http: any CodexHTTPClient, historySync: (any LinkedHistorySync)? = nil) throws {
        self.root = root
        self.secrets = secrets
        self.http = http
        self.historySync = historySync
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let registryURL = root.appendingPathComponent("accounts.json")
        if FileManager.default.fileExists(atPath: registryURL.path) {
            registry = try JSONDecoder().decode(AccountRegistry.self, from: Data(contentsOf: registryURL))
        } else {
            registry = AccountRegistry()
            try registry.saving(to: registryURL)
        }
        try registry.validate()
        let original = registry
        // Recover names from our own account-partitioned history, even when the
        // original predictors were removed and the current credential expired.
        for index in registry.accounts.indices where registry.accounts[index].knownValues == nil {
            let account = registry.accounts[index]
            let directory = root.appendingPathComponent("diagram-history").appendingPathComponent(account.id.uuidString)
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            var values: [LinkedUsageValue] = []
            for file in files where file.pathExtension == "jsonl" {
                guard let sample = try? QuotaSampleStore(fileURL: file).load().last else { continue }
                let scope = account.provider == .codex ? "general" : sample.limitId
                let title = account.provider == .codex ? "General" : sample.limitName ?? scope
                let hash = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
                guard file.deletingPathExtension().lastPathComponent == hash,
                      !values.contains(where: { $0.scopeID == scope }) else { continue }
                values.append(LinkedUsageValue(scopeID: scope, title: title))
            }
            if !values.isEmpty { registry.accounts[index].knownValues = Self.sortedValues(values) }
        }
        if registry != original { try registry.saving(to: root.appendingPathComponent("accounts.json")) }
    }

    public func accounts() -> [LinkedUsageAccount] {
        registry.accounts.map { LinkedUsageAccount(id: $0.id, provider: $0.provider.rawValue, name: $0.name,
            email: $0.email, plan: $0.plan, values: $0.knownValues ?? [],
            cloudKey: Self.hash($0.provider.rawValue + ":" + ($0.identity ?? $0.id.uuidString)),
            usesLegacyHistory: $0.id == registry.legacyCodexID, requiresSignIn: $0.requiresSignIn == true) }
    }

    public func maintenanceMessage() -> String? {
        (registry.credentialCleanup ?? []).isEmpty ? nil
            : "The account change is saved, but an inactive Keychain credential still needs cleanup. TokenCoffee will retry before the next account operation."
    }

    public func rename(_ id: UUID, to name: String) throws -> [LinkedUsageAccount] {
        guard !busy, pending == nil else { throw LinkedAccountError.busy }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 60, !clean.contains(where: { $0.isNewline }) else {
            throw NativeUsage.Failure(diagnostic: "invalid_account_name")
        }
        let url = root.appendingPathComponent("accounts.json")
        var latest = try JSONDecoder().decode(AccountRegistry.self, from: Data(contentsOf: url))
        try latest.validate()
        guard let index = latest.accounts.firstIndex(where: { $0.id == id }),
              let original = registry.accounts.first(where: { $0.id == id }),
              latest.accounts[index].identity == original.identity,
              latest.accounts[index].provider == original.provider else {
            throw NativeUsage.Failure(diagnostic: "account_identity_changed")
        }
        latest.accounts[index].name = clean
        try latest.saving(to: url)
        registry = latest
        return accounts()
    }

    public func refresh(_ id: UUID) async throws -> [LinkedUsageDiagram] {
        guard !busy, pending == nil else { throw LinkedAccountError.busy }
        busy = true
        defer { busy = false }
        try? cleanupCredentials()
        guard let account = registry.accounts.first(where: { $0.id == id }), let identity = account.identity else {
            throw NativeUsage.Failure(diagnostic: "account_identity_unavailable")
        }
        let snapshots: [(String, String, RateLimitSnapshot)]
        guard account.requiresSignIn != true else { throw LinkedAccountError.signInRequired }
        switch account.provider {
        case .claude:
            if let reference = account.credentialReference {
                guard let data = try secrets.read(reference),
                      var credential = try? JSONDecoder().decode(ClaudeAccountCredential.self, from: data) else {
                    throw LinkedAccountError.signInRequired
                }
                let oauth = ClaudeAccountOAuth(http: http)
                var renewed = false
                if credential.needsRefresh {
                    credential = try await oauth.refresh(credential)
                    // Persist rotating refresh tokens immediately, before another
                    // network request can fail. Only this actor owns this grant.
                    try secrets.write(JSONEncoder().encode(credential), for: reference)
                    renewed = true
                }
                func read(_ credential: ClaudeAccountCredential) async throws -> ClaudeUsageReading {
                    let profile = try await oauth.profile(credential)
                    guard profile.identity == identity else { throw LinkedAccountError.wrongAccount }
                    return try await oauth.usage(credential)
                }
                let reading: ClaudeUsageReading
                do { reading = try await read(credential) }
                catch LinkedAccountError.http(401) where !renewed {
                    credential = try await oauth.refresh(credential)
                    try secrets.write(JSONEncoder().encode(credential), for: reference)
                    reading = try await read(credential)
                }
                snapshots = Self.claudeSnapshots(reading, plan: account.plan)
                break
            }
            guard let directory = account.claudeDirectory else {
                throw NativeUsage.Failure(diagnostic: "invalid_private_profile")
            }
            let profile = root.appendingPathComponent(directory.uuidString).appendingPathComponent("claude-account-a")
            let (_, reading, _) = try await NativeUsage.fetchDiagrams(profilePath: profile.path, expectedIdentity: identity)
            snapshots = Self.claudeSnapshots(reading, plan: account.plan)
        case .codex:
            let client = CodexRateLimitClient(configuration: .defaultConfiguration(), httpClient: http,
                tokenStore: ManagedCodexTokens(reference: account.credentialReference!, identity: identity, secrets: secrets))
            let reading = try await client.fetch().response.codexSnapshot
            snapshots = [("general", "General", try Self.normalizeCodex(reading))]
        }
        var updated = account
        var values = account.knownValues ?? []
        for (scope, title, _) in snapshots {
            values.removeAll { $0.scopeID == scope }
            values.append(LinkedUsageValue(scopeID: scope, title: title))
        }
        updated.knownValues = Self.sortedValues(values)
        try save(registry.replacing(updated))
        let now = Date()
        var result: [LinkedUsageDiagram] = []
        for (scope, title, snapshot) in snapshots {
            // Provider names and scope labels never become filesystem paths.
            let key = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
            let store = QuotaSampleStore(fileURL: root.appendingPathComponent("diagram-history")
                .appendingPathComponent(id.uuidString).appendingPathComponent(key + ".jsonl"))
            let previous = try store.load()
            var samples = previous
            if let sample = QuotaSample(snapshot: snapshot, capturedAt: now) { samples.append(sample) }
            samples = QuotaSampleStore.compactedSamples(samples)
            var syncMessage: String?
            if let historySync, let source = accounts().first(where: { $0.id == id }) {
                let synced = await historySync.sync(account: source, scope: scope, samples: samples, snapshot: snapshot)
                samples = synced.samples
                syncMessage = synced.message
            }
            try store.write(samples)
            let currentCycle = samples.filter { sample in
                guard let reset = snapshot.secondary?.resetDate, let sampleReset = sample.weeklyResetsAt else { return false }
                let start = reset.addingTimeInterval(-Double(snapshot.secondary?.windowDurationMins ?? 10_080) * 60)
                return sample.capturedAt >= start && sample.capturedAt <= reset
                    && abs(sampleReset.timeIntervalSince(reset)) < 300
                    && sample.weeklyWindowMinutes == snapshot.secondary?.windowDurationMins
            }
            result.append(LinkedUsageDiagram(accountID: id, scopeID: scope, title: title, snapshot: snapshot,
                samples: currentCycle, capturedAt: now, syncMessage: syncMessage))
        }
        return result
    }

    private static func sortedValues(_ values: [LinkedUsageValue]) -> [LinkedUsageValue] {
        values.sorted {
            func rank(_ scope: String) -> Int { scope == "session" ? 0 : scope == "general" ? 1 : 2 }
            return rank($0.scopeID) == rank($1.scopeID) ? $0.title < $1.title : rank($0.scopeID) < rank($1.scopeID)
        }
    }

    private func save(_ next: AccountRegistry) throws {
        try next.saving(to: root.appendingPathComponent("accounts.json"))
        registry = next
    }

    // The journal lists only inactive credentials. A crash can leave a staged
    // or retired secret, never make that secret the login for a different account.
    private func cleanupCredentials() throws {
        var next = registry
        if let id = next.pendingCodexID {
            try secrets.delete(LinkedCredentialReference(provider: .codex, id: id))
            next.pendingCodexID = nil
        }
        for reference in next.credentialCleanup ?? [] { try secrets.delete(reference) }
        next.credentialCleanup = nil
        if next != registry { try save(next) }
    }

    public func beginLogin(provider: String, replacing id: UUID? = nil) async throws -> LinkedAccountLogin {
        guard !busy, pending == nil else { throw LinkedAccountError.busy }
        busy = true
        defer { busy = false }
        try? cleanupCredentials()
        guard let provider = ProbeAccount.Provider(rawValue: provider) else { throw LinkedAccountError.invalidResponse }
        let target = id.flatMap { id in registry.accounts.first { $0.id == id } }
        if id != nil, target == nil || target?.provider != provider { throw LinkedAccountError.wrongAccount }
        let loginID = UUID()
        let codex = provider == .codex ? try await codexAuth.requestDeviceCode() : nil
        let claude = provider == .claude ? ClaudeAccountOAuth.Pending() : nil
        try Task.checkCancellation()
        pending = PendingLogin(id: loginID, target: target, provider: provider, codex: codex, claude: claude)
        return LinkedAccountLogin(id: loginID, provider: provider.rawValue,
            url: codex?.verificationURL ?? claude!.url, deviceCode: codex?.userCode)
    }

    public func cancelLogin(_ id: UUID) {
        if pending?.id == id { pending = nil }
    }

    private var codexAuth: CodexNativeAuthService {
        CodexNativeAuthService(configuration: .defaultConfiguration(), httpClient: http, tokenStore: PendingCodexTokens())
    }

    public func completeLogin(_ id: UUID, code: String = "") async throws -> UUID {
        guard !busy, let login = pending, login.id == id else { throw LinkedAccountError.cancelled }
        busy = true
        defer { busy = false }
        let data: Data
        let identity: String
        let email: String?
        let plan: String?
        if let codex = login.codex {
            let tokens = try await codexAuth.completeDeviceCodeLogin(codex)
            data = try ManagedCodexTokens.encode(tokens)
            identity = try ScopedCodexTokens.identity(tokens)
            let account = codexAuth.accountSnapshot(for: tokens)
            email = account.email; plan = account.planType
        } else if let claude = login.claude {
            let oauth = ClaudeAccountOAuth(http: http)
            let credential = try await oauth.complete(claude, input: code)
            let profile = try await oauth.profile(credential)
            data = try JSONEncoder().encode(credential)
            identity = profile.identity; email = profile.email; plan = login.target?.plan
        } else { throw LinkedAccountError.invalidResponse }
        try Task.checkCancellation()
        guard pending?.id == id else { throw LinkedAccountError.cancelled }
        let accountID = try commitLogin(provider: login.provider, target: login.target,
            identity: identity, email: email, plan: plan, credential: data)
        pending = nil
        return accountID
    }

    // Synchronous commit is also used by focused tests with an in-memory secret
    // store. Network responses and pending tokens cannot mutate linked accounts.
    func commitLogin(provider: ProbeAccount.Provider, target: ProbeAccount?, identity: String,
                     email: String?, plan: String?, credential: Data) throws -> UUID {
        if let target {
            guard target.provider == provider, target.identity == identity,
                  registry.accounts.contains(target) else { throw LinkedAccountError.wrongAccount }
        }
        guard !registry.accounts.contains(where: { $0.id != target?.id && $0.provider == provider && $0.identity == identity }) else {
            throw LinkedAccountError.duplicateAccount
        }
        var account = target ?? ProbeAccount(id: UUID(), provider: provider,
            name: email ?? provider.rawValue + " account", identity: identity)
        account.email = email; account.plan = plan
        let previous = account.credentialReference
        let reference = LinkedCredentialReference(provider: provider, id: UUID())
        account.credentialID = reference.id
        account.requiresSignIn = nil
        // After explicit reauthorization the former CLI profile is no longer read.
        account.claudeDirectory = nil
        var staged = registry
        staged.credentialCleanup = (staged.credentialCleanup ?? []) + [reference]
        try save(staged)
        try secrets.write(credential, for: reference)
        var committed = registry
        committed.credentialCleanup = committed.credentialCleanup?.filter { $0 != reference }
        committed = try committed.replacing(account)
        if let previous { committed.credentialCleanup = (committed.credentialCleanup ?? []) + [previous] }
        try save(committed)
        // If cleanup fails, the journal is retried before the next operation.
        // The new account is already committed, so don't report a false failure.
        try? cleanupCredentials()
        return account.id
    }

    public func remove(_ id: UUID) throws -> [LinkedUsageAccount] {
        guard !busy, pending == nil else { throw LinkedAccountError.busy }
        try? cleanupCredentials()
        guard let account = registry.accounts.first(where: { $0.id == id }) else { return accounts() }
        var next = registry
        next.accounts.removeAll { $0.id == id }
        if let reference = account.credentialReference {
            next.credentialCleanup = (next.credentialCleanup ?? []) + [reference]
        }
        try save(next)
        try? cleanupCredentials()
        return accounts()
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Adopts only this app's former default login, not a CLI/prototype grant.
    public func adoptExistingCodex() async throws {
        guard registry.legacyCodexID == nil, !busy, pending == nil else { return }
        busy = true
        defer { busy = false }
        guard let tokens = try await KeychainCodexAuthTokenStore().load() else { return }
        let identity = try ScopedCodexTokens.identity(tokens)
        let existing = registry.accounts.first { $0.provider == .codex && $0.identity == identity }
        let snapshot = codexAuth.accountSnapshot(for: tokens)
        let id: UUID
        if let existing, existing.credentialID != nil, existing.requiresSignIn != true { id = existing.id }
        else {
            id = try commitLogin(provider: .codex, target: existing, identity: identity,
                email: snapshot.email, plan: snapshot.planType, credential: ManagedCodexTokens.encode(tokens))
        }
        let legacy = try QuotaSampleStore.defaultStore()
        let store = QuotaSampleStore(fileURL: root.appendingPathComponent("diagram-history/\(id.uuidString)/\(Self.hash("general")).jsonl"))
        try store.write(QuotaSampleStore.compactedSamples(try store.load() + legacy.load()))
        var next = registry
        next.legacyCodexID = id
        try save(next)
    }

    static func claudeSnapshots(_ reading: ClaudeUsageReading, plan: String?) -> [(String, String, RateLimitSnapshot)] {
        var result: [(String, String, RateLimitSnapshot)] = []
        if let session = reading.session {
            result.append(("session", "5h", RateLimitSnapshot(limitId: "session", limitName: "5h",
                primary: nil, secondary: session, credits: nil, planType: plan, rateLimitReachedType: nil)))
        }
        result += reading.diagrams.map { diagram in
                (diagram.id, diagram.title, RateLimitSnapshot(limitId: diagram.id, limitName: diagram.title,
                    primary: reading.session,
                    secondary: RateLimitWindow(usedPercent: diagram.usedPercent, windowDurationMins: diagram.windowMinutes,
                        resetsAt: diagram.resetsAt.map { Int($0.timeIntervalSince1970.rounded(.up)) }),
                    credits: nil, planType: plan, rateLimitReachedType: nil))
            }
        return result
    }

    static func normalizeCodex(_ reading: RateLimitSnapshot) throws -> RateLimitSnapshot {
        // Free can have one 30-day primary; Pro can have a weekly secondary.
        let windows = [reading.primary, reading.secondary].compactMap { $0 }
            .sorted { ($0.windowDurationMins ?? 0) < ($1.windowDurationMins ?? 0) }
        guard let allowance = windows.last else { throw NativeUsage.Failure(diagnostic: "missing_usage_windows") }
        return RateLimitSnapshot(limitId: reading.limitId, limitName: reading.limitName,
            primary: windows.count > 1 ? windows.first : nil, secondary: allowance, credits: reading.credits,
            planType: reading.planType, rateLimitReachedType: reading.rateLimitReachedType)
    }
}

public struct LinkedHistorySyncResult: Sendable {
    public let samples: [QuotaSample]
    public let message: String
    public init(samples: [QuotaSample], message: String) { self.samples = samples; self.message = message }
}
public protocol LinkedHistorySync: Sendable {
    func sync(account: LinkedUsageAccount, scope: String, samples: [QuotaSample], snapshot: RateLimitSnapshot) async -> LinkedHistorySyncResult
}
