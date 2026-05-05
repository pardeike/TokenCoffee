import Foundation

public enum QuotaPaceState: String, Codable, Equatable, Sendable {
    case noData
    case fine
    case watch
    case slowDown
}

public struct QuotaProjection: Equatable, Sendable {
    public let currentWeeklyUsedPercent: Double
    public let idealWeeklyUsedPercent: Double?
    public let projectedWeeklyUsedPercentAtReset: Double?
    public let weeklyResetDate: Date?
    public let weeklyWindowStartDate: Date?
    public let paceState: QuotaPaceState

    public init(
        currentWeeklyUsedPercent: Double,
        idealWeeklyUsedPercent: Double?,
        projectedWeeklyUsedPercentAtReset: Double?,
        weeklyResetDate: Date?,
        weeklyWindowStartDate: Date?,
        paceState: QuotaPaceState
    ) {
        self.currentWeeklyUsedPercent = currentWeeklyUsedPercent
        self.idealWeeklyUsedPercent = idealWeeklyUsedPercent
        self.projectedWeeklyUsedPercentAtReset = projectedWeeklyUsedPercentAtReset
        self.weeklyResetDate = weeklyResetDate
        self.weeklyWindowStartDate = weeklyWindowStartDate
        self.paceState = paceState
    }
}

public enum QuotaProjectionEngine {
    public static func make(
        snapshot: RateLimitSnapshot?,
        samples: [QuotaSample],
        now: Date = Date()
    ) -> QuotaProjection {
        guard let snapshot,
              let weekly = snapshot.secondary else {
            return QuotaProjection(
                currentWeeklyUsedPercent: 0,
                idealWeeklyUsedPercent: nil,
                projectedWeeklyUsedPercentAtReset: nil,
                weeklyResetDate: nil,
                weeklyWindowStartDate: nil,
                paceState: .noData
            )
        }

        let current = weekly.usedPercent
        guard let resetDate = weekly.resetDate,
              let durationMinutes = weekly.windowDurationMins,
              durationMinutes > 0 else {
            return QuotaProjection(
                currentWeeklyUsedPercent: current,
                idealWeeklyUsedPercent: nil,
                projectedWeeklyUsedPercentAtReset: nil,
                weeklyResetDate: weekly.resetDate,
                weeklyWindowStartDate: nil,
                paceState: .watch
            )
        }

        let duration = TimeInterval(durationMinutes * 60)
        let startDate = resetDate.addingTimeInterval(-duration)
        let elapsed = max(0, min(duration, now.timeIntervalSince(startDate)))
        let remaining = max(0, resetDate.timeIntervalSince(now))
        let elapsedFraction = duration > 0 ? elapsed / duration : 0
        let ideal = elapsedFraction * 100

        let currentWindowSamples = samples
            .filter { sample in
                sample.limitId == (snapshot.limitId ?? "codex")
                    && sample.capturedAt >= startDate
                    && sample.capturedAt <= now
                    && sameReset(sample.weeklyResetsAt, resetDate)
            }
            .sorted { $0.capturedAt < $1.capturedAt }

        let projected = projectedUsage(
            current: current,
            remaining: remaining,
            elapsedFraction: elapsedFraction,
            now: now,
            samples: currentWindowSamples
        )
        let state = paceState(current: current, ideal: ideal, projected: projected)

        return QuotaProjection(
            currentWeeklyUsedPercent: current,
            idealWeeklyUsedPercent: ideal,
            projectedWeeklyUsedPercentAtReset: projected,
            weeklyResetDate: resetDate,
            weeklyWindowStartDate: startDate,
            paceState: state
        )
    }

    private static func projectedUsage(
        current: Double,
        remaining: TimeInterval,
        elapsedFraction: Double,
        now: Date,
        samples: [QuotaSample]
    ) -> Double {
        let fallbackProjection = elapsedFraction > 0.001
            ? current / elapsedFraction
            : current

        if let burstAwareProjection = burstAwareProjection(
            current: current,
            remaining: remaining,
            now: now,
            samples: samples
        ) {
            return burstAwareProjection
        }

        let recentCutoff = now.addingTimeInterval(-12 * 60 * 60)
        let recentSamples = samples.filter { $0.capturedAt >= recentCutoff }
        let slopeSamples = recentSamples.count >= 2 ? recentSamples : samples

        if let first = slopeSamples.first,
           let last = slopeSamples.last,
           last.capturedAt > first.capturedAt {
            let deltaPercent = last.weeklyUsedPercent - first.weeklyUsedPercent
            let deltaSeconds = last.capturedAt.timeIntervalSince(first.capturedAt)
            let slope = max(0, deltaPercent / max(1, deltaSeconds))
            return current + slope * remaining
        }

        return fallbackProjection
    }

