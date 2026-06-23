import Foundation
import QuotaForecastKit

enum QuotaForecastKitAdapter {
    static func makeCycleRunForecast(
        current: Double,
        startDate: Date,
        resetDate: Date,
        now: Date,
        samples: [QuotaSample]
    ) -> QuotaCycleRunForecast? {
        guard let input = makeForecastInput(
            current: current,
            startDate: startDate,
            resetDate: resetDate,
            now: now,
            samples: samples
        ),
              input.hasUsageIncreases else {
            return nil
        }

        let result: QuotaForecast
        do {
            result = try forecast(input)
        } catch {
            return nil
        }

        let observedIntensityRuns = observedIntensityRuns(from: input.inputSamples)
        let projectedHotRuns = projectedHotRuns(
            from: observedIntensityRuns,
            now: input.now,
            resetDate: input.weeklyResetDate
        )

        let packageOptimisticSegments = lineSegments(
            from: result.optimistic,
            input: input,
            marksCurrentActivity: input.isCurrentlyActive
        )
        let rawPackagePessimisticSegments = lineSegments(
            from: result.pessimistic,
            input: input,
            marksCurrentActivity: input.isCurrentlyActive
        )
        let packagePessimisticSegments = activeContinuationCappedSegments(
            rawPackagePessimisticSegments,
            input: input,
            observedRuns: observedIntensityRuns
        )
        let optimisticSegments = hotRunAdjustedSegments(
            packageOptimisticSegments,
            projectedHotRuns: projectedHotRuns,
            input: input,
            targetMultiplier: optimisticHotRunMultiplier,
            marksCurrentActivity: input.isCurrentlyActive
        )
        let pessimisticSegments = hotRunAdjustedSegments(
            packagePessimisticSegments,
            projectedHotRuns: projectedHotRuns,
            input: input,
            targetMultiplier: pessimisticHotRunMultiplier,
            marksCurrentActivity: input.isCurrentlyActive
        )
        let adjustedPessimisticSegments = highEvidenceAdjustedSegments(
            rawHighSegments: pessimisticSegments,
            lowSegments: optimisticSegments,
            input: input,
            observedRuns: observedIntensityRuns
        )
        let cappedPessimisticSegments = highCeilingAdjustedSegments(
            adjustedPessimisticSegments,
            lowSegments: optimisticSegments,
            input: input,
            observedRuns: observedIntensityRuns
        )
        guard optimisticSegments.isEmpty == false,
              cappedPessimisticSegments.isEmpty == false else {
            return nil
        }

        let optimisticEndpoint = optimisticSegments.last?.endUsedPercent ?? result.optimistic.endpoint
        let pessimisticEndpoint = cappedPessimisticSegments.last?.endUsedPercent ?? result.pessimistic.endpoint

        return QuotaCycleRunForecast(
            projectedWeeklyUsedPercentAtReset: optimisticEndpoint,
            lowProjectedWeeklyUsedPercentAtReset: optimisticEndpoint,
            highProjectedWeeklyUsedPercentAtReset: pessimisticEndpoint,
            ghostRuns: forecastRuns(from: cappedPessimisticSegments),
            averageRuns: forecastRuns(from: optimisticSegments),
            lineSegments: optimisticSegments,
            lowLineSegments: optimisticSegments,
            highLineSegments: cappedPessimisticSegments,
            earliestLineSegments: optimisticSegments,
            latestLineSegments: cappedPessimisticSegments,
            corridorPoints: corridorPoints(
                lowSegments: optimisticSegments,
                highSegments: cappedPessimisticSegments,
                dates: [input.now] + input.futureDates,
                current: input.current
            ),
            observedIntensityRuns: observedIntensityRuns
        )
    }

    static func makeForecastInput(
        current: Double,
        startDate: Date,
        resetDate: Date,
        now: Date,
        samples: [QuotaSample]
    ) -> QuotaForecastKitInput? {
        guard current.isFinite,
              now < resetDate,
              resetDate > startDate else {
            return nil
        }

        let inputSamples = forecastInputSamples(
            current: current,
            startDate: startDate,
            now: now,
            samples: samples
        )
        guard inputSamples.isEmpty == false else {
            return nil
        }

        let observed = observedSeries(
            current: current,
            now: now,
            inputSamples: inputSamples
        )
        guard observed.values.isEmpty == false else {
            return nil
        }

        let futureDates = futureGridDates(
            now: now,
            resetDate: resetDate,
            stepSeconds: forecastStepSeconds
        )
        guard futureDates.isEmpty == false else {
            return nil
        }

        return QuotaForecastKitInput(
            limitId: inputSamples.last?.limitId,
            limitName: inputSamples.last?.limitName,
            planType: inputSamples.last?.planType,
            weeklyStartDate: startDate,
            weeklyResetDate: resetDate,
            now: now,
            current: current,
            stepSeconds: forecastStepSeconds,
            observedDates: observed.dates,
            observedValues: observed.values,
            futureDates: futureDates,
            inputSamples: inputSamples,
            configuration: defaultConfiguration()
        )
    }

    static func forecast(_ input: QuotaForecastKitInput) throws -> QuotaForecast {
        try QuotaForecaster(configuration: input.configuration).forecast(
            observed: input.observedValues,
            totalCount: input.totalCount
        )
    }

    static func parametersSummary(for configuration: QuotaForecastConfiguration) -> QuotaForecastKitParameterSummary {
        QuotaForecastKitParameterSummary(configuration)
    }

