import Foundation

public enum QuotaPaceState: String, Codable, Equatable, Sendable {
    case noData
    case fine
    case watch
    case slowDown
}

public struct QuotaCycleRunForecast: Equatable, Sendable {
    public let projectedWeeklyUsedPercentAtReset: Double
    public let ghostRuns: [QuotaForecastRun]
    public let averageRuns: [QuotaForecastRun]
    public let lineSegments: [QuotaForecastLineSegment]
    public let earliestLineSegments: [QuotaForecastLineSegment]
    public let latestLineSegments: [QuotaForecastLineSegment]
    public let corridorPoints: [QuotaForecastCorridorPoint]

    public init(
        projectedWeeklyUsedPercentAtReset: Double,
        ghostRuns: [QuotaForecastRun],
        averageRuns: [QuotaForecastRun] = [],
        lineSegments: [QuotaForecastLineSegment] = [],
        earliestLineSegments: [QuotaForecastLineSegment] = [],
        latestLineSegments: [QuotaForecastLineSegment] = [],
        corridorPoints: [QuotaForecastCorridorPoint]
    ) {
        self.projectedWeeklyUsedPercentAtReset = projectedWeeklyUsedPercentAtReset
        self.ghostRuns = ghostRuns
        self.averageRuns = averageRuns
        self.lineSegments = lineSegments
        self.earliestLineSegments = earliestLineSegments
        self.latestLineSegments = latestLineSegments
        self.corridorPoints = corridorPoints
    }
}

public enum QuotaForecastLineSegmentKind: String, Equatable, Sendable {
    case projectedIdle
    case projectedActivity
    case currentProjectedActivity
}

public struct QuotaForecastLineSegment: Equatable, Sendable {
    public let startDate: Date
    public let endDate: Date
    public let startUsedPercent: Double
    public let endUsedPercent: Double
    public let kind: QuotaForecastLineSegmentKind

    public init(
        startDate: Date,
        endDate: Date,
        startUsedPercent: Double,
        endUsedPercent: Double,
        kind: QuotaForecastLineSegmentKind
    ) {
        self.startDate = startDate
        self.endDate = endDate
        self.startUsedPercent = startUsedPercent
        self.endUsedPercent = endUsedPercent
        self.kind = kind
    }
}

public struct QuotaForecastRun: Equatable, Sendable {
    public let startDate: Date
    public let endDate: Date
    public let startUsedPercent: Double
    public let endUsedPercent: Double

    public init(
        startDate: Date,
        endDate: Date,
        startUsedPercent: Double,
        endUsedPercent: Double
    ) {
        self.startDate = startDate
        self.endDate = endDate
        self.startUsedPercent = startUsedPercent
        self.endUsedPercent = endUsedPercent
    }
}

public struct QuotaForecastCorridorPoint: Equatable, Sendable {
    public let date: Date
    public let averageUsedPercent: Double
    public let lowerUsedPercent: Double
    public let upperUsedPercent: Double

    public init(
        date: Date,
        averageUsedPercent: Double,
        lowerUsedPercent: Double,
        upperUsedPercent: Double
    ) {
        self.date = date
        self.averageUsedPercent = averageUsedPercent
        self.lowerUsedPercent = lowerUsedPercent
        self.upperUsedPercent = upperUsedPercent
    }
}

public struct QuotaProjection: Equatable, Sendable {
    public let currentWeeklyUsedPercent: Double
    public let idealWeeklyUsedPercent: Double?
    public let projectedWeeklyUsedPercentAtReset: Double?
    public let cycleRunForecast: QuotaCycleRunForecast?
    public let weeklyResetDate: Date?
    public let weeklyWindowStartDate: Date?
    public let paceState: QuotaPaceState

