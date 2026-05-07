import XCTest
@testable import TokenCoffeeCore

final class DemoQuotaDataTests: XCTestCase {
    func testBundledDemoQuotaDataProjectsNearTargetEstimate() throws {
        let data = try Data(contentsOf: Self.demoQuotaDataURL)
        let fixture = try JSONDecoder().decode(DemoQuotaData.self, from: data)
        let now = Date(timeIntervalSince1970: 2_000_000_000)

        let scenario = try fixture.makeScenario(referenceDate: now)
        let weekly = try XCTUnwrap(scenario.snapshot.secondary)
        let resetDate = try XCTUnwrap(weekly.resetDate)
        let windowStart = resetDate.addingTimeInterval(-TimeInterval(10_080 * 60))

        XCTAssertEqual(weekly.windowDurationMins, 10_080)
        XCTAssertEqual(now.timeIntervalSince(windowStart), TimeInterval(5_040 * 60), accuracy: 0.001)
        XCTAssertEqual(resetDate.timeIntervalSince(now), TimeInterval(5_040 * 60), accuracy: 0.001)
        XCTAssertEqual(scenario.samples.first?.capturedAt, windowStart)
        XCTAssertEqual(scenario.samples.last?.capturedAt, now)
        XCTAssertTrue(scenario.samples.allSatisfy { $0.capturedAt <= now })
        XCTAssertEqual(scenario.snapshot.secondary?.usedPercent ?? 0, 66, accuracy: 0.001)

        let projection = QuotaProjectionEngine.make(
            snapshot: scenario.snapshot,
            samples: scenario.samples,
            now: scenario.now
        )
        let forecast = try XCTUnwrap(projection.cycleRunForecast)

        XCTAssertEqual(forecast.projectedWeeklyUsedPercentAtReset, 132, accuracy: 10)
        XCTAssertEqual(projection.paceState, .slowDown)
    }

    private static var demoQuotaDataURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TokenCoffeeApp/Resources/DemoQuotaData.json")
    }
}