    static func defaultConfiguration() -> QuotaForecastConfiguration {
        var configuration = QuotaForecastConfiguration()
        configuration.softQuota = 100
        configuration.ensembleSize = 64
        configuration.allowOverrun = true
        configuration.optimisticConservationStrength = 0.45
        configuration.optimisticTargetQuotaFraction = 1.03
        configuration.minimumConservationMultiplier = 0.30
        configuration.optimisticPatternQuantile = 0.40
        configuration.optimisticMagnitudeMultiplier = 0.98
        configuration.pessimisticPatternQuantile = 0.87
        configuration.pessimisticMagnitudeMultiplier = 1.12
        configuration.pessimisticRepresentativeQuantile = 0.60
        configuration.quantizationStep = 1
        return configuration
    }

    private static func forecastInputSamples(
        current: Double,
        startDate: Date,
        now: Date,
        samples: [QuotaSample]
    ) -> [ForecastInputSample] {
        var inputSamples = samples
            .filter { sample in
                sample.capturedAt >= startDate
                    && sample.capturedAt <= now
                    && sample.weeklyUsedPercent.isFinite
            }
            .sorted { first, second in
                if first.capturedAt == second.capturedAt {
                    return first.weeklyUsedPercent < second.weeklyUsedPercent
                }
                return first.capturedAt < second.capturedAt
            }
            .map { sample in
                ForecastInputSample(
                    date: sample.capturedAt,
                    usedPercent: sample.weeklyUsedPercent,
                    limitId: sample.limitId,
                    limitName: sample.limitName,
                    planType: sample.planType
                )
            }

        if let lastIndex = inputSamples.indices.last,
           abs(inputSamples[lastIndex].date.timeIntervalSince(now)) < 0.5 {
            inputSamples[lastIndex].usedPercent = current
        } else {
            inputSamples.append(ForecastInputSample(
                date: now,
                usedPercent: current,
                limitId: inputSamples.last?.limitId,
                limitName: inputSamples.last?.limitName,
                planType: inputSamples.last?.planType
            ))
        }

        return inputSamples
    }

    private static func observedSeries(
        current: Double,
        now: Date,
        inputSamples: [ForecastInputSample]
    ) -> ForecastObservedSeries {
        guard let firstDate = inputSamples.first?.date else {
            return ForecastObservedSeries(dates: [], values: [])
        }

        var dates: [Date] = []
        var cursor = firstDate
        while cursor < now.addingTimeInterval(-minimumDateSeparation) {
            dates.append(cursor)
            cursor = cursor.addingTimeInterval(forecastStepSeconds)
        }
        if let last = dates.last,
           abs(last.timeIntervalSince(now)) < minimumDateSeparation {
            dates[dates.count - 1] = now
        } else {
            dates.append(now)
        }

        var values: [Double] = []
        var sampleIndex = 0
        var previousValue = inputSamples.first?.usedPercent ?? current
        for date in dates {
            while sampleIndex + 1 < inputSamples.count,
                  inputSamples[sampleIndex + 1].date <= date {
                sampleIndex += 1
            }

            let rawValue = date >= now.addingTimeInterval(-minimumDateSeparation)
                ? current
                : inputSamples[sampleIndex].usedPercent
            let value = max(previousValue, rawValue)
            values.append(value)
            previousValue = value
        }

        return ForecastObservedSeries(dates: dates, values: values)
    }

    private static func futureGridDates(
        now: Date,
        resetDate: Date,
        stepSeconds: TimeInterval
    ) -> [Date] {
        guard resetDate > now else {
            return []
        }

        var dates: [Date] = []
        var cursor = now.addingTimeInterval(stepSeconds)
        while cursor < resetDate.addingTimeInterval(-minimumDateSeparation) {
            dates.append(cursor)
            cursor = cursor.addingTimeInterval(stepSeconds)
        }

        if let last = dates.last,
           abs(last.timeIntervalSince(resetDate)) < minimumDateSeparation {
            dates[dates.count - 1] = resetDate
        } else {
            dates.append(resetDate)
        }
        return dates
    }

    private static func lineSegments(
        from forecast: ScenarioForecast,
        input: QuotaForecastKitInput,
        marksCurrentActivity: Bool
    ) -> [QuotaForecastLineSegment] {
        let pointCount = min(input.futureDates.count, forecast.futureValues.count)
        guard pointCount > 0 else {
            return []
        }

        var points = [ForecastPoint(date: input.now, usedPercent: input.current)]
        for index in 0..<pointCount {
            points.append(ForecastPoint(
                date: input.futureDates[index],
                usedPercent: forecast.futureValues[index]
            ))
        }

        var hasMarkedCurrentActivity = false
        var segments: [QuotaForecastLineSegment] = []
        for (startPoint, endPoint) in zip(points, points.dropFirst()) where endPoint.date > startPoint.date {
            let kind: QuotaForecastLineSegmentKind
            if endPoint.usedPercent - startPoint.usedPercent <= minimumUsageDelta {
                kind = .projectedIdle
            } else if marksCurrentActivity,
                      hasMarkedCurrentActivity == false {
                kind = .currentProjectedActivity
                hasMarkedCurrentActivity = true
            } else {
                kind = .projectedActivity
            }

            appendLineSegment(
                QuotaForecastLineSegment(
                    startDate: startPoint.date,
                    endDate: endPoint.date,
                    startUsedPercent: startPoint.usedPercent,
                    endUsedPercent: endPoint.usedPercent,
                    kind: kind
                ),
                into: &segments
            )
        }
        return segments
    }

