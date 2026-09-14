import AppKit
import CryptoKit
import XCTest
@testable import TokenCoffeeCore
@testable import Token_Coffee

final class AccountLoginFlowTests: XCTestCase {
    func testCloudZoneIsIndependentOfAdoptionAndLocalAccountID() {
        func account(_ key: String, legacy: Bool) -> LinkedUsageAccount {
            LinkedUsageAccount(id: UUID(), provider: "Codex", name: "Personal", email: nil, plan: nil,
                values: [], cloudKey: key, usesLegacyHistory: legacy)
        }
        let adopted = account("account-a", legacy: true)
        let linkedElsewhere = account("account-a", legacy: false)
        let anotherAdopted = account("account-b", legacy: true)
        XCTAssertEqual(LinkedHistoryCloudSync.zoneName(account: adopted, scope: "general"),
                       LinkedHistoryCloudSync.zoneName(account: linkedElsewhere, scope: "general"))
        XCTAssertNotEqual(LinkedHistoryCloudSync.zoneName(account: adopted, scope: "general"),
                          LinkedHistoryCloudSync.zoneName(account: anotherAdopted, scope: "general"))
        XCTAssertNotEqual(LinkedHistoryCloudSync.zoneName(account: adopted, scope: "general"),
                          LinkedHistoryCloudSync.zoneName(account: adopted, scope: "session"))
        XCTAssertNotEqual(LinkedHistoryCloudSync.zoneName(account: adopted, scope: "general"), "QuotaSamples")
    }

