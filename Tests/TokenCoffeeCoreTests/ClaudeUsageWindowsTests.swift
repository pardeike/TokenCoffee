import XCTest
@testable import TokenCoffeeCore

final class ClaudeUsageWindowsTests: XCTestCase {
    private let liveShape = #"{"five_hour":{"utilization":100,"resets_at":"2026-09-13T23:00:00.439938+00:00"},"seven_day":{"utilization":26,"resets_at":"2026-09-19T22:00:00.439961+00:00"},"limits":[{"kind":"session","group":"session","percent":100,"is_active":true,"scope":null},{"kind":"weekly_all","group":"weekly","percent":26,"is_active":false,"scope":null},{"kind":"weekly_scoped","group":"weekly","percent":41,"resets_at":"2026-09-19T22:00:00.440152+00:00","is_active":false,"scope":{"model":{"id":null,"display_name":"Fable"}}}]}"#

    func testLiveFableShapeDoesNotConfuseActiveWithAvailable() throws {
        let result = try ClaudeUsageReading.decode(Data(liveShape.utf8))
        XCTAssertEqual(result.diagrams.map(\.title), ["General", "Fable"])
        XCTAssertEqual(result.diagrams.map(\.id), ["general", "model-name:fable"])
        XCTAssertEqual(result.diagrams.map(\.usedPercent), [26, 41])
        XCTAssertEqual(result.session?.usedPercent, 100)
        XCTAssertNotNil(result.diagrams.last?.resetsAt)
    }

    func testClaudeSessionIsAnIndependentFiveHourChart() throws {
        let reading = try ClaudeUsageReading.decode(Data(liveShape.utf8))
        let charts = LinkedUsageService.claudeSnapshots(reading, plan: nil)
        XCTAssertEqual(charts.map { $0.0 }, ["session", "general", "model-name:fable"])
        XCTAssertEqual(charts.map { $0.1 }, ["5h", "General", "Fable"])
        XCTAssertEqual(charts.map { $0.2.secondary?.usedPercent }, [100, 26, 41])
        XCTAssertEqual(charts.map { $0.2.secondary?.windowDurationMins }, [300, 10_080, 10_080])
        XCTAssertNil(charts[0].2.primary)
        XCTAssertEqual(charts[1].2.primary, reading.session)
        XCTAssertEqual(charts[2].2.primary, reading.session)
        let noSession = try ClaudeUsageReading.decode(Data(#"{"seven_day":{"utilization":26}}"#.utf8))
        XCTAssertEqual(LinkedUsageService.claudeSnapshots(noSession, plan: nil).map { $0.0 }, ["general"])
        let onlySession = try ClaudeUsageReading.decode(Data(#"{"five_hour":{"utilization":100}}"#.utf8))
        XCTAssertEqual(LinkedUsageService.claudeSnapshots(onlySession, plan: nil).map { $0.0 }, ["session"])
    }

    @MainActor func testRenamePersistsOnlyAccountNameAndRejectsInvalidInput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let account = ProbeAccount(id: id, provider: .claude, name: "original@example.test", email: "original@example.test",
            identity: "organization:member", claudeDirectory: UUID())
        let other = ProbeAccount(id: UUID(), provider: .codex, name: "Work", identity: "codex-account")
        let original = AccountRegistry(accounts: [account, other], pendingCodexID: UUID())
        let url = root.appendingPathComponent("accounts.json")
        try original.saving(to: url)
        let service = try LinkedUsageService(root: root)
        _ = try await service.rename(id, to: "  Personal  ")
        var expected = original
        expected.accounts[0].name = "Personal"
        XCTAssertEqual(try JSONDecoder().decode(AccountRegistry.self, from: Data(contentsOf: url)), expected)
        let reopened = try LinkedUsageService(root: root)
        let accounts = await reopened.accounts()
        XCTAssertEqual(accounts.first?.name, "Personal")
        for invalid in [" ", "two\nlines", String(repeating: "x", count: 61)] {
            do { _ = try await service.rename(id, to: invalid); XCTFail("Invalid name accepted") }
            catch is NativeUsage.Failure { }
        }
        XCTAssertEqual(try JSONDecoder().decode(AccountRegistry.self, from: Data(contentsOf: url)), expected)
    }

    func testProviderIDWinsOverDisplayName() throws {
        let original = liveShape.replacingOccurrences(of: "\"id\":null", with: "\"id\":\"model-1\"")
        let renamed = original.replacingOccurrences(of: "Fable", with: "New name")
        let first = try ClaudeUsageReading.decode(Data(original.utf8))
        let second = try ClaudeUsageReading.decode(Data(renamed.utf8))
        XCTAssertEqual(first.diagrams.last?.id, "model:model-1")
        XCTAssertEqual(first.diagrams.last?.id, second.diagrams.last?.id)
        XCTAssertEqual(second.diagrams.last?.title, "New name")
    }

    func testMissingScopedLimitDoesNotInventOne() throws {
        let result = try ClaudeUsageReading.decode(Data(#"{"seven_day":{"utilization":0},"limits":null}"#.utf8))
        XCTAssertEqual(result.diagrams.map(\.title), ["General"])
        XCTAssertNil(result.session)
    }

    func testSubsecondResetDoesNotAdvertiseThePreviousMinute() throws {
        let json = #"{"five_hour":{"utilization":100,"resets_at":"2026-09-13T22:59:59.999Z"},"seven_day":{"utilization":26}}"#
        let result = try ClaudeUsageReading.decode(Data(json.utf8))
        XCTAssertEqual(result.session?.resetDate, ISO8601DateFormatter().date(from: "2026-09-13T23:00:00Z"))
    }

    func testMalformedReadingIsNotZeroUsage() {
        for json in [#"{"seven_day":{"utilization":101}}"#, #"{"seven_day":{"utilization":-1}}"#,
                     #"{"seven_day":{"utilization":26,"resets_at":"bad"}}"#, #"{}"#] {
            XCTAssertThrowsError(try ClaudeUsageReading.decode(Data(json.utf8)))
        }
    }

    func testDuplicateScopeIsRejected() {
        let json = #"{"limits":[{"kind":"weekly_scoped","group":"weekly","percent":41,"scope":{"model":{"display_name":"Fable"}}},{"kind":"weekly_scoped","group":"weekly","percent":42,"scope":{"model":{"display_name":"Fable"}}}]}"#
        XCTAssertThrowsError(try ClaudeUsageReading.decode(Data(json.utf8)))
    }

    func testCodexSingleThirtyDayWindowIsNotPresentedAsFiveHours() throws {
        let window = RateLimitWindow(usedPercent: 0, windowDurationMins: 43_200, resetsAt: 1_800_000_000)
        let raw = RateLimitSnapshot(limitId: "codex", limitName: nil, primary: window, secondary: nil,
            credits: nil, planType: "free", rateLimitReachedType: nil)
        let normalized = try LinkedUsageService.normalizeCodex(raw)
        XCTAssertEqual(normalized.secondary, window)
        XCTAssertNil(normalized.primary)
        XCTAssertEqual(QuotaSample(snapshot: normalized, capturedAt: Date())?.weeklyWindowMinutes, 43_200)
    }
}