    private static func forecastRuns(from segments: [QuotaForecastLineSegment]) -> [QuotaForecastRun] {
        var runs: [QuotaForecastRun] = []
        var currentRun: QuotaForecastRun?

        for segment in segments where segment.kind != .projectedIdle {
            if let run = currentRun,
               abs(run.endDate.timeIntervalSince(segment.startDate)) < minimumDateSeparation,
               abs(run.endUsedPercent - segment.startUsedPercent) < 0.001 {
                currentRun = QuotaForecastRun(
                    startDate: run.startDate,
                    endDate: segment.endDate,
                    startUsedPercent: run.startUsedPercent,
                    endUsedPercent: segment.endUsedPercent
                )
            } else {
                if let run = currentRun {
                    runs.append(run)
                }
                currentRun = QuotaForecastRun(
                    startDate: segment.startDate,
                    endDate: segment.endDate,
                    startUsedPercent: segment.startUsedPercent,
                    endUsedPercent: segment.endUsedPercent
                )
            }
        }

        if let currentRun {
            runs.append(currentRun)
        }
        return runs
    }

    private static func projectedHotRuns(
        from observedRuns: [QuotaForecastRun],
        now: Date,
        resetDate: Date
    ) -> [ProjectedHotRun] {
        let candidates = observedRuns.flatMap { run -> [ProjectedHotRunCandidate] in
            let gain = run.endUsedPercent - run.startUsedPercent
            let duration = run.endDate.timeIntervalSince(run.startDate)
            guard gain > minimumHotRunGain,
                  duration >= minimumHotRunDurationSeconds,
                  run.startDate < now else {
                return []
            }

            let ageDays = max(0, now.timeIntervalSince(run.startDate) / daySeconds)
            let recencyWeight = max(minimumHotRunRecencyWeight, exp(-hotRunRecencyDecay * ageDays))
            var offset = daySeconds
            while run.endDate.addingTimeInterval(offset) <= now.addingTimeInterval(minimumDateSeparation) {
                offset += daySeconds
            }

            var projected: [ProjectedHotRunCandidate] = []
            while run.startDate.addingTimeInterval(offset) < resetDate {
                let projectedStart = run.startDate.addingTimeInterval(offset)
                let projectedEnd = run.endDate.addingTimeInterval(offset)
                let clippedStart = max(now, projectedStart)
                let clippedEnd = min(resetDate, projectedEnd)
                if clippedEnd.timeIntervalSince(clippedStart) >= minimumHotRunDurationSeconds {
                    let visibleFraction = clippedEnd.timeIntervalSince(clippedStart) / duration
                    projected.append(ProjectedHotRunCandidate(
                        startDate: clippedStart,
                        endDate: clippedEnd,
                        gain: gain * visibleFraction,
                        weight: recencyWeight
                    ))
                }
                offset += daySeconds
            }
            return projected
        }
        return mergedProjectedHotRuns(from: candidates)
    }

    private static func mergedProjectedHotRuns(from candidates: [ProjectedHotRunCandidate]) -> [ProjectedHotRun] {
        let sorted = candidates.sorted { first, second in
            if first.startDate == second.startDate {
                return first.endDate < second.endDate
            }
            return first.startDate < second.startDate
        }
        var groups: [[ProjectedHotRunCandidate]] = []
        for candidate in sorted {
            if let lastGroup = groups.indices.last,
               let groupEnd = groups[lastGroup].map(\.endDate).max(),
               candidate.startDate.timeIntervalSince(groupEnd) <= hotRunGroupingGapSeconds {
                groups[lastGroup].append(candidate)
            } else {
                groups.append([candidate])
            }
        }

        return groups.compactMap { group in
            guard let startDate = group.map(\.startDate).min(),
                  let endDate = group.map(\.endDate).max(),
                  endDate.timeIntervalSince(startDate) >= minimumHotRunDurationSeconds else {
                return nil
            }

            let weightedGain = group.reduce(0.0) { total, candidate in
                total + candidate.gain * candidate.weight
            }
            let totalWeight = group.reduce(0.0) { total, candidate in
                total + candidate.weight
            }
            let representativeGain = totalWeight > 0
                ? weightedGain / totalWeight
                : group.map(\.gain).max() ?? 0
            let strongestGain = group.map { $0.gain * $0.weight }.max() ?? representativeGain
            let gain = max(representativeGain, strongestGain)
            guard gain > minimumHotRunGain else {
                return nil
            }
            return ProjectedHotRun(startDate: startDate, endDate: endDate, gain: gain)
        }
    }

    private static func hotRunAdjustedSegments(
        _ baseSegments: [QuotaForecastLineSegment],
        projectedHotRuns: [ProjectedHotRun],
        input: QuotaForecastKitInput,
        targetMultiplier: Double,
        marksCurrentActivity: Bool
    ) -> [QuotaForecastLineSegment] {
        guard baseSegments.isEmpty == false,
              projectedHotRuns.isEmpty == false else {
            return baseSegments
        }

        let dates = uniqueDates(
            [input.now] + input.futureDates
                + projectedHotRuns.flatMap { [$0.startDate, $0.endDate] }
        )
        guard dates.count >= 2 else {
            return baseSegments
        }

        let replayTargets = projectedHotRuns.compactMap { run -> ProjectedHotRunReplay? in
            let targetGain = max(0, run.gain * targetMultiplier)
            guard targetGain > minimumUsageDelta else {
                return nil
            }
            return ProjectedHotRunReplay(
                startDate: run.startDate,
                endDate: run.endDate,
                gain: targetGain
            )
        }
        guard replayTargets.isEmpty == false else {
            return baseSegments
        }

        var cumulativeReplayGain = 0.0
        var points = [ForecastPoint(date: input.now, usedPercent: input.current)]
        for (startDate, endDate) in zip(dates, dates.dropFirst()) where endDate > startDate {
            let intervalReplayGain = replayTargets.reduce(0.0) { total, target in
                total + target.gain(overlapStart: startDate, overlapEnd: endDate)
            }
            cumulativeReplayGain += intervalReplayGain
            let baselineValue = percent(at: endDate, in: baseSegments) ?? points.last?.usedPercent ?? input.current
            let replayFloor = input.current + cumulativeReplayGain
            let adjustedValue = max(points.last?.usedPercent ?? input.current, baselineValue, replayFloor)
            points.append(ForecastPoint(date: endDate, usedPercent: adjustedValue))
        }

        return lineSegments(
            from: points,
            marksCurrentActivity: marksCurrentActivity
        )
    }