    public init(
        currentWeeklyUsedPercent: Double,
        idealWeeklyUsedPercent: Double?,
        projectedWeeklyUsedPercentAtReset: Double?,
        cycleRunForecast: QuotaCycleRunForecast? = nil,
        weeklyResetDate: Date?,
        weeklyWindowStartDate: Date?,
        paceState: QuotaPaceState
    ) {
        self.currentWeeklyUsedPercent = currentWeeklyUsedPercent
        self.idealWeeklyUsedPercent = idealWeeklyUsedPercent
        self.projectedWeeklyUsedPercentAtReset = projectedWeeklyUsedPercentAtReset
        self.cycleRunForecast = cycleRunForecast
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
        let cycleForecast = cycleRunForecast(
            current: current,
            startDate: startDate,
            resetDate: resetDate,
            now: now,
            samples: currentWindowSamples
        )
        let paceProjected = cycleForecast?.projectedWeeklyUsedPercentAtReset ?? projected
        let state = paceState(current: current, projected: paceProjected)

        return QuotaProjection(
            currentWeeklyUsedPercent: current,
            idealWeeklyUsedPercent: ideal,
            projectedWeeklyUsedPercentAtReset: projected,
            cycleRunForecast: cycleForecast,
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
        usageBursts(from: samples.map {
            UsageSample(capturedAt: $0.capturedAt, weeklyUsedPercent: $0.weeklyUsedPercent)
        })
    }

    private static func usageBursts(from samples: [UsageSample]) -> [UsageBurst] {
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

    private static func cycleRunForecast(
        current: Double,
        startDate: Date,
        resetDate: Date,
        now: Date,
        samples: [QuotaSample]
    ) -> QuotaCycleRunForecast? {
        guard now < resetDate,
              samples.count >= 2 else {
            return nil
        }

        let usageSamples = normalizedUsageSamples(samples: samples, current: current, now: now)
        let runs = usageBursts(from: usageSamples)
        guard runs.isEmpty == false else {
            return nil
        }

        let observations = runs.compactMap {
            cycleRunObservation(for: $0, weeklyStartDate: startDate)
        }
        guard observations.isEmpty == false else {
            return nil
        }

        let clusters = clusteredRunObservations(observations)
        guard clusters.isEmpty == false else {
            return nil
        }

        let currentCycle = cycleIndex(for: now, weeklyStartDate: startDate)
        let currentCycleStart = cycleStartDate(weeklyStartDate: startDate, cycleIndex: currentCycle)
        let currentCycleGain = usageGain(
            from: usageSamples,
            startDate: currentCycleStart,
            endDate: now
        )
        let historicalGain = historicalCycleGain(observations, before: currentCycle)
        let fallbackGain = robustAverage(cycleGains(from: observations))
        let effectiveHistoricalGain = historicalGain > 0 ? historicalGain : fallbackGain
        let dailyGain = blendedDailyGain(currentGain: currentCycleGain, historicalGain: effectiveHistoricalGain)
        guard dailyGain >= minimumUsageDelta else {
            return nil
        }

        let clusterGainTotal = clusters.reduce(0) { $0 + $1.averageGain }
        guard clusterGainTotal >= minimumUsageDelta else {
            return nil
        }

        let scheduled = scheduledForecastRuns(
            clusters: clusters,
            dailyGain: dailyGain,
            clusterGainTotal: clusterGainTotal,
            weeklyStartDate: startDate,
            currentCycle: currentCycle,
            now: now,
            resetDate: resetDate
        )
        guard scheduled.average.isEmpty == false else {
            return nil
        }

        let averageRuns = forecastRuns(current: current, events: scheduled.average)
        let lineSegments = forecastLineSegments(
            current: current,
            now: now,
            resetDate: resetDate,
            events: scheduled.average
        )
        let earliestLineSegments = forecastLineSegments(
            current: current,
            now: now,
            resetDate: resetDate,
            events: scheduled.earliest
        )
        let latestLineSegments = forecastLineSegments(
            current: current,
            now: now,
            resetDate: resetDate,
            events: scheduled.latest
        )
        let ghostRuns = scheduledGhostRuns(
            clusters: clusters,
            averageEvents: scheduled.average,
            dailyGain: dailyGain,
            clusterGainTotal: clusterGainTotal,
            weeklyStartDate: startDate,
            currentCycle: currentCycle,
            now: now,
            resetDate: resetDate,
            current: current
        )
        let timepoints = forecastTimepoints(
            now: now,
            resetDate: resetDate,
            eventGroups: [scheduled.average, scheduled.earliest, scheduled.latest]
        )
        let corridorPoints = timepoints.map { date in
            let average = forecastPercent(at: date, current: current, events: scheduled.average)
            let earliest = forecastPercent(at: date, current: current, events: scheduled.earliest)
            let latest = forecastPercent(at: date, current: current, events: scheduled.latest)
            return QuotaForecastCorridorPoint(
                date: date,
                averageUsedPercent: average,
                lowerUsedPercent: min(earliest, latest),
                upperUsedPercent: max(earliest, latest)
            )
        }
        let projected = forecastPercent(at: resetDate, current: current, events: scheduled.average)

        return QuotaCycleRunForecast(
            projectedWeeklyUsedPercentAtReset: projected,
            ghostRuns: ghostRuns,
            averageRuns: averageRuns,
            lineSegments: lineSegments,
            earliestLineSegments: earliestLineSegments,
            latestLineSegments: latestLineSegments,
            corridorPoints: corridorPoints
        )
    }

    private static func normalizedUsageSamples(
        samples: [QuotaSample],
        current: Double,
        now: Date
    ) -> [UsageSample] {
        var usageSamples = samples.map {
            UsageSample(capturedAt: $0.capturedAt, weeklyUsedPercent: $0.weeklyUsedPercent)
        }
        if let lastSample = usageSamples.last,
           now > lastSample.capturedAt,
           abs(current - lastSample.weeklyUsedPercent) > 0.0001 {
            usageSamples.append(UsageSample(capturedAt: now, weeklyUsedPercent: current))
        }
        return usageSamples.sorted { $0.capturedAt < $1.capturedAt }
    }

    private static func cycleRunObservation(
        for run: UsageBurst,
        weeklyStartDate: Date
    ) -> CycleRunObservation? {
        let cycleIndex = cycleIndex(for: run.startDate, weeklyStartDate: weeklyStartDate)
        let cycleStart = cycleStartDate(weeklyStartDate: weeklyStartDate, cycleIndex: cycleIndex)
        let startOffset = run.startDate.timeIntervalSince(cycleStart)
        let endOffset = run.endDate.timeIntervalSince(cycleStart)
        guard endOffset > startOffset,
              startOffset >= 0,
              startOffset < dayDuration * 2 else {
            return nil
        }

        return CycleRunObservation(
            cycleIndex: cycleIndex,
            startOffset: startOffset,
            endOffset: endOffset,
            gain: run.usedPercentGain
        )
    }

    private static func clusteredRunObservations(_ observations: [CycleRunObservation]) -> [CycleRunCluster] {
        var clusters: [CycleRunCluster] = []
        for observation in observations.sorted(by: { $0.startOffset < $1.startOffset }) {
            let matchingIndex = clusters.indices.min { lhs, rhs in
                abs(clusters[lhs].averageStartOffset - observation.startOffset)
                    < abs(clusters[rhs].averageStartOffset - observation.startOffset)
            }.flatMap { index -> Int? in
                abs(clusters[index].averageStartOffset - observation.startOffset) <= runClusterStartToleranceSeconds
                    ? index
                    : nil
            }

            if let matchingIndex {
                clusters[matchingIndex].append(observation)
            } else {
                clusters.append(CycleRunCluster(observation: observation))
            }
        }
        return clusters.sorted { $0.averageStartOffset < $1.averageStartOffset }
    }

    private static func usageGain(
        from samples: [UsageSample],
        startDate: Date,
        endDate: Date
    ) -> Double {
        guard endDate > startDate else {
            return 0
        }

        var gain = 0.0
        for index in 1..<samples.count {
            let previous = samples[index - 1]
            let current = samples[index]
            guard current.capturedAt > startDate,
                  current.capturedAt <= endDate,
                  current.capturedAt > previous.capturedAt else {
                continue
            }

            gain += max(0, current.weeklyUsedPercent - previous.weeklyUsedPercent)
        }
        return gain
    }

    private static func historicalCycleGain(
        _ observations: [CycleRunObservation],
        before currentCycle: Int
    ) -> Double {
        let gains = cycleGains(from: observations.filter { $0.cycleIndex < currentCycle })
        return robustAverage(gains)
    }

    private static func cycleGains(from observations: [CycleRunObservation]) -> [Double] {
        let grouped = Dictionary(grouping: observations, by: \.cycleIndex)
        return grouped.values
            .map { cycleObservations in
                cycleObservations.reduce(0) { $0 + $1.gain }
            }
            .filter { $0 >= minimumUsageDelta }
    }

    private static func blendedDailyGain(currentGain: Double, historicalGain: Double) -> Double {
        if currentGain >= minimumUsageDelta, historicalGain >= minimumUsageDelta {
            return currentGainWeight * currentGain + (1 - currentGainWeight) * historicalGain
        }
        if currentGain >= minimumUsageDelta {
            return currentGain
        }
        return historicalGain
    }

    private static func scheduledForecastRuns(
        clusters: [CycleRunCluster],
        dailyGain: Double,
        clusterGainTotal: Double,
        weeklyStartDate: Date,
        currentCycle: Int,
        now: Date,
        resetDate: Date
    ) -> ForecastSchedule {
        var average: [ScheduledForecastRun] = []
        var earliest: [ScheduledForecastRun] = []
        var latest: [ScheduledForecastRun] = []

        for cycle in currentCycle..<7 {
            let cycleStart = cycleStartDate(weeklyStartDate: weeklyStartDate, cycleIndex: cycle)
            for cluster in clusters {
                let gain = dailyGain * (cluster.averageGain / clusterGainTotal)
                if let event = scheduledForecastRun(
                    cycleStart: cycleStart,
                    startOffset: cluster.averageStartOffset,
                    endOffset: cluster.averageEndOffset,
                    gain: gain,
                    now: now,
                    resetDate: resetDate
                ) {
                    average.append(event)
                }
                if let event = scheduledForecastRun(
                    cycleStart: cycleStart,
                    startOffset: cluster.minimumStartOffset,
                    endOffset: cluster.minimumEndOffset,
                    gain: gain,
                    now: now,
                    resetDate: resetDate
                ) {
                    earliest.append(event)
                }
                if let event = scheduledForecastRun(
                    cycleStart: cycleStart,
                    startOffset: cluster.maximumStartOffset,
                    endOffset: cluster.maximumEndOffset,
                    gain: gain,
                    now: now,
                    resetDate: resetDate
                ) {
                    latest.append(event)
                }
            }
        }

        return ForecastSchedule(
            average: average.sorted { $0.startDate < $1.startDate },
            earliest: earliest.sorted { $0.startDate < $1.startDate },
            latest: latest.sorted { $0.startDate < $1.startDate }
        )
    }

    private static func scheduledGhostRuns(
        clusters: [CycleRunCluster],
        averageEvents: [ScheduledForecastRun],
        dailyGain: Double,
        clusterGainTotal: Double,
        weeklyStartDate: Date,
        currentCycle: Int,
        now: Date,
        resetDate: Date,
        current: Double
    ) -> [QuotaForecastRun] {
        var ghostRuns: [QuotaForecastRun] = []
        for cycle in currentCycle..<7 {
            let cycleStart = cycleStartDate(weeklyStartDate: weeklyStartDate, cycleIndex: cycle)
            for cluster in clusters {
                let clusterGain = dailyGain * (cluster.averageGain / clusterGainTotal)
                for observation in cluster.observations {
                    let observationGain = observation.gain * clusterGain / max(cluster.averageGain, minimumUsageDelta)
                    guard let event = scheduledForecastRun(
                        cycleStart: cycleStart,
                        startOffset: observation.startOffset,
                        endOffset: observation.endOffset,
                        gain: observationGain,
                        now: now,
                        resetDate: resetDate
                    ) else {
                        continue
                    }

                    let startUsedPercent = forecastPercent(at: event.startDate, current: current, events: averageEvents)
                    ghostRuns.append(
                        QuotaForecastRun(
                            startDate: event.startDate,
                            endDate: event.endDate,
                            startUsedPercent: startUsedPercent,
                            endUsedPercent: startUsedPercent + event.gain
                        )
                    )
                }
            }
        }
        return ghostRuns.sorted { $0.startDate < $1.startDate }
    }

    private static func forecastRuns(
        current: Double,
        events: [ScheduledForecastRun]
    ) -> [QuotaForecastRun] {
        events.sorted { $0.startDate < $1.startDate }.map { event in
            let startUsedPercent = forecastPercent(at: event.startDate, current: current, events: events)
            return QuotaForecastRun(
                startDate: event.startDate,
                endDate: event.endDate,
                startUsedPercent: startUsedPercent,
                endUsedPercent: startUsedPercent + event.gain
            )
        }
    }

    private static func forecastLineSegments(
        current: Double,
        now: Date,
        resetDate: Date,
        events: [ScheduledForecastRun]
    ) -> [QuotaForecastLineSegment] {
        var segments: [QuotaForecastLineSegment] = []
        var cursorDate = now
        var cursorPercent = current

        for event in events.sorted(by: { $0.startDate < $1.startDate }) where event.endDate > cursorDate {
            if event.startDate > cursorDate {
                appendForecastLineSegment(
                    startDate: cursorDate,
                    endDate: event.startDate,
                    startUsedPercent: cursorPercent,
                    endUsedPercent: cursorPercent,
                    kind: .projectedIdle,
                    into: &segments
                )
                cursorDate = event.startDate
            }

            let activityStartDate = max(cursorDate, event.startDate)
            let activityGain = event.gain(from: activityStartDate)
            let activityKind: QuotaForecastLineSegmentKind = abs(activityStartDate.timeIntervalSince(now)) < 0.5
                ? .currentProjectedActivity
                : .projectedActivity

            appendForecastLineSegment(
                startDate: activityStartDate,
                endDate: event.endDate,
                startUsedPercent: cursorPercent,
                endUsedPercent: cursorPercent + activityGain,
                kind: activityKind,
                into: &segments
            )
            cursorDate = event.endDate
            cursorPercent += activityGain
        }

        if resetDate > cursorDate {
            appendForecastLineSegment(
                startDate: cursorDate,
                endDate: resetDate,
                startUsedPercent: cursorPercent,
                endUsedPercent: cursorPercent,
                kind: .projectedIdle,
                into: &segments
            )
        }

        return segments
    }

    private static func appendForecastLineSegment(
        startDate: Date,
        endDate: Date,
        startUsedPercent: Double,
        endUsedPercent: Double,
        kind: QuotaForecastLineSegmentKind,
        into segments: inout [QuotaForecastLineSegment]
    ) {
        guard endDate > startDate else {
            return
        }

        let segment = QuotaForecastLineSegment(
            startDate: startDate,
            endDate: endDate,
            startUsedPercent: startUsedPercent,
            endUsedPercent: endUsedPercent,
            kind: kind
        )

        if let last = segments.last,
           last.kind == segment.kind,
           abs(last.endDate.timeIntervalSince(segment.startDate)) < 0.5,
           abs(last.endUsedPercent - segment.startUsedPercent) < 0.001 {
            segments[segments.count - 1] = QuotaForecastLineSegment(
                startDate: last.startDate,
                endDate: segment.endDate,
                startUsedPercent: last.startUsedPercent,
                endUsedPercent: segment.endUsedPercent,
                kind: last.kind
            )
            return
        }

        segments.append(segment)
    }

    private static func scheduledForecastRun(
        cycleStart: Date,
        startOffset: TimeInterval,
        endOffset: TimeInterval,
        gain: Double,
        now: Date,
        resetDate: Date
    ) -> ScheduledForecastRun? {
        let originalStart = cycleStart.addingTimeInterval(startOffset)
        let originalEnd = cycleStart.addingTimeInterval(max(endOffset, startOffset + minimumExpectedBurstSeconds))
        guard originalEnd > now,
              originalStart < resetDate else {
            return nil
        }

        let start = max(originalStart, now)
        let end = min(originalEnd, resetDate)
        guard end > start else {
            return nil
        }

        let originalDuration = max(1, originalEnd.timeIntervalSince(originalStart))
        let remainingDuration = end.timeIntervalSince(start)
        let remainingGain = gain * remainingDuration / originalDuration
        guard remainingGain >= minimumUsageDelta else {
            return nil
        }

        return ScheduledForecastRun(startDate: start, endDate: end, gain: remainingGain)
    }

    private static func forecastTimepoints(
        now: Date,
        resetDate: Date,
        eventGroups: [[ScheduledForecastRun]]
    ) -> [Date] {
        var dates = [now, resetDate]
        for event in eventGroups.flatMap(\.self) {
            dates.append(event.startDate)
            dates.append(event.endDate)
        }

        let sorted = dates.sorted()
        var unique: [Date] = []
        for date in sorted {
            guard let last = unique.last,
                  abs(last.timeIntervalSince(date)) < 0.5 else {
                unique.append(date)
                continue
            }
        }
        return unique
    }

    private static func forecastPercent(
        at date: Date,
        current: Double,
        events: [ScheduledForecastRun]
    ) -> Double {
        events.reduce(current) { total, event in
            total + event.gain * event.progress(at: date)
        }
    }

    private static func cycleIndex(for date: Date, weeklyStartDate: Date) -> Int {
        let rawIndex = Int(floor(date.timeIntervalSince(weeklyStartDate) / dayDuration))
        return min(6, max(0, rawIndex))
    }

    private static func cycleStartDate(weeklyStartDate: Date, cycleIndex: Int) -> Date {
        weeklyStartDate.addingTimeInterval(TimeInterval(cycleIndex) * dayDuration)
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

    private static func paceState(current: Double, projected: Double) -> QuotaPaceState {
        if projected >= 100 || current >= 100 {
            return .slowDown
        }
        if projected >= 90 {
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
    private static let burstMergeGapSeconds: TimeInterval = 90 * 60
    private static let activeBurstGraceSeconds: TimeInterval = 10 * 60
    private static let minimumExpectedBurstSeconds: TimeInterval = 30 * 60
    private static let maximumBurstContinuationSeconds: TimeInterval = 30 * 60
    private static let dayDuration: TimeInterval = 24 * 60 * 60
    private static let runClusterStartToleranceSeconds: TimeInterval = 3 * 60 * 60
    private static let currentGainWeight = 0.65
}

private struct UsageSample {
    let capturedAt: Date
    let weeklyUsedPercent: Double
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

private struct CycleRunObservation {
    let cycleIndex: Int
    let startOffset: TimeInterval
    let endOffset: TimeInterval
    let gain: Double
}

private struct CycleRunCluster {
    private(set) var observations: [CycleRunObservation]

    init(observation: CycleRunObservation) {
        self.observations = [observation]
    }

    mutating func append(_ observation: CycleRunObservation) {
        observations.append(observation)
    }

    var averageStartOffset: TimeInterval {
        average(observations.map(\.startOffset))
    }

    var averageEndOffset: TimeInterval {
        max(averageStartOffset + 1, average(observations.map(\.endOffset)))
    }

    var minimumStartOffset: TimeInterval {
        observations.map(\.startOffset).min() ?? averageStartOffset
    }

    var maximumStartOffset: TimeInterval {
        observations.map(\.startOffset).max() ?? averageStartOffset
    }

    var minimumEndOffset: TimeInterval {
        max(minimumStartOffset + 1, observations.map(\.endOffset).min() ?? averageEndOffset)
    }

    var maximumEndOffset: TimeInterval {
        max(maximumStartOffset + 1, observations.map(\.endOffset).max() ?? averageEndOffset)
    }

    var averageGain: Double {
        average(observations.map(\.gain))
    }

    private func average(_ values: [Double]) -> Double {
        guard values.isEmpty == false else {
            return 0
        }
        return values.reduce(0, +) / Double(values.count)
    }
}

private struct ForecastSchedule {
    let average: [ScheduledForecastRun]
    let earliest: [ScheduledForecastRun]
    let latest: [ScheduledForecastRun]
}

private struct ScheduledForecastRun {
    let startDate: Date
    let endDate: Date
    let gain: Double

    func gain(from date: Date) -> Double {
        let remainingDuration = max(0, endDate.timeIntervalSince(max(date, startDate)))
        return gain * min(1, remainingDuration / max(1, endDate.timeIntervalSince(startDate)))
    }

    func progress(at date: Date) -> Double {
        if date <= startDate {
            return 0
        }
        if date >= endDate {
            return 1
        }
        return date.timeIntervalSince(startDate) / max(1, endDate.timeIntervalSince(startDate))
    }
}
