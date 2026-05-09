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

        XCTAssertEqual(forecast.lowProjectedWeeklyUsedPercentAtReset, 120.179, accuracy: 0.001)
        XCTAssertEqual(forecast.highProjectedWeeklyUsedPercentAtReset, 168.503, accuracy: 0.001)
        XCTAssertGreaterThan(forecast.highProjectedWeeklyUsedPercentAtReset - forecast.lowProjectedWeeklyUsedPercentAtReset, 40)
        let futureDayGains = (4...6).map { dayIndex in
            activityGain(
                in: forecast.highLineSegments,
                startDate: windowStart.addingTimeInterval(TimeInterval(dayIndex * 24 * 60 * 60)),
                endDate: windowStart.addingTimeInterval(TimeInterval((dayIndex + 1) * 24 * 60 * 60))
            )
        }
        XCTAssertTrue(futureDayGains.allSatisfy { $0 > 20 }, "\(futureDayGains)")
        XCTAssertLessThan((futureDayGains.max() ?? 0) / max(0.001, futureDayGains.min() ?? 0), 2)
        XCTAssertEqual(projection.paceState, .slowDown)
    }

    private static var demoQuotaDataURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TokenCoffeeApp/Resources/DemoQuotaData.json")
    }

    private func activityGain(
        in segments: [QuotaForecastLineSegment],
        startDate: Date,
        endDate: Date
    ) -> Double {
        segments.reduce(0) { total, segment in
            guard segment.kind != .projectedIdle,
                  segment.endDate > startDate,
                  segment.startDate < endDate else {
                return total
            }

            let overlapStart = max(segment.startDate, startDate)
            let overlapEnd = min(segment.endDate, endDate)
            let segmentDuration = segment.endDate.timeIntervalSince(segment.startDate)
            guard overlapEnd > overlapStart,
                  segmentDuration > 0 else {
                return total
            }

            let overlapFraction = overlapEnd.timeIntervalSince(overlapStart) / segmentDuration
            return total + (segment.endUsedPercent - segment.startUsedPercent) * overlapFraction
        }
    }
}