    private static func activeContinuationCappedSegments(
        _ segments: [QuotaForecastLineSegment],
        input: QuotaForecastKitInput,
        observedRuns: [QuotaForecastRun]
    ) -> [QuotaForecastLineSegment] {
        guard let policy = activeContinuationPolicy(input: input, observedRuns: observedRuns),
              segments.isEmpty == false else {
            return segments
        }

        let dates = uniqueDates(
            [input.now, policy.capEndDate]
                + segments.flatMap { [$0.startDate, $0.endDate] }
        )
        guard dates.count >= 2,
              let rawAtCapEnd = percent(at: policy.capEndDate, in: segments) else {
            return segments
        }

        let cappedAtCapEnd = min(rawAtCapEnd, input.current + policy.allowedAdditionalGain)
        let excessAtCapEnd = max(0, rawAtCapEnd - cappedAtCapEnd)
        var points = [ForecastPoint(date: input.now, usedPercent: input.current)]

        for date in dates.dropFirst() where date > input.now {
            guard let rawValue = percent(at: date, in: segments) else {
                continue
            }

            let adjustedValue: Double
            if date <= policy.capEndDate {
                let progress = max(0, min(1, date.timeIntervalSince(input.now) / policy.capEndDate.timeIntervalSince(input.now)))
                let allowed = input.current + policy.allowedAdditionalGain * smoothStep(progress)
                adjustedValue = min(rawValue, allowed)
            } else {
                adjustedValue = rawValue - excessAtCapEnd
            }

            points.append(ForecastPoint(
                date: date,
                usedPercent: max(points.last?.usedPercent ?? input.current, adjustedValue, input.current)
            ))
        }

        return lineSegments(from: points, marksCurrentActivity: input.isCurrentlyActive)
    }

    private static func highEvidenceAdjustedSegments(
        rawHighSegments: [QuotaForecastLineSegment],
        lowSegments: [QuotaForecastLineSegment],
        input: QuotaForecastKitInput,
        observedRuns: [QuotaForecastRun]
    ) -> [QuotaForecastLineSegment] {
        let blend = max(
            idleEvidenceBlend(input: input),
            weakCurrentActivityBlend(input: input, observedRuns: observedRuns)
        )
        guard blend > 0,
              rawHighSegments.isEmpty == false,
              lowSegments.isEmpty == false else {
            return rawHighSegments
        }

        let dates = uniqueDates(
            [input.now]
                + input.futureDates
                + rawHighSegments.flatMap { [$0.startDate, $0.endDate] }
                + lowSegments.flatMap { [$0.startDate, $0.endDate] }
        )
        guard dates.count >= 2 else {
            return rawHighSegments
        }

        var points: [ForecastPoint] = []
        for date in dates {
            let low = percent(at: date, in: lowSegments) ?? input.current
            let high = percent(at: date, in: rawHighSegments) ?? low
            let blended = high - max(0, high - low) * blend
            points.append(ForecastPoint(date: date, usedPercent: max(low, blended, input.current)))
        }

        return lineSegments(from: points, marksCurrentActivity: input.isCurrentlyActive)
    }

    private static func highCeilingAdjustedSegments(
        _ highSegments: [QuotaForecastLineSegment],
        lowSegments: [QuotaForecastLineSegment],
        input: QuotaForecastKitInput,
        observedRuns: [QuotaForecastRun]
    ) -> [QuotaForecastLineSegment] {
        let replayTargets = projectedCeilingReplayTargets(
            from: observedRuns,
            now: input.now,
            resetDate: input.weeklyResetDate
        )
        guard highSegments.isEmpty == false,
              lowSegments.isEmpty == false,
              replayTargets.isEmpty == false else {
            return highSegments
        }

        let dates = uniqueDates(
            [input.now]
                + input.futureDates
                + highSegments.flatMap { [$0.startDate, $0.endDate] }
                + lowSegments.flatMap { [$0.startDate, $0.endDate] }
                + replayTargets.flatMap { [$0.startDate, $0.endDate] }
        )
        guard dates.count >= 2 else {
            return highSegments
        }

        var cumulativeReplayGain = 0.0
        var points = [ForecastPoint(date: input.now, usedPercent: input.current)]
        for (startDate, endDate) in zip(dates, dates.dropFirst()) where endDate > startDate {
            cumulativeReplayGain += replayTargets.reduce(0.0) { total, target in
                total + target.gain(overlapStart: startDate, overlapEnd: endDate)
            }

            let rawHigh = percent(at: endDate, in: highSegments) ?? points.last?.usedPercent ?? input.current
            let low = percent(at: endDate, in: lowSegments) ?? input.current
            let futureDays = max(0, endDate.timeIntervalSince(input.now) / daySeconds)
            let ceiling = input.current
                + cumulativeReplayGain * highCeilingReplayMultiplier
                + highCeilingUnmodeledDailyAllowance * futureDays
            let adjusted = min(rawHigh, max(low, ceiling))
            points.append(ForecastPoint(
                date: endDate,
                usedPercent: max(points.last?.usedPercent ?? input.current, adjusted, input.current)
            ))
        }

        return lineSegments(from: points, marksCurrentActivity: input.isCurrentlyActive)
    }

