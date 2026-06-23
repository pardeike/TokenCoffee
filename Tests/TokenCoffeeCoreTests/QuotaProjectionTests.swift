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
        XCTAssertGreaterThan(projection.cycleRunForecast?.highProjectedWeeklyUsedPercentAtReset ?? 0, 100)
        XCTAssertEqual(projection.paceState, .slowDown)
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
        XCTAssertGreaterThan(projection.cycleRunForecast?.highProjectedWeeklyUsedPercentAtReset ?? 0, 100)
        XCTAssertEqual(projection.paceState, .slowDown)
    }

    func testCycleRunForecastReplaysSparseOvernightRunsIntoLowPath() {
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
        guard let forecast = projection.cycleRunForecast else {
            XCTFail("Expected cycle forecast")
            return
        }

        XCTAssertGreaterThan(forecast.lowProjectedWeeklyUsedPercentAtReset, 20)
        XCTAssertLessThan(forecast.lowProjectedWeeklyUsedPercentAtReset, 30)
        XCTAssertGreaterThan(forecast.highProjectedWeeklyUsedPercentAtReset, forecast.lowProjectedWeeklyUsedPercentAtReset)
        XCTAssertFalse(forecast.averageRuns.isEmpty)
        XCTAssertFalse(forecast.ghostRuns.isEmpty)
        XCTAssertTrue(forecast.observedIntensityRuns.allSatisfy { $0.startDate < now && $0.endDate <= now })

        let lineSegments = forecast.lineSegments
        guard lineSegments.isEmpty == false else {
            XCTFail("Expected forecast line segments")
            return
        }
        XCTAssertEqual(lineSegments.first?.startDate, now)
        XCTAssertEqual(lineSegments.first?.startUsedPercent ?? 0, 10, accuracy: 0.001)
        XCTAssertEqual(lineSegments.last?.endDate, reset)
        XCTAssertEqual(lineSegments.last?.endUsedPercent ?? 0, forecast.projectedWeeklyUsedPercentAtReset, accuracy: 0.001)
        XCTAssertTrue(lineSegments.contains { $0.kind == .projectedActivity })
        XCTAssertTrue(forecast.highLineSegments.contains { $0.kind != .projectedIdle })
        assertForecastLineSegmentsAreConnected(lineSegments)
        XCTAssertEqual(forecast.corridorPoints.first?.date, now)
        XCTAssertEqual(forecast.corridorPoints.last?.date, reset)
        XCTAssertTrue(forecast.corridorPoints.allSatisfy { $0.lowerUsedPercent <= $0.upperUsedPercent })
    }

    func testCycleRunForecastBuildsOrderedScenarioLinesForBlendedHotspots() {
        let day: TimeInterval = 24 * 60 * 60
        let hour: TimeInterval = 60 * 60
        let start = Date(timeIntervalSince1970: 1_000)
        let reset = start.addingTimeInterval(7 * day)
        let now = start.addingTimeInterval(3 * day + 12 * hour)
        let snapshot = snapshot(usedPercent: 37, reset: reset)
        let samples = [
            sample(at: start.addingTimeInterval(8 * hour), usedPercent: 0, reset: reset),
            sample(at: start.addingTimeInterval(9 * hour), usedPercent: 4, reset: reset),
            sample(at: start.addingTimeInterval(18 * hour), usedPercent: 4, reset: reset),
            sample(at: start.addingTimeInterval(19 * hour), usedPercent: 8, reset: reset),
            sample(at: start.addingTimeInterval(day + 8 * hour), usedPercent: 8, reset: reset),
            sample(at: start.addingTimeInterval(day + 9 * hour), usedPercent: 13, reset: reset),
            sample(at: start.addingTimeInterval(day + 18 * hour), usedPercent: 13, reset: reset),
            sample(at: start.addingTimeInterval(day + 19 * hour), usedPercent: 19, reset: reset),
            sample(at: start.addingTimeInterval(2 * day + 8 * hour), usedPercent: 19, reset: reset),
            sample(at: start.addingTimeInterval(2 * day + 9 * hour), usedPercent: 26, reset: reset),
            sample(at: start.addingTimeInterval(2 * day + 18 * hour), usedPercent: 26, reset: reset),
            sample(at: start.addingTimeInterval(2 * day + 19 * hour), usedPercent: 37, reset: reset),
            sample(at: now, usedPercent: 37, reset: reset)
        ]

        let projection = QuotaProjectionEngine.make(snapshot: snapshot, samples: samples, now: now)
        guard let forecast = projection.cycleRunForecast else {
            XCTFail("Expected cycle forecast")
            return
        }

        let highFutureDayGains = (4...6).map { dayIndex in
            activityGain(
                in: forecast.highLineSegments,
                startDate: start.addingTimeInterval(Double(dayIndex) * day),
                endDate: start.addingTimeInterval(Double(dayIndex + 1) * day)
            )
        }
        let lowFutureDayGains = (4...6).map { dayIndex in
            activityGain(
                in: forecast.lowLineSegments,
                startDate: start.addingTimeInterval(Double(dayIndex) * day),
                endDate: start.addingTimeInterval(Double(dayIndex + 1) * day)
            )
        }

        XCTAssertTrue(highFutureDayGains.allSatisfy { $0 >= 0 }, "\(highFutureDayGains)")
        XCTAssertTrue(lowFutureDayGains.allSatisfy { $0 >= 0 }, "\(lowFutureDayGains)")
        XCTAssertGreaterThanOrEqual(highFutureDayGains.reduce(0, +), lowFutureDayGains.reduce(0, +))
        XCTAssertGreaterThanOrEqual(
            forecast.highLineSegments.filter { $0.kind == .projectedActivity }.count,
            forecast.lowLineSegments.filter { $0.kind == .projectedActivity }.count
        )
        XCTAssertGreaterThanOrEqual(
            forecast.highProjectedWeeklyUsedPercentAtReset,
            forecast.lowProjectedWeeklyUsedPercentAtReset
        )
        assertForecastLineSegmentsAreConnected(forecast.lowLineSegments)
        assertForecastLineSegmentsAreConnected(forecast.highLineSegments)
    }

    func testCycleRunForecastReplaysCurrentCycleGainIntoLowPath() {
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
        XCTAssertGreaterThan(forecast?.lowProjectedWeeklyUsedPercentAtReset ?? 0, 65)
        XCTAssertLessThan(forecast?.lowProjectedWeeklyUsedPercentAtReset ?? 0, 80)
        XCTAssertGreaterThan(
            forecast?.highProjectedWeeklyUsedPercentAtReset ?? 0,
            forecast?.lowProjectedWeeklyUsedPercentAtReset ?? 0
        )
        XCTAssertFalse(forecast?.averageRuns.isEmpty ?? true)
        XCTAssertTrue(forecast?.highLineSegments.contains { $0.kind != .projectedIdle } ?? false)
        XCTAssertEqual(projection.paceState, .slowDown)
    }

    func testCycleRunForecastCreatesWideHighWedgeWhenDailyHotspotsAccelerate() {
        let day: TimeInterval = 24 * 60 * 60
        let hour: TimeInterval = 60 * 60
        let start = Date(timeIntervalSince1970: 1_000)
        let reset = start.addingTimeInterval(7 * day)
        let now = start.addingTimeInterval(4 * day + 6 * hour)
        let snapshot = snapshot(usedPercent: 50, reset: reset)
        let samples = [
            sample(at: start.addingTimeInterval(8 * hour), usedPercent: 30, reset: reset),
            sample(at: start.addingTimeInterval(9 * hour), usedPercent: 32, reset: reset),
            sample(at: start.addingTimeInterval(day + 8 * hour), usedPercent: 32, reset: reset),
            sample(at: start.addingTimeInterval(day + 9 * hour), usedPercent: 35, reset: reset),
            sample(at: start.addingTimeInterval(2 * day + 8 * hour), usedPercent: 35, reset: reset),
            sample(at: start.addingTimeInterval(2 * day + 9 * hour), usedPercent: 38, reset: reset),
            sample(at: start.addingTimeInterval(3 * day + 8 * hour), usedPercent: 38, reset: reset),
            sample(at: start.addingTimeInterval(3 * day + 9 * hour), usedPercent: 49, reset: reset),
            sample(at: start.addingTimeInterval(4 * day + 5 * hour), usedPercent: 49, reset: reset),
            sample(at: start.addingTimeInterval(4 * day + 5.5 * hour), usedPercent: 50, reset: reset),
            sample(at: now, usedPercent: 50, reset: reset)
        ]

        let projection = QuotaProjectionEngine.make(snapshot: snapshot, samples: samples, now: now)
        guard let forecast = projection.cycleRunForecast else {
            XCTFail("Expected cycle forecast")
            return
        }

        XCTAssertGreaterThan(forecast.lowProjectedWeeklyUsedPercentAtReset, 60)
        XCTAssertLessThan(forecast.lowProjectedWeeklyUsedPercentAtReset, 75)
        XCTAssertGreaterThan(forecast.highProjectedWeeklyUsedPercentAtReset, forecast.lowProjectedWeeklyUsedPercentAtReset)
        XCTAssertGreaterThan(forecast.highProjectedWeeklyUsedPercentAtReset, 90)
        XCTAssertLessThan(forecast.highProjectedWeeklyUsedPercentAtReset, 130)
        XCTAssertEqual(projection.paceState, .watch)
        XCTAssertTrue(forecast.highLineSegments.contains { $0.kind == .projectedActivity })
        assertForecastLineSegmentsAreConnected(forecast.lowLineSegments)
        assertForecastLineSegmentsAreConnected(forecast.highLineSegments)
    }

    func testCycleRunForecastTreatsTinyPostIdleActivityAsWeakEvidence() {
        let day: TimeInterval = 24 * 60 * 60
        let hour: TimeInterval = 60 * 60
        let minute: TimeInterval = 60
        let start = Date(timeIntervalSince1970: 1_000)
        let reset = start.addingTimeInterval(7 * day)
        let now = start.addingTimeInterval(day + 12 * hour)
        let snapshot = snapshot(usedPercent: 15, reset: reset)
        let samples = [
            sample(at: start.addingTimeInterval(1 * hour), usedPercent: 0, reset: reset),
            sample(at: start.addingTimeInterval(5 * hour), usedPercent: 13, reset: reset),
            sample(at: now.addingTimeInterval(-20 * minute), usedPercent: 13, reset: reset),
            sample(at: now, usedPercent: 15, reset: reset)
        ]

        let projection = QuotaProjectionEngine.make(snapshot: snapshot, samples: samples, now: now)
        guard let forecast = projection.cycleRunForecast else {
            XCTFail("Expected cycle forecast")
            return
        }

        XCTAssertGreaterThan(forecast.highProjectedWeeklyUsedPercentAtReset, forecast.lowProjectedWeeklyUsedPercentAtReset)
        XCTAssertLessThan(forecast.highProjectedWeeklyUsedPercentAtReset, 115)
        XCTAssertLessThan(
            activityGain(
                in: forecast.highLineSegments,
                startDate: now,
                endDate: now.addingTimeInterval(8 * hour)
            ),
            20
        )
        assertForecastLineSegmentsAreConnected(forecast.highLineSegments)
    }

    func testCycleRunForecastHighPathRespondsToLengtheningIdleTail() {
        let day: TimeInterval = 24 * 60 * 60
        let hour: TimeInterval = 60 * 60
        let start = Date(timeIntervalSince1970: 1_000)
        let reset = start.addingTimeInterval(7 * day)
        let earlyNow = start.addingTimeInterval(16 * hour)
        let laterNow = start.addingTimeInterval(20 * hour)
        let samples = [
            sample(at: start.addingTimeInterval(1 * hour), usedPercent: 0, reset: reset),
            sample(at: start.addingTimeInterval(5 * hour), usedPercent: 13, reset: reset)
        ]

        let earlyProjection = QuotaProjectionEngine.make(
            snapshot: snapshot(usedPercent: 13, reset: reset),
            samples: samples,
            now: earlyNow
        )
        let laterProjection = QuotaProjectionEngine.make(
            snapshot: snapshot(usedPercent: 13, reset: reset),
            samples: samples,
            now: laterNow
        )
        guard let earlyForecast = earlyProjection.cycleRunForecast,
              let laterForecast = laterProjection.cycleRunForecast else {
            XCTFail("Expected cycle forecasts")
            return
        }

        XCTAssertGreaterThan(
            earlyForecast.highProjectedWeeklyUsedPercentAtReset,
            earlyForecast.lowProjectedWeeklyUsedPercentAtReset
        )
        XCTAssertLessThan(
            laterForecast.highProjectedWeeklyUsedPercentAtReset,
            earlyForecast.highProjectedWeeklyUsedPercentAtReset - 5
        )
        XCTAssertLessThan(laterForecast.highProjectedWeeklyUsedPercentAtReset, 120)
        assertForecastLineSegmentsAreConnected(laterForecast.highLineSegments)
    }

    func testCycleRunForecastCapsOverlongCurrentHotRunAgainstPriorBoundedRun() {
        let day: TimeInterval = 24 * 60 * 60
        let hour: TimeInterval = 60 * 60
        let start = Date(timeIntervalSince1970: 1_000)
        let reset = start.addingTimeInterval(7 * day)
        let currentRunStart = start.addingTimeInterval(4 * day + 8 * hour)
        let now = currentRunStart.addingTimeInterval(8 * hour)
        let snapshot = snapshot(usedPercent: 49, reset: reset)
        let samples = [
            sample(at: start.addingTimeInterval(1 * hour), usedPercent: 0, reset: reset),
            sample(at: start.addingTimeInterval(5 * hour), usedPercent: 20, reset: reset),
            sample(at: currentRunStart, usedPercent: 20, reset: reset),
            sample(at: currentRunStart.addingTimeInterval(2 * hour), usedPercent: 32, reset: reset),
            sample(at: currentRunStart.addingTimeInterval(4 * hour), usedPercent: 41, reset: reset),
            sample(at: now, usedPercent: 49, reset: reset)
        ]

        let projection = QuotaProjectionEngine.make(snapshot: snapshot, samples: samples, now: now)
        guard let forecast = projection.cycleRunForecast else {
            XCTFail("Expected cycle forecast")
            return
        }

        XCTAssertGreaterThan(forecast.highProjectedWeeklyUsedPercentAtReset, forecast.lowProjectedWeeklyUsedPercentAtReset)
        XCTAssertLessThan(forecast.highProjectedWeeklyUsedPercentAtReset, 145)
        XCTAssertLessThan(
            activityGain(
                in: forecast.highLineSegments,
                startDate: now,
                endDate: now.addingTimeInterval(8 * hour)
            ),
            15
        )
        assertForecastLineSegmentsAreConnected(forecast.highLineSegments)
    }

    func testCycleRunForecastCapsRecentlyEndedOverlongHotRunAgainstPriorBoundedRun() {
        let day: TimeInterval = 24 * 60 * 60
        let hour: TimeInterval = 60 * 60
        let minute: TimeInterval = 60
        let start = Date(timeIntervalSince1970: 1_000)
        let reset = start.addingTimeInterval(7 * day)
        let currentRunStart = start.addingTimeInterval(4 * day + 8 * hour)
        let currentRunEnd = currentRunStart.addingTimeInterval(8 * hour)
        let now = currentRunEnd.addingTimeInterval(30 * minute)
        let snapshot = snapshot(usedPercent: 49, reset: reset)
        let samples = [
            sample(at: start.addingTimeInterval(1 * hour), usedPercent: 0, reset: reset),
            sample(at: start.addingTimeInterval(5 * hour), usedPercent: 13, reset: reset),
            sample(at: currentRunStart, usedPercent: 13, reset: reset),
            sample(at: currentRunStart.addingTimeInterval(2 * hour), usedPercent: 25, reset: reset),
            sample(at: currentRunStart.addingTimeInterval(4 * hour), usedPercent: 37, reset: reset),
            sample(at: currentRunEnd, usedPercent: 49, reset: reset)
        ]

        let projection = QuotaProjectionEngine.make(snapshot: snapshot, samples: samples, now: now)
        guard let forecast = projection.cycleRunForecast else {
            XCTFail("Expected cycle forecast")
            return
        }

        XCTAssertGreaterThanOrEqual(forecast.highProjectedWeeklyUsedPercentAtReset, forecast.lowProjectedWeeklyUsedPercentAtReset)
        XCTAssertLessThan(forecast.highProjectedWeeklyUsedPercentAtReset, 130)
        assertForecastLineSegmentsAreConnected(forecast.highLineSegments)
    }

    func testCycleRunForecastKeepsSteadyDailyHotspotsBounded() {
        let day: TimeInterval = 24 * 60 * 60
        let hour: TimeInterval = 60 * 60
        let start = Date(timeIntervalSince1970: 1_000)
        let reset = start.addingTimeInterval(7 * day)
        let now = start.addingTimeInterval(3 * day + 6 * hour)
        let snapshot = snapshot(usedPercent: 15, reset: reset)
        let samples = [
            sample(at: start.addingTimeInterval(8 * hour), usedPercent: 0, reset: reset),
            sample(at: start.addingTimeInterval(9 * hour), usedPercent: 5, reset: reset),
            sample(at: start.addingTimeInterval(day + 8 * hour), usedPercent: 5, reset: reset),
            sample(at: start.addingTimeInterval(day + 9 * hour), usedPercent: 10, reset: reset),
            sample(at: start.addingTimeInterval(2 * day + 8 * hour), usedPercent: 10, reset: reset),
            sample(at: start.addingTimeInterval(2 * day + 9 * hour), usedPercent: 15, reset: reset),
            sample(at: now, usedPercent: 15, reset: reset)
        ]

        let projection = QuotaProjectionEngine.make(snapshot: snapshot, samples: samples, now: now)
        guard let forecast = projection.cycleRunForecast else {
            XCTFail("Expected cycle forecast")
            return
        }

        XCTAssertGreaterThan(forecast.lowProjectedWeeklyUsedPercentAtReset, 20)
        XCTAssertLessThan(forecast.lowProjectedWeeklyUsedPercentAtReset, 30)
        XCTAssertGreaterThan(forecast.highProjectedWeeklyUsedPercentAtReset, forecast.lowProjectedWeeklyUsedPercentAtReset)
        XCTAssertGreaterThan(forecast.highProjectedWeeklyUsedPercentAtReset, 25)
        XCTAssertLessThan(forecast.highProjectedWeeklyUsedPercentAtReset, 45)
        XCTAssertEqual(projection.paceState, .fine)
        XCTAssertTrue(forecast.corridorPoints.allSatisfy { $0.lowerUsedPercent <= $0.upperUsedPercent })
    }

    func testPaceStateUsesDisplayedCycleRunForecastWhenRecentSlopeOverreacts() {
        let day: TimeInterval = 24 * 60 * 60
        let hour: TimeInterval = 60 * 60
        let start = Date(timeIntervalSince1970: 1_000)
        let reset = start.addingTimeInterval(7 * day)
        let now = start.addingTimeInterval(day + 4 * hour)
        let snapshot = snapshot(usedPercent: 30, reset: reset)
        let samples = [
            sample(at: now.addingTimeInterval(-3.5 * hour), usedPercent: 28, reset: reset),
            sample(at: now.addingTimeInterval(-2 * hour), usedPercent: 29, reset: reset),
            sample(at: now, usedPercent: 30, reset: reset)
        ]

        let projection = QuotaProjectionEngine.make(snapshot: snapshot, samples: samples, now: now)

        XCTAssertGreaterThan(projection.projectedWeeklyUsedPercentAtReset ?? 0, 100)
        XCTAssertLessThan(projection.cycleRunForecast?.highProjectedWeeklyUsedPercentAtReset ?? 0, 100)
        XCTAssertEqual(projection.paceState, .watch)
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
        XCTAssertTrue(projection.cycleRunForecast?.highLineSegments.contains { $0.kind == .currentProjectedActivity } ?? false)
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

    func testCycleRunForecastExposesConnectedBoundaryLinesForCorridorRendering() {
        let day: TimeInterval = 24 * 60 * 60
        let hour: TimeInterval = 60 * 60
        let start = Date(timeIntervalSince1970: 1_000)
        let reset = start.addingTimeInterval(7 * day)
        let now = start.addingTimeInterval(2 * day + 12 * hour)
        let snapshot = snapshot(usedPercent: 10, reset: reset)
        let samples = [
            sample(at: start.addingTimeInterval(8 * hour), usedPercent: 0, reset: reset),
            sample(at: start.addingTimeInterval(10 * hour), usedPercent: 5, reset: reset),
            sample(at: start.addingTimeInterval(day + 9 * hour), usedPercent: 5, reset: reset),
            sample(at: start.addingTimeInterval(day + 12 * hour), usedPercent: 10, reset: reset),
            sample(at: now, usedPercent: 10, reset: reset)
        ]

        let projection = QuotaProjectionEngine.make(snapshot: snapshot, samples: samples, now: now)
        guard let forecast = projection.cycleRunForecast else {
            XCTFail("Expected cycle forecast")
            return
        }

        for segments in [forecast.lowLineSegments, forecast.highLineSegments] {
            XCTAssertEqual(segments.first?.startDate, now)
            XCTAssertEqual(segments.first?.startUsedPercent ?? 0, 10, accuracy: 0.001)
            XCTAssertEqual(segments.last?.endDate, reset)
            assertForecastLineSegmentsAreConnected(segments)
        }
        XCTAssertTrue(
            (forecast.lowLineSegments + forecast.highLineSegments).contains { $0.kind == .projectedActivity }
        )
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

        XCTAssertFalse(forecast.averageRuns.isEmpty)
        XCTAssertTrue(forecast.lineSegments.contains { $0.kind != .projectedIdle })
        XCTAssertTrue(forecast.lineSegments.allSatisfy { $0.endDate > $0.startDate })
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
        }
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
