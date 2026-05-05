import XCTest
@testable import TokenHelperCore

final class QuotaProjectionTests: XCTestCase {
    func testFallbackProjectionUsesElapsedWindowFraction() {
        let start = Date(timeIntervalSince1970: 1_000)
        let reset = start.addingTimeInterval(10_080 * 60)
        let now = start.addingTimeInterval(10_080 * 60 / 2)
        let snapshot = snapshot(usedPercent: 30, reset: reset)

        let projection = QuotaProjectionEngine.make(snapshot: snapshot, samples: [], now: now)

        XCTAssertEqual(projection.currentWeeklyUsedPercent, 30)
        XCTAssertEqual(projection.idealWeeklyUsedPercent ?? 0, 50, accuracy: 0.001)
        XCTAssertEqual(projection.projectedWeeklyUsedPercentAtReset ?? 0, 60, accuracy: 0.001)
        XCTAssertEqual(projection.paceState, .fine)
    }

    func testRecentSlopeProjectionCanWarn() {
        let start = Date(timeIntervalSince1970: 1_000)
        let reset = start.addingTimeInterval(10_080 * 60)
        let now = start.addingTimeInterval(2 * 24 * 60 * 60)
        let snapshot = snapshot(usedPercent: 55, reset: reset)
        let samples = [
            sample(at: now.addingTimeInterval(-60 * 60), usedPercent: 45, reset: reset),
            sample(at: now, usedPercent: 55, reset: reset)
        ]

        let projection = QuotaProjectionEngine.make(snapshot: snapshot, samples: samples, now: now)

        XCTAssertGreaterThan(projection.projectedWeeklyUsedPercentAtReset ?? 0, 100)
        XCTAssertEqual(projection.paceState, .slowDown)
    }

    func testBurstAwareProjectionUsesObservedCadenceInsteadOfRecentClump() {
        let start = Date(timeIntervalSince1970: 1_000)
        let reset = start.addingTimeInterval(10_080 * 60)
        let now = start.addingTimeInterval(2 * 24 * 60 * 60)
        let snapshot = snapshot(usedPercent: 20, reset: reset)
        let samples = [
            sample(at: start, usedPercent: 0, reset: reset),
            sample(at: start.addingTimeInterval(60 * 60), usedPercent: 0, reset: reset),
            sample(at: start.addingTimeInterval(60 * 60 + 60), usedPercent: 10, reset: reset),
            sample(at: now.addingTimeInterval(-2 * 60 * 60), usedPercent: 10, reset: reset),
            sample(at: now.addingTimeInterval(-60 * 60), usedPercent: 10, reset: reset),
            sample(at: now.addingTimeInterval(-60 * 60 + 60), usedPercent: 20, reset: reset),
            sample(at: now, usedPercent: 20, reset: reset)
        ]

        let projection = QuotaProjectionEngine.make(snapshot: snapshot, samples: samples, now: now)

        XCTAssertEqual(projection.projectedWeeklyUsedPercentAtReset ?? 0, 70, accuracy: 0.001)
        XCTAssertEqual(projection.paceState, .fine)
    }

    func testActiveBurstContinuationIsCappedAtTypicalBurstGain() {
        let start = Date(timeIntervalSince1970: 1_000)
        let reset = start.addingTimeInterval(10_080 * 60)
        let now = start.addingTimeInterval(2 * 24 * 60 * 60)
        let snapshot = snapshot(usedPercent: 20, reset: reset)
        let samples = [
            sample(at: start, usedPercent: 0, reset: reset),
            sample(at: start.addingTimeInterval(60 * 60), usedPercent: 0, reset: reset),
            sample(at: start.addingTimeInterval(60 * 60 + 60), usedPercent: 10, reset: reset),
            sample(at: now.addingTimeInterval(-6 * 60), usedPercent: 10, reset: reset),
            sample(at: now.addingTimeInterval(-5 * 60), usedPercent: 20, reset: reset)
        ]

        let projection = QuotaProjectionEngine.make(snapshot: snapshot, samples: samples, now: now)

        XCTAssertEqual(projection.projectedWeeklyUsedPercentAtReset ?? 0, 80, accuracy: 0.001)
        XCTAssertEqual(projection.paceState, .fine)
    }

