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