    private static func projectedCeilingReplayTargets(
        from observedRuns: [QuotaForecastRun],
        now: Date,
        resetDate: Date
    ) -> [ProjectedHotRunReplay] {
        observedRuns.enumerated().flatMap { index, run -> [ProjectedHotRunReplay] in
            let duration = run.endDate.timeIntervalSince(run.startDate)
            let gain = ceilingReplayGain(
                for: run,
                priorRuns: Array(observedRuns.prefix(index)),
                now: now
            ) * ceilingReplayScaleAfterQuietGap(
                forRunAt: index,
                in: observedRuns,
                now: now
            )
            guard gain > minimumHotRunGain,
                  duration >= minimumHotRunDurationSeconds,
                  run.startDate < now else {
                return []
            }

            var offset = daySeconds
            while run.endDate.addingTimeInterval(offset) <= now.addingTimeInterval(minimumDateSeparation) {
                offset += daySeconds
            }

            var targets: [ProjectedHotRunReplay] = []
            while run.startDate.addingTimeInterval(offset) < resetDate {
                let projectedStart = run.startDate.addingTimeInterval(offset)
                let projectedEnd = run.endDate.addingTimeInterval(offset)
                let clippedStart = max(now, projectedStart)
                let clippedEnd = min(resetDate, projectedEnd)
                if clippedEnd.timeIntervalSince(clippedStart) >= minimumHotRunDurationSeconds {
                    let visibleFraction = clippedEnd.timeIntervalSince(clippedStart) / duration
                    targets.append(ProjectedHotRunReplay(
                        startDate: clippedStart,
                        endDate: clippedEnd,
                        gain: gain * visibleFraction
                    ))
                }
                offset += daySeconds
            }
            return targets
        }
    }

    private static func ceilingReplayGain(
        for run: QuotaForecastRun,
        priorRuns: [QuotaForecastRun],
        now: Date
    ) -> Double {
        let gain = max(0, run.endUsedPercent - run.startUsedPercent)
        guard now.timeIntervalSince(run.endDate) <= recentRunAnalogCooldownSeconds,
              priorRuns.isEmpty == false else {
            return gain
        }

        let priorGains = priorRuns.map { $0.endUsedPercent - $0.startUsedPercent }
        let referenceGain = max(
            minimumActiveReferenceGain,
            quantile(priorGains, activeReferenceQuantile) * activeReferenceGainMultiplier,
            quantile(priorGains, 0.90) * activeReferenceGainMultiplier,
            (priorGains.max() ?? 0) * 0.90
        )
        let referenceDuration = max(
            minimumActiveReferenceDurationSeconds,
            quantile(priorRuns.map { $0.endDate.timeIntervalSince($0.startDate) }, activeReferenceQuantile)
                * activeReferenceDurationMultiplier
        )
        let currentDuration = max(0, now.timeIntervalSince(run.startDate))
        let evidence = max(
            currentDuration / max(referenceDuration, 1),
            gain / max(referenceGain, minimumUsageDelta)
        )
        let boundedGain = min(gain, referenceGain)
        if evidence < weakActivityEvidenceFull {
            return boundedGain * max(minimumCurrentReplayEvidenceMultiplier, evidence / weakActivityEvidenceFull)
        }
        if evidence > 1 {
            return boundedGain * overlongCurrentReplayMultiplier
        }
        return boundedGain
    }

    private static func ceilingReplayScaleAfterQuietGap(
        forRunAt index: Int,
        in observedRuns: [QuotaForecastRun],
        now: Date
    ) -> Double {
        guard observedRuns.indices.contains(index) else {
            return 1
        }

        let run = observedRuns[index]
        let quietEndDate = observedRuns.indices.contains(index + 1)
            ? observedRuns[index + 1].startDate
            : now
        let quietDuration = quietEndDate.timeIntervalSince(run.endDate)
        guard quietDuration > idleCeilingDiscountStartSeconds else {
            return 1
        }

        let progress = (quietDuration - idleCeilingDiscountStartSeconds)
            / max(1, idleCeilingDiscountFullSeconds - idleCeilingDiscountStartSeconds)
        return 1 - maxIdleCeilingReplayDiscount * smoothStep(progress)
    }

    private static func activeContinuationPolicy(
        input: QuotaForecastKitInput,
        observedRuns: [QuotaForecastRun]
    ) -> ActiveContinuationPolicy? {
        guard input.isCurrentlyActive,
              let currentRun = observedRuns.last,
              input.now.timeIntervalSince(currentRun.endDate) <= activeContinuationGraceSeconds else {
            return nil
        }

        let priorRuns = observedRuns.dropLast().filter { run in
            run.endDate <= currentRun.startDate.addingTimeInterval(-minimumDateSeparation)
        }
        guard priorRuns.isEmpty == false else {
            return nil
        }

        let referenceDuration = max(
            minimumActiveReferenceDurationSeconds,
            quantile(priorRuns.map { $0.endDate.timeIntervalSince($0.startDate) }, activeReferenceQuantile)
                * activeReferenceDurationMultiplier
        )
        let referenceGain = max(
            minimumActiveReferenceGain,
            quantile(priorRuns.map { $0.endUsedPercent - $0.startUsedPercent }, activeReferenceQuantile)
                * activeReferenceGainMultiplier
        )
        let currentDuration = max(0, input.now.timeIntervalSince(currentRun.startDate))
        let currentGain = max(0, input.current - currentRun.startUsedPercent)
        let progress = max(
            currentDuration / max(referenceDuration, 1),
            currentGain / max(referenceGain, minimumUsageDelta)
        )
        let remainingDuration = max(0, referenceDuration - currentDuration)
        let remainingGain = max(0, referenceGain - currentGain)
        let cooldown = activeContinuationCooldownSeconds * smoothStep(min(1, progress))
        let horizon = min(
            maxActiveContinuationCapSeconds,
            max(minActiveContinuationCapSeconds, remainingDuration + cooldown)
        )
        guard horizon > minimumDateSeparation else {
            return nil
        }

        return ActiveContinuationPolicy(
            capEndDate: input.now.addingTimeInterval(horizon),
            allowedAdditionalGain: remainingGain
        )
    }