    func testCycleRunForecastRepeatsResetAlignedOvernightRuns() {
        let day: TimeInterval = 24 * 60 * 60
        let start = Date(timeIntervalSince1970: 1_000)
        let reset = start.addingTimeInterval(7 * day)
        let now = start.addingTimeInterval(2 * day + 12 * 60 * 60)
        let snapshot = snapshot(usedPercent: 10, reset: reset)
        let samples = [
            sample(at: start.addingTimeInterval(18 * 60 * 60), usedPercent: 0, reset: reset),
            sample(at: start.addingTimeInterval(27 * 60 * 60), usedPercent: 5, reset: reset),
            sample(at: start.addingTimeInterval(day + 18 * 60 * 60), usedPercent: 5, reset: reset),
            sample(at: start.addingTimeInterval(day + 27 * 60 * 60), usedPercent: 10, reset: reset),
            sample(at: now, usedPercent: 10, reset: reset)
        ]

        let projection = QuotaProjectionEngine.make(snapshot: snapshot, samples: samples, now: now)
        let forecast = projection.cycleRunForecast

        XCTAssertNotNil(forecast)
        XCTAssertEqual(forecast?.projectedWeeklyUsedPercentAtReset ?? 0, 33.333, accuracy: 0.001)
        XCTAssertEqual(forecast?.averageRuns.count, 5)
        XCTAssertEqual(forecast?.averageRuns.first?.startDate, start.addingTimeInterval(2 * day + 18 * 60 * 60))
        XCTAssertEqual(forecast?.averageRuns.first?.endDate, start.addingTimeInterval(3 * day + 3 * 60 * 60))
        if let averageRuns = forecast?.averageRuns {
            XCTAssertTrue(zip(averageRuns, averageRuns.dropFirst()).allSatisfy { previous, next in
                abs(previous.endUsedPercent - next.startUsedPercent) < 0.001
            })
        }
        XCTAssertEqual(forecast?.ghostRuns.count, 10)
        XCTAssertEqual(forecast?.ghostRuns.first?.startDate, start.addingTimeInterval(2 * day + 18 * 60 * 60))
        XCTAssertEqual(forecast?.ghostRuns.first?.endDate, start.addingTimeInterval(3 * day + 3 * 60 * 60))
        XCTAssertEqual(forecast?.ghostRuns.first?.startUsedPercent ?? 0, 10, accuracy: 0.001)
        XCTAssertEqual(forecast?.ghostRuns.first?.endUsedPercent ?? 0, 15, accuracy: 0.001)
        XCTAssertEqual(forecast?.corridorPoints.first?.date, now)
        XCTAssertEqual(forecast?.corridorPoints.last?.date, reset)
        XCTAssertTrue(forecast?.corridorPoints.allSatisfy { $0.lowerUsedPercent <= $0.upperUsedPercent } ?? false)
    }

    func testCycleRunForecastWeightsCurrentCycleGainOverHistory() {
        let day: TimeInterval = 24 * 60 * 60
        let start = Date(timeIntervalSince1970: 1_000)
        let reset = start.addingTimeInterval(7 * day)
        let now = start.addingTimeInterval(2 * day + 12 * 60 * 60)
        let snapshot = snapshot(usedPercent: 30, reset: reset)
        let samples = [
            sample(at: start.addingTimeInterval(8 * 60 * 60), usedPercent: 0, reset: reset),
            sample(at: start.addingTimeInterval(10 * 60 * 60), usedPercent: 10, reset: reset),
            sample(at: start.addingTimeInterval(2 * day + 8 * 60 * 60), usedPercent: 10, reset: reset),
            sample(at: start.addingTimeInterval(2 * day + 10 * 60 * 60), usedPercent: 30, reset: reset),
            sample(at: now, usedPercent: 30, reset: reset)
        ]

        let projection = QuotaProjectionEngine.make(snapshot: snapshot, samples: samples, now: now)
        let forecast = projection.cycleRunForecast

        XCTAssertNotNil(forecast)
        XCTAssertEqual(forecast?.projectedWeeklyUsedPercentAtReset ?? 0, 96, accuracy: 0.001)
        XCTAssertEqual(forecast?.averageRuns.count, 4)
        XCTAssertEqual(forecast?.ghostRuns.count, 8)
    }

    func testCycleRunForecastRequiresUsageIncreases() {
        let start = Date(timeIntervalSince1970: 1_000)
        let reset = start.addingTimeInterval(10_080 * 60)
        let now = start.addingTimeInterval(2 * 24 * 60 * 60)
        let snapshot = snapshot(usedPercent: 10, reset: reset)
        let samples = [
            sample(at: start, usedPercent: 10, reset: reset),
            sample(at: now.addingTimeInterval(-60 * 60), usedPercent: 10, reset: reset),
            sample(at: now, usedPercent: 10, reset: reset)
        ]

        let projection = QuotaProjectionEngine.make(snapshot: snapshot, samples: samples, now: now)

        XCTAssertNil(projection.cycleRunForecast)
    }

    func testMissingSnapshotProducesNoDataProjection() {
        let projection = QuotaProjectionEngine.make(snapshot: nil, samples: [])

        XCTAssertEqual(projection.paceState, .noData)
        XCTAssertNil(projection.weeklyResetDate)
    }

    private func snapshot(usedPercent: Double, reset: Date) -> RateLimitSnapshot {
        RateLimitSnapshot(
            limitId: "codex",
            limitName: nil,
            primary: RateLimitWindow(usedPercent: 5, windowDurationMins: 300, resetsAt: Int(reset.timeIntervalSince1970) - 3_600),
            secondary: RateLimitWindow(usedPercent: usedPercent, windowDurationMins: 10_080, resetsAt: Int(reset.timeIntervalSince1970)),
            credits: nil,
            planType: "pro",
            rateLimitReachedType: nil
        )
    }

    private func sample(at date: Date, usedPercent: Double, reset: Date) -> QuotaSample {
        QuotaSample(
            capturedAt: date,
            limitId: "codex",
            limitName: nil,
            weeklyUsedPercent: usedPercent,
            weeklyWindowMinutes: 10_080,
            weeklyResetsAt: reset,
            fiveHourUsedPercent: 5,
            fiveHourWindowMinutes: 300,
            fiveHourResetsAt: date.addingTimeInterval(60 * 60),
            planType: "pro",
            rateLimitReachedType: nil
        )
    }
}
