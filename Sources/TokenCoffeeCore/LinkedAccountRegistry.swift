import Foundation

struct ProbeAccount: Codable, Identifiable, Equatable, Sendable {
    enum Provider: String, Codable, Sendable { case codex = "Codex", claude = "Claude" }
    let id: UUID
    let provider: Provider
    var name: String
    var email: String?
    var plan: String?
    var identity: String?
    var claudeDirectory: UUID?
    var credentialID: UUID?
    var knownValues: [LinkedUsageValue]?
    var requiresSignIn: Bool?
}

// Only account metadata lives here. Tokens stay in provider-scoped Keychain items.
struct AccountRegistry: Codable, Equatable {
    var accounts: [ProbeAccount] = []
    var pendingCodexID: UUID?
    var credentialCleanup: [LinkedCredentialReference]?
    var legacyCodexID: UUID?

    func validate() throws {
        guard Set(accounts.map(\.id)).count == accounts.count,
              !accounts.contains(where: { $0.id == pendingCodexID }) else {
            throw NativeUsage.Failure(diagnostic: "invalid_account_registry")
        }
        var identities = Set<String>()
        var profiles = Set<UUID>()
        for account in accounts {
            guard !account.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NativeUsage.Failure(diagnostic: "missing_account_name")
            }
            if let identity = account.identity {
                guard !identity.isEmpty, identities.insert(account.provider.rawValue + ":" + identity).inserted else {
                    throw NativeUsage.Failure(diagnostic: "account_already_linked")
                }
            }
            if account.provider == .claude {
                guard account.credentialID != nil || account.claudeDirectory != nil || account.requiresSignIn == true else {
                    throw NativeUsage.Failure(diagnostic: "invalid_private_profile")
                }
                if let directory = account.claudeDirectory, !profiles.insert(directory).inserted {
                    throw NativeUsage.Failure(diagnostic: "invalid_private_profile")
                }
            } else if account.identity == nil || account.claudeDirectory != nil {
                throw NativeUsage.Failure(diagnostic: "invalid_codex_account")
            }
        }
        let active = accounts.compactMap(\.credentialReference)
        guard Set(active).count == active.count,
              !(credentialCleanup ?? []).contains(where: { active.contains($0) }) else {
            throw NativeUsage.Failure(diagnostic: "invalid_credential_cleanup")
        }
    }

    func saving(to url: URL) throws {
        try validate()
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func load(from url: URL, initialClaudeDirectory: UUID) throws -> Self {
        if FileManager.default.fileExists(atPath: url.path) {
            let registry = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
            try registry.validate()
            return registry
        }
        let registry = Self(accounts: [ProbeAccount(id: UUID(), provider: .claude,
            name: "Claude account", claudeDirectory: initialClaudeDirectory)])
        try registry.saving(to: url)
        return registry
    }

    func replacing(_ account: ProbeAccount) throws -> Self {
        var next = self
        if let index = next.accounts.firstIndex(where: { $0.id == account.id }) {
            next.accounts[index] = account
        } else {
            next.accounts.append(account)
        }
        try next.validate()
        return next
    }
}

extension ProbeAccount {
    var credentialReference: LinkedCredentialReference? {
        guard requiresSignIn != true else { return nil }
        if let credentialID { return LinkedCredentialReference(provider: provider, id: credentialID) }
        return provider == .codex ? LinkedCredentialReference(provider: provider, id: id) : nil
    }
}

// The pending login writes only memory. It cannot overwrite an already-linked account.
actor PendingCodexTokens: CodexAuthTokenStore {
    private var tokens: CodexAuthTokens?
    func load() -> CodexAuthTokens? { tokens }
    func save(_ tokens: CodexAuthTokens) throws {
        try Task.checkCancellation()
        self.tokens = tokens
    }
    func delete() { tokens = nil }
}

struct ScopedCodexTokens: CodexAuthTokenStore {
    static let service = "com.pardeike.TokenCoffee.AccountProbe.codex-auth"
    let id: UUID
    let expectedIdentity: String
    var keychain: KeychainCodexAuthTokenStore {
        KeychainCodexAuthTokenStore(service: Self.service, account: id.uuidString)
    }

    static func identity(_ tokens: CodexAuthTokens) throws -> String {
        let access = CodexJWTClaims.parse(tokens.accessToken).accountID
        let id = CodexJWTClaims.parse(tokens.idToken).accountID
        guard let identity = access ?? id, !identity.isEmpty,
              access == nil || id == nil || access == id else {
            throw NativeUsage.Failure(diagnostic: "account_identity_unavailable")
        }
        return identity
    }

    func load() async throws -> CodexAuthTokens? {
        guard let tokens = try await keychain.load() else { return nil }
        try validate(tokens)
        return tokens
    }
    func save(_ tokens: CodexAuthTokens) async throws {
        try validate(tokens)
        try Task.checkCancellation()
        try await keychain.save(tokens)
    }
    func delete() async throws { try await keychain.delete() }
    private func validate(_ tokens: CodexAuthTokens) throws {
        guard try Self.identity(tokens) == expectedIdentity else {
            throw NativeUsage.Failure(diagnostic: "account_identity_changed")
        }
    }
}