    private static func idleEvidenceBlend(input: QuotaForecastKitInput) -> Double {
        guard input.isCurrentlyActive == false,
              let lastIncreaseDate = lastIncreaseDate(in: input.inputSamples) else {
            return 0
        }

        let idleDuration = input.now.timeIntervalSince(lastIncreaseDate)
        guard idleDuration > idleEvidenceBlendStartSeconds else {
            return 0
        }

        let progress = (idleDuration - idleEvidenceBlendStartSeconds)
            / max(1, idleEvidenceBlendFullSeconds - idleEvidenceBlendStartSeconds)
        return maxIdleEvidenceBlend * smoothStep(progress)
    }

    private static func weakCurrentActivityBlend(
        input: QuotaForecastKitInput,
        observedRuns: [QuotaForecastRun]
    ) -> Double {
        guard input.isCurrentlyActive,
              let currentRun = observedRuns.last else {
            return 0
        }

        let priorRuns = observedRuns.dropLast()
        guard priorRuns.isEmpty == false else {
            return 0
        }

        let referenceDuration = max(
            minimumActiveReferenceDurationSeconds,
            quantile(priorRuns.map { $0.endDate.timeIntervalSince($0.startDate) }, weakActivityReferenceQuantile)
        )
        let referenceGain = max(
            minimumActiveReferenceGain,
            quantile(priorRuns.map { $0.endUsedPercent - $0.startUsedPercent }, weakActivityReferenceQuantile)
        )
        let currentDuration = max(0, input.now.timeIntervalSince(currentRun.startDate))
        let currentGain = max(0, input.current - currentRun.startUsedPercent)
        let evidence = max(
            currentDuration / max(referenceDuration, 1),
            currentGain / max(referenceGain, minimumUsageDelta)
        )
        guard evidence < weakActivityEvidenceFull else {
            return 0
        }

        let missingEvidence = 1 - max(0, evidence) / weakActivityEvidenceFull
        return maxWeakActivityBlend * smoothStep(missingEvidence)
    }

    private static func lastIncreaseDate(in samples: [ForecastInputSample]) -> Date? {
        var date: Date?
        for (previous, current) in zip(samples, samples.dropFirst()) {
            if current.usedPercent - previous.usedPercent > minimumUsageDelta {
                date = current.date
            }
        }
        return date
    }

    private static func lineSegments(
        from points: [ForecastPoint],
        marksCurrentActivity: Bool
    ) -> [QuotaForecastLineSegment] {
        var hasMarkedCurrentActivity = false
        var segments: [QuotaForecastLineSegment] = []
        for (startPoint, endPoint) in zip(points, points.dropFirst()) where endPoint.date > startPoint.date {
            let kind: QuotaForecastLineSegmentKind
            if endPoint.usedPercent - startPoint.usedPercent <= minimumUsageDelta {
                kind = .projectedIdle
            } else if marksCurrentActivity,
                      hasMarkedCurrentActivity == false {
                kind = .currentProjectedActivity
                hasMarkedCurrentActivity = true
            } else {
                kind = .projectedActivity
            }

            appendLineSegment(
                QuotaForecastLineSegment(
                    startDate: startPoint.date,
                    endDate: endPoint.date,
                    startUsedPercent: startPoint.usedPercent,
                    endUsedPercent: endPoint.usedPercent,
                    kind: kind
                ),
                into: &segments
            )
        }
        return segments
    }

    private static func corridorPoints(
        lowSegments: [QuotaForecastLineSegment],
        highSegments: [QuotaForecastLineSegment],
        dates: [Date],
        current: Double
    ) -> [QuotaForecastCorridorPoint] {
        uniqueDates(dates).map { date in
            let low = percent(at: date, in: lowSegments) ?? current
            let high = percent(at: date, in: highSegments) ?? low
            return QuotaForecastCorridorPoint(
                date: date,
                averageUsedPercent: (low + high) / 2,
                lowerUsedPercent: min(low, high),
                upperUsedPercent: max(low, high)
            )
        }
    }

