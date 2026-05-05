import XCTest
@testable import TokenCoffeeCore

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

    func testFlatObservedTrendIsFineEvenWhenAheadOfLinearBudget() {
        let start = Date(timeIntervalSince1970: 1_000)
        let reset = start.addingTimeInterval(10_080 * 60)
        let now = start.addingTimeInterval(24 * 60 * 60)
        let snapshot = snapshot(usedPercent: 28, reset: reset)
        let samples = [
            sample(at: now.addingTimeInterval(-60 * 60), usedPercent: 28, reset: reset),
            sample(at: now, usedPercent: 28, reset: reset)
        ]

        let projection = QuotaProjectionEngine.make(snapshot: snapshot, samples: samples, now: now)

        XCTAssertEqual(projection.idealWeeklyUsedPercent ?? 0, 14.286, accuracy: 0.001)
        XCTAssertEqual(projection.projectedWeeklyUsedPercentAtReset ?? 0, 28, accuracy: 0.001)
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
        guard let lineSegments = forecast?.lineSegments else {
            XCTFail("Expected forecast line segments")
            return
        }
        XCTAssertEqual(lineSegments.first?.startDate, now)
        XCTAssertEqual(lineSegments.first?.startUsedPercent ?? 0, 10, accuracy: 0.001)
        XCTAssertEqual(lineSegments.first?.kind, .projectedIdle)
        XCTAssertEqual(lineSegments.dropFirst().first?.kind, .projectedActivity)
        XCTAssertEqual(lineSegments.last?.endDate, reset)
        XCTAssertEqual(lineSegments.last?.endUsedPercent ?? 0, forecast?.projectedWeeklyUsedPercentAtReset ?? 0, accuracy: 0.001)
        XCTAssertEqual(lineSegments.filter { $0.kind == .projectedActivity }.count, forecast?.averageRuns.count)
        XCTAssertTrue(lineSegments.filter { $0.kind == .projectedIdle }.allSatisfy {
            abs($0.endUsedPercent - $0.startUsedPercent) < 0.001
        })
        XCTAssertTrue(lineSegments.filter { $0.kind == .projectedActivity }.allSatisfy {
            $0.endUsedPercent > $0.startUsedPercent
        })
        assertForecastLineSegmentsAreConnected(lineSegments)
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

    func testCycleRunForecastLineStartsWithCurrentProjectedActivityInsideRun() {
        let day: TimeInterval = 24 * 60 * 60
        let start = Date(timeIntervalSince1970: 1_000)
        let reset = start.addingTimeInterval(7 * day)
        let now = start.addingTimeInterval(2 * day + 9 * 60 * 60)
        let snapshot = snapshot(usedPercent: 25, reset: reset)
        let samples = [
            sample(at: start.addingTimeInterval(8 * 60 * 60), usedPercent: 0, reset: reset),
            sample(at: start.addingTimeInterval(10 * 60 * 60), usedPercent: 10, reset: reset),
            sample(at: start.addingTimeInterval(day + 8 * 60 * 60), usedPercent: 10, reset: reset),
            sample(at: start.addingTimeInterval(day + 10 * 60 * 60), usedPercent: 20, reset: reset),
            sample(at: start.addingTimeInterval(2 * day + 8 * 60 * 60), usedPercent: 20, reset: reset),
            sample(at: now, usedPercent: 25, reset: reset)
        ]

        let projection = QuotaProjectionEngine.make(snapshot: snapshot, samples: samples, now: now)
        guard let lineSegments = projection.cycleRunForecast?.lineSegments,
              let first = lineSegments.first else {
            XCTFail("Expected forecast line segments")
            return
        }

        XCTAssertEqual(first.kind, .currentProjectedActivity)
        XCTAssertEqual(first.startDate, now)
        XCTAssertEqual(first.startUsedPercent, 25, accuracy: 0.001)
        XCTAssertGreaterThan(first.endUsedPercent, first.startUsedPercent)
        XCTAssertLessThan(first.endUsedPercent - first.startUsedPercent, 6.75)
        XCTAssertEqual(lineSegments.last?.endDate, reset)
        assertForecastLineSegmentsAreConnected(lineSegments)
    }

    func testCycleRunForecastLineStartsFromLiveSnapshotWhenLatestSampleIsStale() {
        let day: TimeInterval = 24 * 60 * 60
        let start = Date(timeIntervalSince1970: 1_000)
        let reset = start.addingTimeInterval(7 * day)
        let now = start.addingTimeInterval(2 * day + 12 * 60 * 60)
        let snapshot = snapshot(usedPercent: 22, reset: reset)
        let samples = [
            sample(at: start.addingTimeInterval(8 * 60 * 60), usedPercent: 0, reset: reset),
            sample(at: start.addingTimeInterval(10 * 60 * 60), usedPercent: 10, reset: reset),
            sample(at: start.addingTimeInterval(day + 8 * 60 * 60), usedPercent: 10, reset: reset),
            sample(at: start.addingTimeInterval(day + 10 * 60 * 60), usedPercent: 20, reset: reset),
            sample(at: now.addingTimeInterval(-60), usedPercent: 20, reset: reset)
        ]

        let projection = QuotaProjectionEngine.make(snapshot: snapshot, samples: samples, now: now)
        guard let first = projection.cycleRunForecast?.lineSegments.first else {
            XCTFail("Expected forecast line segment")
            return
        }

        XCTAssertEqual(first.startDate, now)
        XCTAssertEqual(first.startUsedPercent, 22, accuracy: 0.001)
    }

    func testCycleRunForecastMergesShortFlatGapInsideActivityPeriod() {
        let day: TimeInterval = 24 * 60 * 60
        let hour: TimeInterval = 60 * 60
        let start = Date(timeIntervalSince1970: 1_000)
        let reset = start.addingTimeInterval(7 * day)
        let now = start.addingTimeInterval(13 * hour)
        let snapshot = snapshot(usedPercent: 10, reset: reset)
        let samples = [
            sample(at: start.addingTimeInterval(9 * hour), usedPercent: 0, reset: reset),
            sample(at: start.addingTimeInterval(10 * hour), usedPercent: 5, reset: reset),
            sample(at: start.addingTimeInterval(11 * hour), usedPercent: 5, reset: reset),
            sample(at: start.addingTimeInterval(12 * hour), usedPercent: 10, reset: reset),
            sample(at: now, usedPercent: 10, reset: reset)
        ]

        let projection = QuotaProjectionEngine.make(snapshot: snapshot, samples: samples, now: now)
        guard let forecast = projection.cycleRunForecast else {
            XCTFail("Expected cycle forecast")
            return
        }

        XCTAssertEqual(forecast.averageRuns.count, 6)
        XCTAssertEqual(forecast.lineSegments.filter { $0.kind == .projectedActivity }.count, 6)
        XCTAssertTrue(forecast.lineSegments.filter { $0.kind == .projectedActivity }.allSatisfy {
            abs($0.endUsedPercent - $0.startUsedPercent - 10) < 0.001
        })
        assertForecastLineSegmentsAreConnected(forecast.lineSegments)
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

    private func assertForecastLineSegmentsAreConnected(
        _ segments: [QuotaForecastLineSegment],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for (previous, next) in zip(segments, segments.dropFirst()) {
            XCTAssertEqual(previous.endDate, next.startDate, file: file, line: line)
            XCTAssertEqual(previous.endUsedPercent, next.startUsedPercent, accuracy: 0.001, file: file, line: line)
            XCTAssertNotEqual(previous.kind, next.kind, file: file, line: line)
        }
    }
}