    private static func burstAwareProjection(
        current: Double,
        remaining: TimeInterval,
        now: Date,
        samples: [QuotaSample]
    ) -> Double? {
        guard samples.count >= 3,
              let firstSample = samples.first else {
            return nil
        }

        let observedEnd = max(now, samples.last?.capturedAt ?? now)
        let observedDuration = observedEnd.timeIntervalSince(firstSample.capturedAt)
        guard observedDuration >= minimumBurstHistorySeconds else {
            return nil
        }

        let bursts = usageBursts(from: samples)
        guard bursts.isEmpty == false else {
            return current
        }

        let gainPerBurst = robustAverage(bursts.map(\.usedPercentGain))
        let burstsPerSecond = Double(bursts.count) / observedDuration
        let cadenceGain = gainPerBurst * burstsPerSecond * remaining
        let continuationGain = currentBurstContinuationGain(
            bursts: bursts,
            typicalGain: gainPerBurst,
            now: now,
            remaining: remaining
        )

        return max(current, current + cadenceGain + continuationGain)
    }

    private static func usageBursts(from samples: [QuotaSample]) -> [UsageBurst] {
        var bursts: [UsageBurst] = []
        for index in 1..<samples.count {
            let previous = samples[index - 1]
            let current = samples[index]
            let delta = current.weeklyUsedPercent - previous.weeklyUsedPercent
            guard delta >= minimumUsageDelta,
                  current.capturedAt > previous.capturedAt else {
                continue
            }

            let interval = UsageInterval(
                startDate: previous.capturedAt,
                endDate: current.capturedAt,
                usedPercentGain: delta
            )

            if let lastIndex = bursts.indices.last,
               interval.startDate.timeIntervalSince(bursts[lastIndex].endDate) <= burstMergeGapSeconds {
                bursts[lastIndex].append(interval)
            } else {
                bursts.append(UsageBurst(interval: interval))
            }
        }
        return bursts
    }

    private static func currentBurstContinuationGain(
        bursts: [UsageBurst],
        typicalGain: Double,
        now: Date,
        remaining: TimeInterval
    ) -> Double {
        guard let lastBurst = bursts.last,
              now.timeIntervalSince(lastBurst.endDate) <= activeBurstGraceSeconds else {
            return 0
        }

        let typicalDuration = max(
            minimumExpectedBurstSeconds,
            robustAverage(bursts.map(\.activeDuration))
        )
        let expectedContinuation = min(
            maximumBurstContinuationSeconds,
            max(0, typicalDuration - lastBurst.activeDuration),
            remaining
        )
        guard expectedContinuation > 0 else {
            return 0
        }

        let burstRate = lastBurst.usedPercentGain / max(1, lastBurst.activeDuration)
        return min(typicalGain, burstRate * expectedContinuation)
    }

    private static func robustAverage(_ values: [Double]) -> Double {
        guard values.isEmpty == false else {
            return 0
        }

        let sorted = values.sorted()
        let mean = sorted.reduce(0, +) / Double(sorted.count)
        guard sorted.count >= 3 else {
            return mean
        }

        let median: Double
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            median = (sorted[middle - 1] + sorted[middle]) / 2
        } else {
            median = sorted[middle]
        }
        return (mean + median) / 2
    }

    private static func paceState(current: Double, ideal: Double, projected: Double) -> QuotaPaceState {
        if projected >= 100 || current >= 100 {
            return .slowDown
        }
        if projected >= 90 || current > ideal + 10 {
            return .watch
        }
        return .fine
    }

    private static func sameReset(_ lhs: Date?, _ rhs: Date) -> Bool {
        guard let lhs else {
            return false
        }
        return abs(lhs.timeIntervalSince(rhs)) < 1
    }

    private static let minimumUsageDelta: Double = 0.05
    private static let minimumBurstHistorySeconds: TimeInterval = 6 * 60 * 60
    private static let burstMergeGapSeconds: TimeInterval = 45 * 60
    private static let activeBurstGraceSeconds: TimeInterval = 10 * 60
    private static let minimumExpectedBurstSeconds: TimeInterval = 30 * 60
    private static let maximumBurstContinuationSeconds: TimeInterval = 30 * 60
}

private struct UsageInterval {
    let startDate: Date
    let endDate: Date
    let usedPercentGain: Double

    var duration: TimeInterval {
        max(1, endDate.timeIntervalSince(startDate))
    }
}

private struct UsageBurst {
    private(set) var startDate: Date
    private(set) var endDate: Date
    private(set) var usedPercentGain: Double
    private(set) var activeDuration: TimeInterval

    init(interval: UsageInterval) {
        self.startDate = interval.startDate
        self.endDate = interval.endDate
        self.usedPercentGain = interval.usedPercentGain
        self.activeDuration = interval.duration
    }

    mutating func append(_ interval: UsageInterval) {
        endDate = interval.endDate
        usedPercentGain += interval.usedPercentGain
        activeDuration += interval.duration
    }
}
