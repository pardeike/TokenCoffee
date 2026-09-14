import CryptoKit
import Foundation
import XCTest
@testable import TokenCoffeeCore

final class LinkedAccountManagementTests: XCTestCase {
    private func root(_ accounts: [ProbeAccount] = []) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try AccountRegistry(accounts: accounts).saving(to: url.appendingPathComponent("accounts.json"))
        return url
    }
    private func registry(_ root: URL) throws -> AccountRegistry {
        try JSONDecoder().decode(AccountRegistry.self, from: Data(contentsOf: root.appendingPathComponent("accounts.json")))
    }

    func testPKCEStateExpiryAndLimitedScope() throws {
        let pending = ClaudeAccountOAuth.Pending()
        let items = try XCTUnwrap(URLComponents(url: pending.url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "scope" }?.value, "user:profile")
        XCTAssertEqual(items.first { $0.name == "code_challenge_method" }?.value, "S256")
        XCTAssertNotEqual(items.first { $0.name == "code_challenge" }?.value, pending.verifier)
        XCTAssertEqual(try pending.code(from: " code#" + pending.state + "\n"), "code")
        XCTAssertThrowsError(try pending.code(from: "code#other-login"))
        XCTAssertThrowsError(try pending.code(from: "code"))
        XCTAssertThrowsError(try pending.code(from: "code#" + pending.state, now: pending.createdAt.addingTimeInterval(1800)))
    }

    @MainActor func testAddDuplicateWrongAccountRelinkAndRemoval() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let secrets = TestAccountSecrets()
        let service = try LinkedUsageService(root: root, secrets: secrets, http: TestAccountHTTP([]))
        let first = try await service.commitLogin(provider: .claude, target: nil, identity: "org:member",
            email: "first@example.test", plan: nil, credential: Data("first-secret".utf8))
        let original = try XCTUnwrap(registry(root).accounts.first)
        _ = try await service.rename(first, to: "Personal")
        let named = try XCTUnwrap(registry(root).accounts.first)
        do {
            _ = try await service.commitLogin(provider: .claude, target: nil, identity: "org:member",
                email: "different-email@example.test", plan: nil, credential: Data("duplicate".utf8))
            XCTFail("Duplicate provider identity accepted")
        } catch LinkedAccountError.duplicateAccount { }
        do {
            _ = try await service.commitLogin(provider: .claude, target: named, identity: "org:other-member",
                email: named.email, plan: nil, credential: Data("wrong-account".utf8))
            XCTFail("A different member replaced the account")
        } catch LinkedAccountError.wrongAccount { }
        XCTAssertEqual(try registry(root).accounts, [named])
        XCTAssertEqual(secrets.count, 1)
        let relinked = try await service.commitLogin(provider: .claude, target: named, identity: "org:member",
            email: named.email, plan: nil, credential: Data("new-secret".utf8))
        XCTAssertEqual(relinked, first)
        XCTAssertEqual(try registry(root).accounts.first?.name, "Personal")
        XCTAssertNotEqual(try registry(root).accounts.first?.credentialID, original.credentialID)
        XCTAssertEqual(secrets.count, 1, "Old credential was removed after committing the replacement")
        let removed = try await service.remove(first)
        XCTAssertTrue(removed.isEmpty)
        XCTAssertEqual(secrets.count, 0)
    }

    @MainActor func testFailedCredentialWriteDoesNotReplaceExistingLink() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let secrets = TestAccountSecrets()
        let service = try LinkedUsageService(root: root, secrets: secrets, http: TestAccountHTTP([]))
        _ = try await service.commitLogin(provider: .codex, target: nil, identity: "codex-id",
            email: nil, plan: nil, credential: Data("original".utf8))
        let original = try XCTUnwrap(registry(root).accounts.first)
        secrets.failWrites = true
        do {
            _ = try await service.commitLogin(provider: .codex, target: original, identity: "codex-id",
                email: nil, plan: nil, credential: Data("replacement".utf8))
            XCTFail("Write should fail")
        } catch LinkedAccountError.keychain { }
        XCTAssertEqual(try registry(root).accounts, [original])
        XCTAssertEqual(try secrets.read(XCTUnwrap(original.credentialReference)), Data("original".utf8))
        XCTAssertEqual(try registry(root).credentialCleanup?.count, 1, "Abandoned staging entry is journaled")
    }

    @MainActor func testCleanupFailureIsReportedAndRetriedWithoutDeletingLiveCredentials() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let secrets = TestAccountSecrets()
        let service = try LinkedUsageService(root: root, secrets: secrets, http: TestAccountHTTP([]))
        let id = try await service.commitLogin(provider: .claude, target: nil, identity: "org:member",
            email: nil, plan: nil, credential: Data("secret".utf8))
        secrets.failDeletes = true
        _ = try await service.remove(id)
        let warning = await service.maintenanceMessage()
        XCTAssertNotNil(warning)
        XCTAssertTrue(try registry(root).accounts.isEmpty)
        let unblocked = try await service.beginLogin(provider: "Claude")
        await service.cancelLogin(unblocked.id)
        XCTAssertEqual(secrets.count, 1, "Failure remains queued without blocking an unrelated login")
        secrets.failDeletes = false
        let reopened = try LinkedUsageService(root: root, secrets: secrets, http: TestAccountHTTP([]))
        let login = try await reopened.beginLogin(provider: "Claude")
        XCTAssertEqual(secrets.count, 0)
        await reopened.cancelLogin(login.id)
        let cleanWarning = await reopened.maintenanceMessage()
        XCTAssertNil(cleanWarning)
    }

    func testJournalCannotTargetActiveCredential() throws {
        let account = ProbeAccount(id: UUID(), provider: .codex, name: "Work", identity: "account")
        let invalid = AccountRegistry(accounts: [account], credentialCleanup: [try XCTUnwrap(account.credentialReference)])
        XCTAssertThrowsError(try invalid.validate())
    }

    @MainActor func testNormalFirstLaunchCreatesEmptyRegistryAndImportedClaudeNeedsSignIn() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let empty = try LinkedUsageService(root: directory, secrets: TestAccountSecrets(), http: TestAccountHTTP([]))
        let initial = await empty.accounts()
        XCTAssertTrue(initial.isEmpty)
        let account = ProbeAccount(id: UUID(), provider: .claude, name: "Personal", identity: "org:member",
            knownValues: [LinkedUsageValue(scopeID: "session", title: "5h")], requiresSignIn: true)
        try AccountRegistry(accounts: [account]).saving(to: directory.appendingPathComponent("accounts.json"))
        let imported = try LinkedUsageService(root: directory, secrets: TestAccountSecrets(), http: TestAccountHTTP([]))
        let accounts = await imported.accounts()
        XCTAssertEqual(accounts.first?.values.first?.title, "5h")
        do { _ = try await imported.refresh(account.id); XCTFail("Imported metadata must not read a prototype credential") }
        catch LinkedAccountError.signInRequired { }
        XCTAssertNil(account.credentialReference)
    }

    @MainActor func testCancelledLoginCannotCommitOrCreateAccounts() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let secrets = TestAccountSecrets()
        let service = try LinkedUsageService(root: root, secrets: secrets, http: TestAccountHTTP([]))
        let login = try await service.beginLogin(provider: "Claude")
        await service.cancelLogin(login.id)
        do { _ = try await service.completeLogin(login.id, code: "unused"); XCTFail("Cancelled login completed") }
        catch LinkedAccountError.cancelled { }
        XCTAssertTrue(try registry(root).accounts.isEmpty)
        XCTAssertEqual(secrets.count, 0)
    }

    @MainActor func testClaudeBrowserCompletionStoresOnlyVerifiedIndependentGrant() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let secrets = TestAccountSecrets()
        let http = TestAccountHTTP([
            (200, #"{"access_token":"private-access","refresh_token":"private-refresh","expires_in":28800,"scope":"user:profile"}"#),
            (200, Self.profile)])
        let service = try LinkedUsageService(root: root, secrets: secrets, http: http)
        let login = try await service.beginLogin(provider: "Claude")
        let state = try XCTUnwrap(URLComponents(url: login.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value)
        do { _ = try await service.completeLogin(login.id, code: "bad#state"); XCTFail("Wrong state accepted") }
        catch LinkedAccountError.invalidCode { }
        XCTAssertEqual(secrets.count, 0)
        let id = try await service.completeLogin(login.id, code: "browser-code#" + state)
        let account = try XCTUnwrap(registry(root).accounts.first)
        XCTAssertEqual(account.id, id)
        XCTAssertEqual(account.identity, Self.identity)
        XCTAssertNil(account.claudeDirectory, "No CLI profile is created or reused")
        XCTAssertNotNil(account.credentialID)
        let metadata = try String(contentsOf: root.appendingPathComponent("accounts.json"), encoding: .utf8)
        XCTAssertFalse(metadata.contains("private-access"))
        XCTAssertFalse(metadata.contains("private-refresh"))
        XCTAssertFalse(metadata.contains("browser-code"))
        let requests = await http.requests
        XCTAssertEqual(requests.count, 2, "Invalid state must not reach the network")
    }

    @MainActor func testValuesRecoveredFromAccountHistoryWithoutPredictorsOrNetwork() async throws {
        let account = ProbeAccount(id: UUID(), provider: .claude, name: "Personal", identity: "org:member", claudeDirectory: UUID())
        let root = try root([account])
        defer { try? FileManager.default.removeItem(at: root) }
        for (scope, title) in [("session", "5h"), ("general", "General"), ("model-name:fable", "Fable")] {
            let hash = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
            let file = root.appendingPathComponent("diagram-history/\(account.id.uuidString)/\(hash).jsonl")
            let snapshot = RateLimitSnapshot(limitId: scope, limitName: title, primary: nil,
                secondary: RateLimitWindow(usedPercent: 42, windowDurationMins: 300, resetsAt: 1_800_000_000),
                credits: nil, planType: nil, rateLimitReachedType: nil)
            try QuotaSampleStore(fileURL: file).write([try XCTUnwrap(QuotaSample(snapshot: snapshot, capturedAt: Date()))])
        }
        let service = try LinkedUsageService(root: root, secrets: TestAccountSecrets(), http: TestAccountHTTP([]))
        let accounts = await service.accounts()
        XCTAssertEqual(accounts.first?.values.map(\.title), ["5h", "General", "Fable"])
        let restored = try LinkedUsageService(root: root, secrets: TestAccountSecrets(), http: TestAccountHTTP([]))
        let restoredAccounts = await restored.accounts()
        XCTAssertEqual(restoredAccounts, accounts)
        _ = try await service.remove(account.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("diagram-history/\(account.id.uuidString)").path))
    }

    @MainActor func testExpiredClaudeGrantRotatesOnceAndPersistsBeforeUsageFailure() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let secrets = TestAccountSecrets()
        let http = TestAccountHTTP([
            (200, #"{"access_token":"rotated-access","refresh_token":"rotated-refresh","expires_in":28800,"scope":"user:profile"}"#),
            (200, Self.profile), (429, "private-response-must-not-escape")])
        let service = try LinkedUsageService(root: root, secrets: secrets, http: http)
        let credential = ClaudeAccountCredential(accessToken: "expired", refreshToken: "old-refresh", expiresAt: .distantPast)
        let id = try await service.commitLogin(provider: .claude, target: nil, identity: Self.identity,
            email: nil, plan: nil, credential: JSONEncoder().encode(credential))
        do { _ = try await service.refresh(id); XCTFail("Usage should fail") }
        catch LinkedAccountError.http(429) { }
        let reference = try XCTUnwrap(registry(root).accounts.first?.credentialReference)
        let saved = try JSONDecoder().decode(ClaudeAccountCredential.self, from: XCTUnwrap(secrets.read(reference)))
        XCTAssertEqual(saved.refreshToken, "rotated-refresh")
        XCTAssertFalse(saved.needsRefresh)
        let requests = await http.requests
        XCTAssertEqual(requests.count, 3, "No retry on HTTP 429")
        let body = try XCTUnwrap(requests.first?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json["grant_type"], "refresh_token")
        XCTAssertEqual(json["refresh_token"], "old-refresh")
        XCTAssertFalse(LinkedAccountError.message(for: LinkedAccountError.http(429)).contains("private-response"))
    }

    @MainActor func testClaudeUnauthorizedRetriesOnceWithItsOwnGrant() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let secrets = TestAccountSecrets()
        let http = TestAccountHTTP([(401, ""),
            (200, #"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":28800}"#),
            (200, Self.profile), (200, #"{"five_hour":{"utilization":77},"seven_day":{"utilization":20}}"#)])
        let service = try LinkedUsageService(root: root, secrets: secrets, http: http)
        let credential = ClaudeAccountCredential(accessToken: "revoked-access", refreshToken: "own-refresh", expiresAt: .distantFuture)
        let id = try await service.commitLogin(provider: .claude, target: nil, identity: Self.identity,
            email: nil, plan: nil, credential: JSONEncoder().encode(credential))
        let readings = try await service.refresh(id)
        XCTAssertEqual(readings.map(\.title), ["5h", "General"])
        let accounts = await service.accounts()
        XCTAssertEqual(accounts.first?.values.map(\.scopeID), ["session", "general"])
        let requests = await http.requests
        XCTAssertEqual(requests.count, 4)
    }

    @MainActor func testEarlyResetIsConfirmedBeforePublishingOrSyncingAndSurvivesRestart() async throws {
        let clock = AccountReviewClock()
        let reference = LinkedCredentialReference(provider: .claude, id: UUID())
        let account = ProbeAccount(id: UUID(), provider: .claude, name: "Personal", identity: Self.identity, credentialID: reference.id)
        let directory = try root([account])
        defer { try? FileManager.default.removeItem(at: directory) }
        let secrets = TestAccountSecrets()
        try secrets.write(JSONEncoder().encode(ClaudeAccountCredential(accessToken: "test", refreshToken: "test", expiresAt: .distantFuture)), for: reference)
        let reset = clock.date.addingTimeInterval(100_000)
        let snapshot = RateLimitSnapshot(limitId: "general", limitName: "General", primary: nil,
            secondary: RateLimitWindow(usedPercent: 54, windowDurationMins: 10_080, resetsAt: Int(reset.timeIntervalSince1970)),
            credits: nil, planType: nil, rateLimitReachedType: nil)
        let hash = SHA256.hash(data: Data("general".utf8)).map { String(format: "%02x", $0) }.joined()
        let store = QuotaSampleStore(fileURL: directory.appendingPathComponent("diagram-history/\(account.id.uuidString)/\(hash).jsonl"))
        let baseline = [-120.0, -60.0].compactMap { QuotaSample(snapshot: snapshot, capturedAt: clock.date.addingTimeInterval($0)) }
        try store.write(baseline)
        let newReset = ISO8601DateFormatter().string(from: reset.addingTimeInterval(100_000))
        let usage = "{\"seven_day\":{\"utilization\":0,\"resets_at\":\"\(newReset)\"}}"
        let http = TestAccountHTTP(Array(repeating: [(200, Self.profile), (200, usage)], count: 3).flatMap { $0 })
        let sync = AccountReviewSync()
        let service = try LinkedUsageService(root: directory, secrets: secrets, http: http, historySync: sync, now: { clock.date })
        for _ in 0..<2 {
            let pending = try await service.refresh(account.id)
            XCTAssertEqual(pending.first?.snapshot.secondary?.usedPercent, 54)
            XCTAssertNotNil(pending.first?.warning)
            XCTAssertEqual(try store.load().map(\.weeklyUsedPercent), [54, 54])
            clock.advance(60)
        }
        let before = await sync.count
        XCTAssertEqual(before, 0, "Unconfirmed reset must not drive cloud cleanup or upload")
        let accepted = try await service.refresh(account.id)
        XCTAssertEqual(accepted.first?.snapshot.secondary?.usedPercent, 0)
        XCTAssertNil(accepted.first?.warning)
        XCTAssertEqual(accepted.first?.samples.filter { $0.weeklyUsedPercent == 0 }.count, 3)
        let reopened = try LinkedUsageService(root: directory, secrets: secrets, http: TestAccountHTTP([]))
        let restored = await reopened.cachedDiagrams()
        XCTAssertEqual(restored.first?.snapshot.secondary?.usedPercent, 0)
        XCTAssertEqual(try XCTUnwrap(restored.first).capturedAt.timeIntervalSince1970,
                       try XCTUnwrap(accepted.first).capturedAt.timeIntervalSince1970, accuracy: 1)
        XCTAssertTrue(restored.first?.isCached == true)
    }

    @MainActor func testPendingLoginPausesOnlyItsTargetAndExpiresWithoutCommitting() async throws {
        let clock = AccountReviewClock()
        let target = ProbeAccount(id: UUID(), provider: .claude, name: "Reconnect", identity: "other:member", requiresSignIn: true)
        let reference = LinkedCredentialReference(provider: .claude, id: UUID())
        let other = ProbeAccount(id: UUID(), provider: .claude, name: "Monitor", identity: Self.identity, credentialID: reference.id)
        let directory = try root([target, other])
        defer { try? FileManager.default.removeItem(at: directory) }
        let secrets = TestAccountSecrets()
        try secrets.write(JSONEncoder().encode(ClaudeAccountCredential(accessToken: "test", refreshToken: "test", expiresAt: .distantFuture)), for: reference)
        let http = TestAccountHTTP([(200, Self.profile), (200, #"{"seven_day":{"utilization":25}}"#)])
        let service = try LinkedUsageService(root: directory, secrets: secrets, http: http, now: { clock.date })
        let login = try await service.beginLogin(provider: "Claude", replacing: target.id)
        let readings = try await service.refresh(other.id)
        XCTAssertEqual(readings.first?.snapshot.secondary?.usedPercent, 25)
        do { _ = try await service.refresh(target.id); XCTFail("Read the account being reconnected") }
        catch LinkedAccountError.busy { }
        clock.advance(1801)
        do { _ = try await service.completeLogin(login.id, code: "unused"); XCTFail("Expired grant completed") }
        catch LinkedAccountError.expiredLogin { }
        let retry = try await service.beginLogin(provider: "Claude", replacing: target.id)
        XCTAssertNotEqual(retry.id, login.id)
        await service.cancelLogin(retry.id)
        XCTAssertEqual(try registry(directory).accounts.first?.requiresSignIn, true)
    }

    @MainActor func testLoginCompletionNetworkWaitDoesNotBlockAnotherAccountRead() async throws {
        let reference = LinkedCredentialReference(provider: .claude, id: UUID())
        let other = ProbeAccount(id: UUID(), provider: .claude, name: "Monitor", identity: Self.identity, credentialID: reference.id)
        let directory = try root([other])
        defer { try? FileManager.default.removeItem(at: directory) }
        let secrets = TestAccountSecrets()
        try secrets.write(JSONEncoder().encode(ClaudeAccountCredential(accessToken: "test", refreshToken: "test", expiresAt: .distantFuture)), for: reference)
        let http = SuspendedLoginHTTP(profile: Self.profile)
        let service = try LinkedUsageService(root: directory, secrets: secrets, http: http)
        let login = try await service.beginLogin(provider: "Claude")
        let state = try XCTUnwrap(URLComponents(url: login.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value)
        let completion = Task { try await service.completeLogin(login.id, code: "test#" + state) }
        await http.waitForTokenRequest()
        // Always release the suspended request, including on an assertion failure.
        let readings: [LinkedUsageDiagram]?
        do { readings = try await service.refresh(other.id) }
        catch { readings = nil; XCTFail("Unrelated read blocked during token exchange: \(error)") }
        await http.release()
        XCTAssertEqual(readings?.first?.snapshot.secondary?.usedPercent, 25)
        do { _ = try await completion.value; XCTFail("Duplicate add should still be rejected") }
        catch LinkedAccountError.duplicateAccount { }
        await service.cancelLogin(login.id)
    }

    @MainActor func testWrongClaudeProfileNeverReadsOrAssignsUsage() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let http = TestAccountHTTP([(200, Self.profile)])
        let service = try LinkedUsageService(root: root, secrets: TestAccountSecrets(), http: http)
        let credential = ClaudeAccountCredential(accessToken: "access", refreshToken: "refresh", expiresAt: .distantFuture)
        let id = try await service.commitLogin(provider: .claude, target: nil, identity: "another:account",
            email: nil, plan: nil, credential: JSONEncoder().encode(credential))
        do { _ = try await service.refresh(id); XCTFail("Wrong account read usage") }
        catch LinkedAccountError.wrongAccount { }
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
    }

    private static let identity = "00000000-0000-0000-0000-000000000001:00000000-0000-0000-0000-000000000002"
    private static let profile = #"{"organization":{"uuid":"00000000-0000-0000-0000-000000000001"},"account":{"uuid":"00000000-0000-0000-0000-000000000002","email":"person@example.test"}}"#
}

private final class AccountReviewClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()
    var date: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}

private actor AccountReviewSync: LinkedHistorySync {
    private(set) var count = 0
    func sync(account: LinkedUsageAccount, scope: String, samples: [QuotaSample], snapshot: RateLimitSnapshot) async -> LinkedHistorySyncResult {
        count += 1
        return LinkedHistorySyncResult(samples: QuotaSampleStore.compactedSamples(QuotaSnapshotContinuityPolicy.repairedSamples(samples)), message: "iCloud synced")
    }
}

private actor SuspendedLoginHTTP: CodexHTTPClient {
    let profile: String
    private var tokenRequested = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var tokenResponse: CheckedContinuation<Void, Never>?
    init(profile: String) { self.profile = profile }
    func waitForTokenRequest() async {
        if !tokenRequested { await withCheckedContinuation { waiting = $0 } }
    }
    func release() { tokenResponse?.resume(); tokenResponse = nil }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body: String
        if request.url?.lastPathComponent == "token" {
            tokenRequested = true
            await withCheckedContinuation { continuation in
                tokenResponse = continuation
                waiting?.resume(); waiting = nil
            }
            body = #"{"access_token":"test-access","refresh_token":"test-refresh","expires_in":28800,"scope":"user:profile"}"#
        } else if request.url?.lastPathComponent == "profile" { body = profile }
        else { body = #"{"seven_day":{"utilization":25}}"# }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private final class TestAccountSecrets: LinkedAccountSecrets, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [LinkedCredentialReference: Data] = [:]
    var failWrites = false
    var failDeletes = false
    var count: Int { lock.withLock { values.count } }
    func read(_ reference: LinkedCredentialReference) throws -> Data? { lock.withLock { values[reference] } }
    func write(_ data: Data, for reference: LinkedCredentialReference) throws {
        try lock.withLock {
            if failWrites { throw LinkedAccountError.keychain }
            values[reference] = data
        }
    }
    func delete(_ reference: LinkedCredentialReference) throws {
        try lock.withLock {
            if failDeletes { throw LinkedAccountError.keychain }
            values[reference] = nil
        }
    }
}

private actor TestAccountHTTP: CodexHTTPClient {
    private var responses: [(Int, String)]
    private(set) var requests: [URLRequest] = []
    init(_ responses: [(Int, String)]) { self.responses = responses }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !responses.isEmpty else { throw LinkedAccountError.invalidResponse }
        let response = responses.removeFirst()
        return (Data(response.1.utf8), HTTPURLResponse(url: request.url!, statusCode: response.0, httpVersion: nil, headerFields: nil)!)
    }
}
