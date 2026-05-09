import Foundation

public enum QuotaPaceState: String, Codable, Equatable, Sendable {
    case noData
    case fine
    case watch
    case slowDown
}

public struct QuotaCycleRunForecast: Equatable, Sendable {
    public let projectedWeeklyUsedPercentAtReset: Double
    public let lowProjectedWeeklyUsedPercentAtReset: Double
    public let highProjectedWeeklyUsedPercentAtReset: Double
    public let ghostRuns: [QuotaForecastRun]
    public let averageRuns: [QuotaForecastRun]
    public let lineSegments: [QuotaForecastLineSegment]
    public let lowLineSegments: [QuotaForecastLineSegment]
    public let highLineSegments: [QuotaForecastLineSegment]
    public let earliestLineSegments: [QuotaForecastLineSegment]
    public let latestLineSegments: [QuotaForecastLineSegment]
    public let corridorPoints: [QuotaForecastCorridorPoint]

    public init(
        projectedWeeklyUsedPercentAtReset: Double,
        lowProjectedWeeklyUsedPercentAtReset: Double? = nil,
        highProjectedWeeklyUsedPercentAtReset: Double? = nil,
        ghostRuns: [QuotaForecastRun],
        averageRuns: [QuotaForecastRun] = [],
        lineSegments: [QuotaForecastLineSegment] = [],
        lowLineSegments: [QuotaForecastLineSegment] = [],
        highLineSegments: [QuotaForecastLineSegment] = [],
        earliestLineSegments: [QuotaForecastLineSegment] = [],
        latestLineSegments: [QuotaForecastLineSegment] = [],
        corridorPoints: [QuotaForecastCorridorPoint]
    ) {
        self.projectedWeeklyUsedPercentAtReset = projectedWeeklyUsedPercentAtReset
        self.lowProjectedWeeklyUsedPercentAtReset = lowProjectedWeeklyUsedPercentAtReset ?? projectedWeeklyUsedPercentAtReset
        self.highProjectedWeeklyUsedPercentAtReset = highProjectedWeeklyUsedPercentAtReset ?? projectedWeeklyUsedPercentAtReset
        self.ghostRuns = ghostRuns
        self.averageRuns = averageRuns
        self.lineSegments = lineSegments
        self.lowLineSegments = lowLineSegments.isEmpty ? lineSegments : lowLineSegments
        self.highLineSegments = highLineSegments.isEmpty ? lineSegments : highLineSegments
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
        let paceProjected = cycleForecast?.highProjectedWeeklyUsedPercentAtReset
            ?? cycleForecast?.projectedWeeklyUsedPercentAtReset
            ?? projected
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

        let currentCycle = cycleIndex(for: now, weeklyStartDate: startDate)
        let currentCycleStart = cycleStartDate(weeklyStartDate: startDate, cycleIndex: currentCycle)
        let currentCycleGain = usageGain(
            from: usageSamples,
            startDate: currentCycleStart,
            endDate: now
        )
        let dayPatterns = dailyPatterns(from: runs, weeklyStartDate: startDate, now: now)
        guard dayPatterns.contains(where: \.isWorkedDay) else {
            return nil
        }

        guard let rhythm = dailyHotspotRhythm(from: dayPatterns, currentCycle: currentCycle) else {
            return nil
        }

        let lowDailyGain = conservativeDailyGain(from: dayPatterns, currentCycle: currentCycle)
        guard lowDailyGain >= minimumUsageDelta else {
            return nil
        }

        let highGainModel = pessimisticDailyGainModel(
            from: dayPatterns,
            currentCycle: currentCycle,
            conservativeDailyGain: lowDailyGain
        )
        let lowScenario = forecastScenario(
            rhythm: rhythm,
            current: current,
            weeklyStartDate: startDate,
            currentCycle: currentCycle,
            now: now,
            resetDate: resetDate
        ) { dayIndex, _ in
            dayIndex == currentCycle
                ? max(0, lowDailyGain - currentCycleGain)
                : lowDailyGain
        }
        let highScenario = forecastScenario(
            rhythm: rhythm,
            current: current,
            weeklyStartDate: startDate,
            currentCycle: currentCycle,
            now: now,
            resetDate: resetDate
        ) { dayIndex, futureDayOffset in
            let target = highGainModel.targetGain(forFutureDayOffset: futureDayOffset)
            return dayIndex == currentCycle
                ? max(0, target - currentCycleGain)
                : target
        }

        let timepoints = forecastTimepoints(
            now: now,
            resetDate: resetDate,
            eventGroups: [lowScenario.events, highScenario.events]
        )
        let corridorPoints = timepoints.map { date in
            let low = forecastPercent(at: date, current: current, events: lowScenario.events)
            let high = forecastPercent(at: date, current: current, events: highScenario.events)
            return QuotaForecastCorridorPoint(
                date: date,
                averageUsedPercent: (low + high) / 2,
                lowerUsedPercent: min(low, high),
                upperUsedPercent: max(low, high)
            )
        }

        return QuotaCycleRunForecast(
            projectedWeeklyUsedPercentAtReset: lowScenario.projectedUsedPercent,
            lowProjectedWeeklyUsedPercentAtReset: lowScenario.projectedUsedPercent,
            highProjectedWeeklyUsedPercentAtReset: highScenario.projectedUsedPercent,
            ghostRuns: highScenario.runs,
            averageRuns: lowScenario.runs,
            lineSegments: lowScenario.lineSegments,
            lowLineSegments: lowScenario.lineSegments,
            highLineSegments: highScenario.lineSegments,
            earliestLineSegments: lowScenario.lineSegments,
            latestLineSegments: highScenario.lineSegments,
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

    private static func dailyPatterns(
        from sessions: [UsageBurst],
        weeklyStartDate: Date,
        now: Date
    ) -> [CycleDayPattern] {
        let currentCycle = cycleIndex(for: now, weeklyStartDate: weeklyStartDate)
        return (0...currentCycle).map { dayIndex in
            let dayStartDate = cycleStartDate(weeklyStartDate: weeklyStartDate, cycleIndex: dayIndex)
            let dayEndDate = min(now, dayStartDate.addingTimeInterval(dayDuration))
            let daySessions = sessions.filter { session in
                session.startDate >= dayStartDate
                    && session.startDate < dayStartDate.addingTimeInterval(dayDuration)
            }
            return CycleDayPattern(
                dayIndex: dayIndex,
                startDate: dayStartDate,
                observedFraction: max(0, min(1, dayEndDate.timeIntervalSince(dayStartDate) / dayDuration)),
                totalGain: daySessions.reduce(0) { $0 + $1.usedPercentGain },
                sessions: daySessions
            )
        }
    }

    private static func dailyHotspotRhythm(
        from patterns: [CycleDayPattern],
        currentCycle: Int
    ) -> DailyHotspotRhythm? {
        let completeWorkedPatterns = patterns.filter {
            $0.isWorkedDay && ($0.dayIndex < currentCycle || $0.observedFraction >= 0.85)
        }
        var weightedPatterns = Array(completeWorkedPatterns.suffix(4)).map {
            WeightedCycleDayPattern(pattern: $0, weight: 1)
        }

        if completeWorkedPatterns.count < 2,
           let currentPattern = patterns.first(where: { $0.dayIndex == currentCycle }),
           currentPattern.isWorkedDay,
           currentPattern.observedFraction < 0.85 {
            weightedPatterns.append(WeightedCycleDayPattern(pattern: currentPattern, weight: 0.5))
        }

        let observations = weightedPatterns.flatMap { weightedPattern in
            rhythmObservations(from: weightedPattern)
        }
        guard observations.isEmpty == false else {
            return nil
        }

        var clusters: [DailyHotspotCluster] = []
        for observation in observations.sorted(by: { $0.startOffset < $1.startOffset }) {
            if let nearestClusterIndex = clusters.indices.min(by: {
                abs(clusters[$0].startOffset - observation.startOffset)
                    < abs(clusters[$1].startOffset - observation.startOffset)
            }),
               abs(clusters[nearestClusterIndex].startOffset - observation.startOffset) <= burstMergeGapSeconds {
                clusters[nearestClusterIndex].append(observation)
            } else {
                clusters.append(DailyHotspotCluster(observation: observation))
            }
        }

        let totalWeightedGain = clusters.reduce(0) { $0 + $1.weightedGain }
        guard totalWeightedGain >= minimumUsageDelta else {
            return nil
        }

        let rawHotspots = clusters
            .map { cluster in
                DailyHotspot(
                    startOffset: max(0, cluster.startOffset),
                    duration: max(60, cluster.duration),
                    share: cluster.weightedGain / totalWeightedGain
                )
            }
            .sorted { $0.startOffset < $1.startOffset }

        let keptHotspots = rawHotspots.count > 1
            ? rawHotspots.filter { $0.share >= minimumHotspotShare }
            : rawHotspots
        let effectiveHotspots = keptHotspots.isEmpty ? rawHotspots : keptHotspots
        let shareTotal = effectiveHotspots.reduce(0) { $0 + $1.share }
        guard shareTotal > 0 else {
            return nil
        }

        return DailyHotspotRhythm(
            hotspots: effectiveHotspots.map {
                DailyHotspot(
                    startOffset: $0.startOffset,
                    duration: $0.duration,
                    share: $0.share / shareTotal
                )
            }
        )
    }

    private static func rhythmObservations(
        from weightedPattern: WeightedCycleDayPattern
    ) -> [DailyHotspotObservation] {
        weightedPattern.pattern.sessions.compactMap { session in
            let startOffset = session.startDate.timeIntervalSince(weightedPattern.pattern.startDate)
            let endOffset = session.endDate.timeIntervalSince(weightedPattern.pattern.startDate)
            let duration = max(60, endOffset - startOffset)
            let weightedGain = session.usedPercentGain * weightedPattern.weight
            guard weightedGain >= minimumUsageDelta else {
                return nil
            }
            return DailyHotspotObservation(
                startOffset: startOffset,
                duration: duration,
                weightedGain: weightedGain
            )
        }
    }

    private static func conservativeDailyGain(
        from patterns: [CycleDayPattern],
        currentCycle: Int
    ) -> Double {
        let completeWorkedPatterns = patterns.filter {
            $0.isWorkedDay && ($0.dayIndex < currentCycle || $0.observedFraction >= 0.85)
        }
        let basis = completeWorkedPatterns.isEmpty
            ? patterns.filter(\.isWorkedDay)
            : completeWorkedPatterns
        return median(Array(basis.suffix(4)).map(\.totalGain))
    }

    private static func pessimisticDailyGainModel(
        from patterns: [CycleDayPattern],
        currentCycle: Int,
        conservativeDailyGain: Double
    ) -> PessimisticDailyGainModel {
        let completeWorkedPatterns = patterns.filter {
            $0.isWorkedDay && $0.dayIndex < currentCycle
        }
        let workedPatterns = patterns.filter(\.isWorkedDay)
        let basis = completeWorkedPatterns.count >= 2 ? completeWorkedPatterns : workedPatterns
        let gains = Array(basis.suffix(5)).map(\.totalGain).filter { $0 >= minimumUsageDelta }
        guard gains.isEmpty == false else {
            return PessimisticDailyGainModel(baseGain: conservativeDailyGain, growthStep: 0)
        }

        let typical = median(gains)
        let recent = weightedRecentAverage(gains)
        let latest = gains.last ?? conservativeDailyGain
        let prior = gains.dropLast()
        let priorTypical = prior.isEmpty ? typical : median(Array(prior))
        let latestLift = max(0, latest - priorTypical)
        let positiveGrowth = weightedPositiveGrowth(gains)
        let recentLift = max(0, recent - typical)
        let hasGrowthSignal = latest > priorTypical + minimumUsageDelta || positiveGrowth >= minimumUsageDelta
        let growthStep = hasGrowthSignal
            ? max(latestLift * 0.45, positiveGrowth, recentLift * 0.65)
            : 0
        let baseGain = max(conservativeDailyGain, latest, recent)

        return PessimisticDailyGainModel(baseGain: baseGain, growthStep: growthStep)
    }

    private static func forecastScenario(
        rhythm: DailyHotspotRhythm,
        current: Double,
        weeklyStartDate: Date,
        currentCycle: Int,
        now: Date,
        resetDate: Date,
        targetRemainingGain: (Int, Int) -> Double
    ) -> ForecastScenario {
        var events: [ScheduledForecastRun] = []

        for dayIndex in currentCycle..<7 {
            let targetGain = targetRemainingGain(dayIndex, dayIndex - currentCycle)
            guard targetGain >= minimumUsageDelta else {
                continue
            }

            let dayStartDate = cycleStartDate(weeklyStartDate: weeklyStartDate, cycleIndex: dayIndex)
            events += rhythm.scheduledRuns(
                dayStartDate: dayStartDate,
                targetGain: targetGain,
                now: now,
                resetDate: resetDate,
                minimumGain: minimumUsageDelta,
                normalizesClippedGain: dayIndex == currentCycle
            )
        }

        let sortedEvents = events.sorted { $0.startDate < $1.startDate }
        let lineSegments = forecastLineSegments(
            current: current,
            now: now,
            resetDate: resetDate,
            events: sortedEvents
        )
        let runs = forecastRuns(current: current, events: sortedEvents)
        return ForecastScenario(
            events: sortedEvents,
            runs: runs,
            lineSegments: lineSegments,
            projectedUsedPercent: forecastPercent(at: resetDate, current: current, events: sortedEvents)
        )
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

    private static func median(_ values: [Double]) -> Double {
        guard values.isEmpty == false else {
            return 0
        }

        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private static func weightedRecentAverage(_ values: [Double]) -> Double {
        guard values.isEmpty == false else {
            return 0
        }

        var weightedTotal = 0.0
        var totalWeight = 0.0
        for (index, value) in values.enumerated() {
            let weight = 1.0 + Double(index) / Double(max(1, values.count - 1))
            weightedTotal += value * weight
            totalWeight += weight
        }
        return weightedTotal / totalWeight
    }

    private static func weightedPositiveGrowth(_ values: [Double]) -> Double {
        guard values.count >= 2 else {
            return 0
        }

        var weightedTotal = 0.0
        var totalWeight = 0.0
        let lastDeltaIndex = max(1, values.count - 2)
        for index in 1..<values.count {
            let weight = 1.0 + Double(index - 1) / Double(lastDeltaIndex)
            weightedTotal += max(0, values[index] - values[index - 1]) * weight
            totalWeight += weight
        }
        return weightedTotal / totalWeight
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
        return abs(lhs.timeIntervalSince(rhs)) < 5
    }

    private static let minimumUsageDelta: Double = 0.05
    private static let minimumBurstHistorySeconds: TimeInterval = 6 * 60 * 60
    private static let burstMergeGapSeconds: TimeInterval = 90 * 60
    private static let activeBurstGraceSeconds: TimeInterval = 10 * 60
    private static let minimumExpectedBurstSeconds: TimeInterval = 30 * 60
    private static let maximumBurstContinuationSeconds: TimeInterval = 30 * 60
    private static let minimumHotspotShare = 0.03
    private static let dayDuration: TimeInterval = 24 * 60 * 60
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

private struct CycleDayPattern {
    let dayIndex: Int
    let startDate: Date
    let observedFraction: Double
    let totalGain: Double
    let sessions: [UsageBurst]

    var isWorkedDay: Bool {
        totalGain >= 0.5
    }
}

private struct WeightedCycleDayPattern {
    let pattern: CycleDayPattern
    let weight: Double
}

private struct DailyHotspotObservation {
    let startOffset: TimeInterval
    let duration: TimeInterval
    let weightedGain: Double
}

private struct DailyHotspotCluster {
    private var weightedStartOffset: Double
    private var weightedDuration: Double
    private(set) var weightedGain: Double

    init(observation: DailyHotspotObservation) {
        weightedStartOffset = observation.startOffset * observation.weightedGain
        weightedDuration = observation.duration * observation.weightedGain
        weightedGain = observation.weightedGain
    }

    mutating func append(_ observation: DailyHotspotObservation) {
        weightedStartOffset += observation.startOffset * observation.weightedGain
        weightedDuration += observation.duration * observation.weightedGain
        weightedGain += observation.weightedGain
    }

    var startOffset: TimeInterval {
        weightedStartOffset / max(weightedGain, 0.0001)
    }

    var duration: TimeInterval {
        weightedDuration / max(weightedGain, 0.0001)
    }
}

private struct DailyHotspot {
    let startOffset: TimeInterval
    let duration: TimeInterval
    let share: Double
}

private struct ScheduledHotspot {
    let startDate: Date
    let endDate: Date
    let weightedShare: Double
}

private struct DailyHotspotRhythm {
    let hotspots: [DailyHotspot]

    func scheduledRuns(
        dayStartDate: Date,
        targetGain: Double,
        now: Date,
        resetDate: Date,
        minimumGain: Double,
        normalizesClippedGain: Bool
    ) -> [ScheduledForecastRun] {
        let scheduledHotspots = hotspots.compactMap { hotspot -> ScheduledHotspot? in
            let startDate = dayStartDate.addingTimeInterval(hotspot.startOffset)
            let endDate = startDate.addingTimeInterval(max(60, hotspot.duration))
            guard endDate > now,
                  startDate < resetDate else {
                return nil
            }

            let clippedStartDate = max(startDate, now)
            let clippedEndDate = min(endDate, resetDate)
            guard clippedEndDate > clippedStartDate else {
                return nil
            }

            let remainingFraction = clippedEndDate.timeIntervalSince(clippedStartDate)
                / max(1, endDate.timeIntervalSince(startDate))
            let weightedShare = hotspot.share * remainingFraction
            guard weightedShare > 0 else {
                return nil
            }

            return ScheduledHotspot(
                startDate: clippedStartDate,
                endDate: clippedEndDate,
                weightedShare: weightedShare
            )
        }

        let shareTotal = scheduledHotspots.reduce(0) { $0 + $1.weightedShare }
        guard shareTotal > 0 else {
            return []
        }

        return scheduledHotspots.compactMap { hotspot in
            let gainShare = normalizesClippedGain
                ? hotspot.weightedShare / shareTotal
                : hotspot.weightedShare
            let gain = targetGain * gainShare
            guard gain >= minimumGain else {
                return nil
            }
            return ScheduledForecastRun(
                startDate: hotspot.startDate,
                endDate: hotspot.endDate,
                gain: gain
            )
        }
    }
}

private struct PessimisticDailyGainModel {
    let baseGain: Double
    let growthStep: Double

    func targetGain(forFutureDayOffset offset: Int) -> Double {
        guard growthStep >= 0.05 else {
            return baseGain
        }
        return baseGain + growthStep * Double(offset + 1)
    }
}

private struct ForecastScenario {
    let events: [ScheduledForecastRun]
    let runs: [QuotaForecastRun]
    let lineSegments: [QuotaForecastLineSegment]
    let projectedUsedPercent: Double
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
