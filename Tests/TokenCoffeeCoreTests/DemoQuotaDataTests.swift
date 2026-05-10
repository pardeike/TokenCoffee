import XCTest
@testable import TokenCoffeeCore

final class DemoQuotaDataTests: XCTestCase {
    func testBundledDemoQuotaDataLoadsRealWorldTrace() throws {
        let data = try Data(contentsOf: Self.demoQuotaDataURL)
        let fixture = try JSONDecoder().decode(DemoQuotaData.self, from: data)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let elapsedWindowSeconds = try XCTUnwrap(fixture.elapsedWindowSeconds)
        let firstOffsetSeconds = try XCTUnwrap(fixture.samples.first?.offsetSeconds)

        let scenario = try fixture.makeScenario(referenceDate: now)
        let weekly = try XCTUnwrap(scenario.snapshot.secondary)
        let fiveHour = try XCTUnwrap(scenario.snapshot.primary)
        let resetDate = try XCTUnwrap(weekly.resetDate)
        let firstSample = try XCTUnwrap(scenario.samples.first)
        let weeklyWindowSeconds = TimeInterval(fixture.weeklyWindowMinutes * 60)
        let windowStart = resetDate.addingTimeInterval(-weeklyWindowSeconds)

        XCTAssertEqual(weekly.windowDurationMins, fixture.weeklyWindowMinutes)
        XCTAssertEqual(now.timeIntervalSince(windowStart), TimeInterval(elapsedWindowSeconds), accuracy: 0.001)
        XCTAssertEqual(resetDate.timeIntervalSince(now), weeklyWindowSeconds - TimeInterval(elapsedWindowSeconds), accuracy: 0.001)
        XCTAssertEqual(
            firstSample.capturedAt.timeIntervalSince(windowStart),
            TimeInterval(firstOffsetSeconds),
            accuracy: 0.001
        )
        XCTAssertEqual(scenario.samples.last?.capturedAt, now)
        XCTAssertEqual(scenario.samples.count, fixture.samples.count)
        XCTAssertTrue(scenario.samples.allSatisfy { $0.capturedAt <= now })
        XCTAssertEqual(weekly.usedPercent, 72, accuracy: 0.001)
        XCTAssertEqual(fiveHour.usedPercent, 45, accuracy: 0.001)

        let projection = QuotaProjectionEngine.make(
            snapshot: scenario.snapshot,
            samples: scenario.samples,
            now: scenario.now
        )
        let forecast = try XCTUnwrap(projection.cycleRunForecast)

        XCTAssertEqual(forecast.lowProjectedWeeklyUsedPercentAtReset, 96.034, accuracy: 0.001)
        XCTAssertEqual(forecast.highProjectedWeeklyUsedPercentAtReset, 144.705, accuracy: 0.001)
        XCTAssertGreaterThan(forecast.highProjectedWeeklyUsedPercentAtReset - forecast.lowProjectedWeeklyUsedPercentAtReset, 40)
        let firstHighSegment = try XCTUnwrap(forecast.highLineSegments.first)
        XCTAssertEqual(firstHighSegment.kind, .projectedIdle)
        XCTAssertEqual(firstHighSegment.startDate, scenario.now)
        XCTAssertGreaterThan(firstHighSegment.endUsedPercent, firstHighSegment.startUsedPercent)
        XCTAssertTrue(forecast.highLineSegments.contains { $0.kind == .currentProjectedActivity })
        XCTAssertEqual(forecast.lowLineSegments.first?.kind, .projectedIdle)
        XCTAssertFalse(forecast.observedIntensityRuns.isEmpty)

        var futureDayGains: [Double] = []
        for dayIndex in 5...6 {
            let dayStart = windowStart.addingTimeInterval(TimeInterval(dayIndex * 24 * 60 * 60))
            let dayEnd = windowStart.addingTimeInterval(TimeInterval((dayIndex + 1) * 24 * 60 * 60))
            let gain = activityGain(
                in: forecast.highLineSegments,
                startDate: dayStart,
                endDate: dayEnd
            )
            futureDayGains.append(gain)
        }
        XCTAssertGreaterThan(futureDayGains.reduce(0, +), 25)
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