    func testLegacyLocalMirrorArchivesOriginalOnlyOnce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = QuotaSampleStore(fileURL: root.appendingPathComponent("quota-samples.jsonl"))
        let archive = root.appendingPathComponent("legacy-unattributed-history.jsonl")
        let snapshot = RateLimitSnapshot(limitId: "codex", limitName: nil, primary: nil,
            secondary: RateLimitWindow(usedPercent: 42, windowDurationMins: 10_080, resetsAt: nil),
            credits: nil, planType: nil, rateLimitReachedType: nil)
        try store.write([try XCTUnwrap(QuotaSample(snapshot: snapshot, capturedAt: Date()))])
        let original = try Data(contentsOf: store.fileURL)
        try LinkedHistoryCloudSync.mirrorLegacyFile(samples: [], store: store, archive: archive)
        XCTAssertEqual(try Data(contentsOf: archive), original)
        try LinkedHistoryCloudSync.mirrorLegacyFile(samples: [], store: store, archive: archive)
        XCTAssertEqual(try Data(contentsOf: archive), original)
        XCTAssertTrue(try store.load().isEmpty)
    }

    @MainActor func testOfflineRestartRestoresSavedScopesWithoutChangingTimestamp() async throws {
        let fixture = try Fixture(responses: [])
        defer { fixture.cleanUp() }
        let captured = Date().addingTimeInterval(-120)
        for (scope, duration) in [("session", 300), ("general", 10_080), ("model-name:fable", 10_080), ("unknown-reset", 10_080)] {
            let snapshot = RateLimitSnapshot(limitId: scope, limitName: scope, primary: nil,
                secondary: RateLimitWindow(usedPercent: 42, windowDurationMins: duration,
                    resetsAt: scope == "unknown-reset" ? nil : Int(captured.addingTimeInterval(Double(duration) * 30).timeIntervalSince1970)),
                credits: nil, planType: nil, rateLimitReachedType: nil)
            let key = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
            try QuotaSampleStore(fileURL: fixture.root.appendingPathComponent("diagram-history/\(fixture.accountID.uuidString)/\(key).jsonl"))
                .write([try XCTUnwrap(QuotaSample(snapshot: snapshot, capturedAt: captured))])
        }
        let restarted = try LinkedDashboardModel(service: LinkedUsageService(root: fixture.root,
            secrets: LoginSecrets(), http: LoginHTTP([])), defaults: fixture.defaults)
        await restarted.refresh()
        XCTAssertEqual(restarted.diagrams.count, 4)
        XCTAssertTrue(restarted.diagrams.allSatisfy(\.isCached))
        XCTAssertTrue(restarted.diagrams.allSatisfy { abs($0.capturedAt.timeIntervalSince(captured)) < 1 })
        XCTAssertNotNil(restarted.errors[fixture.accountID], "Offline/sign-in error must remain alongside saved readings")
    }

    @MainActor func testSyncInformationDoesNotOverrideSessionOrQuotaSeverity() {
        for used in [42.0, 100.0] {
            let snapshot = RateLimitSnapshot(limitId: "session", limitName: "5h", primary: nil,
                secondary: RateLimitWindow(usedPercent: used, windowDurationMins: 300, resetsAt: nil),
                credits: nil, planType: nil, rateLimitReachedType: nil)
            let projection = QuotaProjection(currentWeeklyUsedPercent: used, idealWeeklyUsedPercent: nil,
                projectedWeeklyUsedPercentAtReset: nil, weeklyResetDate: nil, weeklyWindowStartDate: nil, paceState: .fine)
            let tile = UsageTileView(title: "Five hours", provider: "Claude", snapshot: snapshot, samples: [],
                projection: projection, now: Date(), kind: .detail, status: nil, prominent: false, inspecting: false,
                syncMessage: "iCloud synced")
            XCTAssertEqual(tile.tint, used == 100 ? .red : .cyan)
            XCTAssertEqual(tile.sessionText, used == 100 ? "Limit reached" : "5-hour window")
        }
    }

    @MainActor func testModelKeepsOtherAccountsPollingDuringReconnect() async throws {
        let fixture = try Fixture(responses: Self.connectedResponses + Array(Self.connectedResponses.suffix(2)))
        defer { fixture.cleanUp() }
        let login = try await fixture.model.beginAccountLogin(provider: "Claude", replacing: fixture.accountID)
        _ = try await fixture.model.completeAccountLogin(login, code: try Self.code(login))
        let before = await fixture.http.requests.count
        let pendingAdd = try await fixture.model.beginAccountLogin(provider: "Claude", replacing: nil)
        await fixture.model.refresh()
        let after = await fixture.http.requests.count
        XCTAssertEqual(after, before + 2)
        XCTAssertTrue(fixture.model.linking)
        await fixture.model.cancelAccountLogin()
        do { _ = try await fixture.model.completeAccountLogin(pendingAdd, code: "unused"); XCTFail("Cancelled login completed") }
        catch LinkedAccountError.cancelled { }
    }

    @MainActor func testImportedAccountReconnectFetchesValuesAndPreservesPredictors() async throws {
        let fixture = try Fixture(responses: Self.connectedResponses)
        defer { fixture.cleanUp() }
        await fixture.model.refresh()
        let account = try XCTUnwrap(fixture.model.accounts.first)
        XCTAssertTrue(account.requiresSignIn)
        let request = AccountLoginRequest(account: account)
        XCTAssertNotEqual(request.id, AccountLoginRequest(account: account).id)
        XCTAssertNil(AccountLoginRequest(account: nil).account)
        let predictor = Predictor(accountID: account.id, scopeID: "session", name: "My five hours", color: .purple)
        XCTAssertTrue(fixture.model.predictors.save(predictor))

        let login = try await fixture.model.beginAccountLogin(provider: request.account!.provider, replacing: request.account!.id)
        let id = try await fixture.model.completeAccountLogin(login, code: try Self.code(login))

        XCTAssertEqual(id, account.id)
        XCTAssertEqual(fixture.model.accounts.count, 1)
        XCTAssertEqual(fixture.model.accounts.first?.name, "Personal")
        XCTAssertEqual(fixture.model.accounts.first?.requiresSignIn, false)
        XCTAssertEqual(fixture.model.predictors.items, [predictor])
        XCTAssertEqual(fixture.model.diagrams.map(\.title), ["5h", "General", "Fable"])
        XCTAssertEqual(fixture.model.diagrams.compactMap { $0.snapshot.secondary?.usedPercent }, [77, 20, 35])
        XCTAssertNil(fixture.model.errors[id])
        XCTAssertFalse(fixture.model.linking)
        XCTAssertFalse(fixture.model.refreshing)
        XCTAssertTrue(fixture.model.accountMessage?.contains("usage updated") == true)
        let requests = await fixture.http.requests
        XCTAssertEqual(requests.map { $0.url?.lastPathComponent }, ["token", "profile", "profile", "usage"])
    }

    @MainActor func testDuplicateFailureReleasesLoginAndAllowsExplicitReconnect() async throws {
        let fixture = try Fixture(responses: Array(Self.connectedResponses.prefix(2)) + Self.connectedResponses)
        defer { fixture.cleanUp() }
        let add = try await fixture.model.beginAccountLogin(provider: "Claude", replacing: nil)
        do {
            _ = try await fixture.model.completeAccountLogin(add, code: try Self.code(add))
            XCTFail("Adding an already linked identity must not replace it")
        } catch LinkedAccountError.duplicateAccount { }
        XCTAssertFalse(fixture.model.linking)
        await fixture.model.refresh()
        XCTAssertTrue(fixture.model.errors[fixture.accountID]?.contains("Sign-in required") == true,
                      "Failed login must not leave Refresh Usage blocked by a pending operation")
        let reconnect = try await fixture.model.beginAccountLogin(provider: "Claude", replacing: fixture.accountID)
        let id = try await fixture.model.completeAccountLogin(reconnect, code: try Self.code(reconnect))
        XCTAssertEqual(id, fixture.accountID)
        XCTAssertEqual(fixture.model.diagrams.count, 3)
    }

    @MainActor func testFetchFailureKeepsSuccessfulLoginAndRefreshRetriesWithoutBrowser() async throws {
        let fixture = try Fixture(responses: Array(Self.connectedResponses.prefix(3)) + [(429, "private-body")]
            + Array(Self.connectedResponses.suffix(2)))
        defer { fixture.cleanUp() }
        let login = try await fixture.model.beginAccountLogin(provider: "Claude", replacing: fixture.accountID)
        let id = try await fixture.model.completeAccountLogin(login, code: try Self.code(login))
        XCTAssertEqual(fixture.model.accounts.first?.requiresSignIn, false)
        XCTAssertTrue(fixture.model.errors[id]?.contains("rate-limiting") == true)
        XCTAssertTrue(fixture.model.accountMessage?.contains("usage could not be fetched") == true)
        XCTAssertFalse(fixture.model.linking)
        await fixture.model.refresh(id)
        XCTAssertNil(fixture.model.errors[id])
        XCTAssertNil(fixture.model.accountMessage, "Successful retry must not leave the earlier failure message visible")
        XCTAssertEqual(fixture.model.diagrams.count, 3)
        let requests = await fixture.http.requests
        XCTAssertEqual(requests.filter { $0.url?.lastPathComponent == "token" }.count, 1)
    }

    @MainActor func testInvalidCodeCanBeCorrectedWithinSameLogin() async throws {
        let fixture = try Fixture(responses: Self.connectedResponses)
        defer { fixture.cleanUp() }
        let login = try await fixture.model.beginAccountLogin(provider: "Claude", replacing: fixture.accountID)
        do {
            _ = try await fixture.model.completeAccountLogin(login, code: "missing-state")
            XCTFail("Malformed code accepted")
        } catch LinkedAccountError.invalidCode { }
        XCTAssertTrue(fixture.model.linking)
        let requests = await fixture.http.requests
        XCTAssertTrue(requests.isEmpty)
        _ = try await fixture.model.completeAccountLogin(login, code: try Self.code(login))
        XCTAssertFalse(fixture.model.linking)
        XCTAssertEqual(fixture.model.diagrams.count, 3)
    }

    @MainActor func testCancelledAndWrongAccountLoginsLeaveAccountUnchanged() async throws {
        let wrong = Self.profile.replacingOccurrences(of: "000000000002", with: "000000000003")
        let fixture = try Fixture(responses: [Self.connectedResponses[0], (200, wrong)])
        defer { fixture.cleanUp() }
        let cancelled = try await fixture.model.beginAccountLogin(provider: "Claude", replacing: fixture.accountID)
        await fixture.model.cancelAccountLogin()
        do {
            _ = try await fixture.model.completeAccountLogin(cancelled, code: "unused")
            XCTFail("Cancelled login completed")
        } catch LinkedAccountError.cancelled { }
        let login = try await fixture.model.beginAccountLogin(provider: "Claude", replacing: fixture.accountID)
        do {
            _ = try await fixture.model.completeAccountLogin(login, code: try Self.code(login))
            XCTFail("Another identity replaced the account")
        } catch LinkedAccountError.wrongAccount { }
        XCTAssertFalse(fixture.model.linking)
        await fixture.model.refresh()
        XCTAssertEqual(fixture.model.accounts.first?.id, fixture.accountID)
        XCTAssertEqual(fixture.model.accounts.first?.requiresSignIn, true)
        XCTAssertTrue(fixture.model.diagrams.isEmpty)
    }

    @MainActor func testRefreshFailurePreservesLastReadingsAndShowsError() async throws {
        let fixture = try Fixture(responses: Self.connectedResponses + [(200, Self.profile), (500, "private-body")])
        defer { fixture.cleanUp() }
        let login = try await fixture.model.beginAccountLogin(provider: "Claude", replacing: fixture.accountID)
        _ = try await fixture.model.completeAccountLogin(login, code: try Self.code(login))
        let before = fixture.model.diagrams.map(\.capturedAt)
        await fixture.model.refresh(fixture.accountID)
        XCTAssertEqual(fixture.model.diagrams.map(\.capturedAt), before)
        XCTAssertNotNil(fixture.model.errors[fixture.accountID])
        XCTAssertFalse(fixture.model.refreshing)
    }

    private static func code(_ login: LinkedAccountLogin) throws -> String {
        let state = try XCTUnwrap(URLComponents(url: login.url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "state" }?.value)
        return "test-code#" + state
    }

    private static let identity = "00000000-0000-0000-0000-000000000001:00000000-0000-0000-0000-000000000002"
    private static let profile = #"{"organization":{"uuid":"00000000-0000-0000-0000-000000000001"},"account":{"uuid":"00000000-0000-0000-0000-000000000002","email":"person@example.test"}}"#
    private static let connectedResponses: [(Int, String)] = [
        (200, #"{"access_token":"test-access","refresh_token":"test-refresh","expires_in":28800,"scope":"user:profile"}"#),
        (200, profile), (200, profile),
        (200, #"{"five_hour":{"utilization":77},"seven_day":{"utilization":20},"limits":[{"kind":"weekly_scoped","group":"weekly","percent":35,"scope":{"model":{"display_name":"Fable"}}}]}"#)
    ]

    @MainActor private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "AccountLoginFlowTests." + UUID().uuidString
        let accountID = UUID()
        let defaults: UserDefaults
        let http: LoginHTTP
        let model: LinkedDashboardModel

        init(responses: [(Int, String)]) throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            http = LoginHTTP(responses)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try AccountRegistry(accounts: [ProbeAccount(id: accountID, provider: .claude,
                name: "Personal", identity: AccountLoginFlowTests.identity, requiresSignIn: true)])
                .saving(to: root.appendingPathComponent("accounts.json"))
            model = try LinkedDashboardModel(service: LinkedUsageService(root: root, secrets: LoginSecrets(), http: http), defaults: defaults)
        }
        func cleanUp() {
            model.stop()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}

private final class LoginSecrets: LinkedAccountSecrets, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [LinkedCredentialReference: Data] = [:]
    func read(_ reference: LinkedCredentialReference) throws -> Data? { lock.withLock { values[reference] } }
    func write(_ data: Data, for reference: LinkedCredentialReference) throws { lock.withLock { values[reference] = data } }
    func delete(_ reference: LinkedCredentialReference) throws { lock.withLock { values[reference] = nil } }
}

private actor LoginHTTP: CodexHTTPClient {
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