    private static func observedIntensityRuns(from samples: [ForecastInputSample]) -> [QuotaForecastRun] {
        guard samples.count >= 2 else {
            return []
        }

        var runs: [QuotaForecastRun] = []
        var currentRun: QuotaForecastRun?
        for (previous, current) in zip(samples, samples.dropFirst()) {
            let gain = current.usedPercent - previous.usedPercent
            guard gain > minimumUsageDelta,
                  current.date > previous.date else {
                continue
            }

            let interval = QuotaForecastRun(
                startDate: previous.date,
                endDate: current.date,
                startUsedPercent: previous.usedPercent,
                endUsedPercent: current.usedPercent
            )
            if let run = currentRun,
               interval.startDate.timeIntervalSince(run.endDate) <= observedRunMergeGapSeconds {
                currentRun = QuotaForecastRun(
                    startDate: run.startDate,
                    endDate: interval.endDate,
                    startUsedPercent: run.startUsedPercent,
                    endUsedPercent: interval.endUsedPercent
                )
            } else {
                if let run = currentRun {
                    runs.append(run)
                }
                currentRun = interval
            }
        }

        if let currentRun {
            runs.append(currentRun)
        }
        return runs
    }

    private static func appendLineSegment(
        _ segment: QuotaForecastLineSegment,
        into segments: inout [QuotaForecastLineSegment]
    ) {
        guard segment.endDate > segment.startDate else {
            return
        }

        if let last = segments.last,
           last.kind == segment.kind,
           abs(last.endDate.timeIntervalSince(segment.startDate)) < minimumDateSeparation,
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

    private static func percent(at date: Date, in segments: [QuotaForecastLineSegment]) -> Double? {
        guard let first = segments.first else {
            return nil
        }
        if date <= first.startDate {
            return first.startUsedPercent
        }

        for segment in segments {
            if date <= segment.startDate {
                return segment.startUsedPercent
            }
            if date <= segment.endDate {
                let duration = segment.endDate.timeIntervalSince(segment.startDate)
                guard duration > 0 else {
                    return segment.endUsedPercent
                }
                let progress = date.timeIntervalSince(segment.startDate) / duration
                return segment.startUsedPercent + (segment.endUsedPercent - segment.startUsedPercent) * progress
            }
        }

        return segments.last?.endUsedPercent
    }

    private static func uniqueDates(_ dates: [Date]) -> [Date] {
        var unique: [Date] = []
        for date in dates.sorted() {
            if let last = unique.last,
               abs(date.timeIntervalSince(last)) < minimumDateSeparation {
                continue
            }
            unique.append(date)
        }
        return unique
    }

    private static func quantile(_ values: [Double], _ probability: Double) -> Double {
        let sorted = values.sorted()
        guard sorted.isEmpty == false else {
            return 0
        }
        guard sorted.count > 1 else {
            return sorted[0]
        }

        let p = max(0, min(1, probability))
        let position = p * Double(sorted.count - 1)
        let lowerIndex = Int(position.rounded(.down))
        let upperIndex = Int(position.rounded(.up))
        if lowerIndex == upperIndex {
            return sorted[lowerIndex]
        }

        let fraction = position - Double(lowerIndex)
        return sorted[lowerIndex] * (1 - fraction) + sorted[upperIndex] * fraction
    }

    private static func smoothStep(_ value: Double) -> Double {
        let clamped = max(0, min(1, value))
        return clamped * clamped * (3 - 2 * clamped)
    }

    private static let forecastStepSeconds: TimeInterval = 30 * 60
    private static let minimumUsageDelta: Double = 0.0001
    private static let minimumDateSeparation: TimeInterval = 0.5
    private static let observedRunMergeGapSeconds: TimeInterval = 90 * 60
    private static let daySeconds: TimeInterval = 24 * 60 * 60
    private static let minimumHotRunGain: Double = 0.5
    private static let minimumHotRunDurationSeconds: TimeInterval = 60
    private static let hotRunGroupingGapSeconds: TimeInterval = 90 * 60
    private static let hotRunRecencyDecay = 0.18
    private static let minimumHotRunRecencyWeight = 0.35
    private static let optimisticHotRunMultiplier = 0.55
    private static let pessimisticHotRunMultiplier = 1.05
    private static let activeContinuationGraceSeconds: TimeInterval = 10 * 60
    private static let recentRunAnalogCooldownSeconds: TimeInterval = 4 * 60 * 60
    private static let activeReferenceQuantile = 0.75
    private static let activeReferenceDurationMultiplier = 1.15
    private static let activeReferenceGainMultiplier = 1.15
    private static let minimumActiveReferenceDurationSeconds: TimeInterval = 60 * 60
    private static let minimumActiveReferenceGain = 1.0
    private static let minActiveContinuationCapSeconds: TimeInterval = 2 * 60 * 60
    private static let maxActiveContinuationCapSeconds: TimeInterval = 12 * 60 * 60
    private static let activeContinuationCooldownSeconds: TimeInterval = 8 * 60 * 60
    private static let idleEvidenceBlendStartSeconds: TimeInterval = 6 * 60 * 60
    private static let idleEvidenceBlendFullSeconds: TimeInterval = 24 * 60 * 60
    private static let maxIdleEvidenceBlend = 0.30
    private static let idleCeilingDiscountStartSeconds: TimeInterval = 6 * 60 * 60
    private static let idleCeilingDiscountFullSeconds: TimeInterval = 16 * 60 * 60
    private static let maxIdleCeilingReplayDiscount = 0.45
    private static let weakActivityReferenceQuantile = 0.60
    private static let weakActivityEvidenceFull = 0.45
    private static let maxWeakActivityBlend = 0.60
    private static let highCeilingReplayMultiplier = 1.30
    private static let highCeilingUnmodeledDailyAllowance = 2.0
    private static let minimumCurrentReplayEvidenceMultiplier = 0.25
    private static let overlongCurrentReplayMultiplier = 0.60
}

struct QuotaForecastKitInput: Sendable {
    let limitId: String?
    let limitName: String?
    let planType: String?
    let weeklyStartDate: Date
    let weeklyResetDate: Date
    let now: Date
    let current: Double
    let stepSeconds: TimeInterval
    let observedDates: [Date]
    let observedValues: [Double]
    let futureDates: [Date]
    let inputSamples: [ForecastInputSample]
    let configuration: QuotaForecastConfiguration

    var totalCount: Int {
        observedValues.count + futureDates.count
    }

    var hasUsageIncreases: Bool {
        zip(observedValues, observedValues.dropFirst()).contains { previous, current in
            current - previous > 0.0001
        }
    }

    var isCurrentlyActive: Bool {
        var lastIncreaseDate: Date?
        for (previous, current) in zip(inputSamples, inputSamples.dropFirst()) {
            if current.usedPercent - previous.usedPercent > 0.0001 {
                lastIncreaseDate = current.date
            }
        }
        guard let lastIncreaseDate else {
            return false
        }
        return now.timeIntervalSince(lastIncreaseDate) <= 10 * 60
    }
}

extension QuotaForecastKitInput: Encodable {
    enum CodingKeys: String, CodingKey {
        case limitId
        case limitName
        case planType
        case weeklyStartDate
        case weeklyResetDate
        case now
        case current
        case stepSeconds
        case observedDates
        case observedValues
        case futureDates
        case observedCount
        case futureCount
        case totalCount
        case samples
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(limitId, forKey: .limitId)
        try container.encodeIfPresent(limitName, forKey: .limitName)
        try container.encodeIfPresent(planType, forKey: .planType)
        try container.encode(weeklyStartDate, forKey: .weeklyStartDate)
        try container.encode(weeklyResetDate, forKey: .weeklyResetDate)
        try container.encode(now, forKey: .now)
        try container.encode(current, forKey: .current)
        try container.encode(stepSeconds, forKey: .stepSeconds)
        try container.encode(observedDates, forKey: .observedDates)
        try container.encode(observedValues, forKey: .observedValues)
        try container.encode(futureDates, forKey: .futureDates)
        try container.encode(observedValues.count, forKey: .observedCount)
        try container.encode(futureDates.count, forKey: .futureCount)
        try container.encode(totalCount, forKey: .totalCount)
        let encodedSamples = zip(observedDates, observedValues).map { date, value in
            QuotaForecastKitEncodedSample(
                date: date,
                offsetSeconds: date.timeIntervalSince(weeklyStartDate),
                weeklyUsedPercent: value
            )
        }
        try container.encode(encodedSamples, forKey: .samples)
    }
}

struct QuotaForecastKitParameterSummary: Encodable, Sendable {
    let softQuota: Double
    let ensembleSize: Int
    let randomSeed: UInt64
    let allowOverrun: Bool
    let minBlockLength: Int
    let maxBlockLength: Int
    let contextLength: Int
    let optimisticPatternQuantile: Double
    let pessimisticPatternQuantile: Double
    let optimisticMagnitudeMultiplier: Double
    let optimisticConservationStrength: Double
    let optimisticTargetQuotaFraction: Double
    let minimumConservationMultiplier: Double
    let pessimisticMagnitudeMultiplier: Double
    let pessimisticRepresentativeQuantile: Double
    let quantizationStep: Double?

    init(_ configuration: QuotaForecastConfiguration) {
        self.softQuota = configuration.softQuota
        self.ensembleSize = configuration.ensembleSize
        self.randomSeed = configuration.randomSeed
        self.allowOverrun = configuration.allowOverrun
        self.minBlockLength = configuration.minBlockLength
        self.maxBlockLength = configuration.maxBlockLength
        self.contextLength = configuration.contextLength
        self.optimisticPatternQuantile = configuration.optimisticPatternQuantile
        self.pessimisticPatternQuantile = configuration.pessimisticPatternQuantile
        self.optimisticMagnitudeMultiplier = configuration.optimisticMagnitudeMultiplier
        self.optimisticConservationStrength = configuration.optimisticConservationStrength
        self.optimisticTargetQuotaFraction = configuration.optimisticTargetQuotaFraction
        self.minimumConservationMultiplier = configuration.minimumConservationMultiplier
        self.pessimisticMagnitudeMultiplier = configuration.pessimisticMagnitudeMultiplier
        self.pessimisticRepresentativeQuantile = configuration.pessimisticRepresentativeQuantile
        self.quantizationStep = configuration.quantizationStep
    }
}

struct ForecastInputSample: Encodable, Sendable {
    var date: Date
    var usedPercent: Double
    var limitId: String?
    var limitName: String?
    var planType: String?
}

private struct ProjectedHotRunCandidate {
    let startDate: Date
    let endDate: Date
    let gain: Double
    let weight: Double
}

private struct ProjectedHotRun {
    let startDate: Date
    let endDate: Date
    let gain: Double
}

private struct ProjectedHotRunReplay {
    let startDate: Date
    let endDate: Date
    let gain: Double

    func gain(overlapStart: Date, overlapEnd: Date) -> Double {
        let start = max(startDate, overlapStart)
        let end = min(endDate, overlapEnd)
        let duration = endDate.timeIntervalSince(startDate)
        guard end > start,
              duration > 0 else {
            return 0
        }
        return gain * end.timeIntervalSince(start) / duration
    }
}

private struct ActiveContinuationPolicy {
    let capEndDate: Date
    let allowedAdditionalGain: Double
}

private struct ForecastObservedSeries {
    let dates: [Date]
    let values: [Double]
}

private struct ForecastPoint {
    let date: Date
    let usedPercent: Double
}

private struct QuotaForecastKitEncodedSample: Encodable {
    let date: Date
    let offsetSeconds: Double
    let weeklyUsedPercent: Double
}
