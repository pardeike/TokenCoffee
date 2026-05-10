import Foundation
import TokenUsageForecast

enum TokenUsageForecastAdapter {
    static func makeCycleRunForecast(
        current: Double,
        startDate: Date,
        resetDate: Date,
        now: Date,
        samples: [QuotaSample]
    ) -> QuotaCycleRunForecast? {
        guard now < resetDate,
              resetDate > startDate else {
            return nil
        }

        let inputSamples = forecastInputSamples(
            current: current,
            startDate: startDate,
            now: now,
            samples: samples
        )
        guard inputSamples.isEmpty == false,
              hasUsageIncreases(inputSamples) else {
            return nil
        }

        let snapshot = UsageLimitSnapshot(
            limitId: inputSamples.last?.limitId,
            limitName: inputSamples.last?.limitName,
            planType: inputSamples.last?.planType,
            weeklyWindowMinutes: resetDate.timeIntervalSince(startDate) / 60,
            elapsedWindowSeconds: now.timeIntervalSince(startDate),
            weeklyUsedPercent: current,
            samples: inputSamples.map { inputSample in
                UsageSample(
                    offsetSeconds: inputSample.date.timeIntervalSince(startDate),
                    weeklyUsedPercent: inputSample.usedPercent
                )
            }
        )

        let result: UsageForecastResult
        do {
            result = try TokenUsageForecaster(parameters: .defaults).forecast(from: snapshot)
        } catch {
            return nil
        }

        let optimisticSegments = lineSegments(
            from: result.optimistic,
            weeklyStartDate: startDate,
            now: now,
            resetDate: resetDate,
            cutoffMinutes: result.cutoffMinutes
        )
        let pessimisticSegments = lineSegments(
            from: result.pessimistic,
            weeklyStartDate: startDate,
            now: now,
            resetDate: resetDate,
            cutoffMinutes: result.cutoffMinutes
        )
        guard optimisticSegments.isEmpty == false,
              pessimisticSegments.isEmpty == false else {
            return nil
        }

        return QuotaCycleRunForecast(
            projectedWeeklyUsedPercentAtReset: result.optimistic.finalUsedPercent,
            lowProjectedWeeklyUsedPercentAtReset: result.optimistic.finalUsedPercent,
            highProjectedWeeklyUsedPercentAtReset: result.pessimistic.finalUsedPercent,
            ghostRuns: forecastRuns(
                from: result.pessimistic,
                weeklyStartDate: startDate,
                resetDate: resetDate
            ),
            averageRuns: forecastRuns(
                from: result.optimistic,
                weeklyStartDate: startDate,
                resetDate: resetDate
            ),
            lineSegments: optimisticSegments,
            lowLineSegments: optimisticSegments,
            highLineSegments: pessimisticSegments,
            earliestLineSegments: optimisticSegments,
            latestLineSegments: pessimisticSegments,
            corridorPoints: corridorPoints(
                result: result,
                weeklyStartDate: startDate,
                now: now,
                resetDate: resetDate
            ),
            observedIntensityRuns: observedIntensityRuns(
                from: result.sessions,
                weeklyStartDate: startDate,
                now: now
            )
        )
    }

    private static func forecastInputSamples(
        current: Double,
        startDate: Date,
        now: Date,
        samples: [QuotaSample]
    ) -> [ForecastInputSample] {
        var inputSamples = samples
            .filter { $0.capturedAt >= startDate && $0.capturedAt <= now }
            .sorted { $0.capturedAt < $1.capturedAt }
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

    private static func hasUsageIncreases(_ samples: [ForecastInputSample]) -> Bool {
        guard samples.count >= 2 else {
            return false
        }
        for (previous, current) in zip(samples, samples.dropFirst()) {
            if current.usedPercent - previous.usedPercent > 0.0001 {
                return true
            }
        }
        return false
    }

    private static func lineSegments(
        from forecast: ScenarioForecast,
        weeklyStartDate: Date,
        now: Date,
        resetDate: Date,
        cutoffMinutes: Double
    ) -> [QuotaForecastLineSegment] {
        guard forecast.points.isEmpty == false else {
            return []
        }

        let resetMinutes = resetDate.timeIntervalSince(weeklyStartDate) / 60
        let nowMinutes = now.timeIntervalSince(weeklyStartDate) / 60
        let dates = forecastLineOffsets(
            forecast: forecast,
            nowMinutes: nowMinutes,
            resetMinutes: resetMinutes
        )

        var segments: [QuotaForecastLineSegment] = []
        for (startMinutes, endMinutes) in zip(dates, dates.dropFirst()) where endMinutes > startMinutes {
            let startPercent = interpolatedUsagePercent(in: forecast.points, at: startMinutes)
                ?? forecast.points.first?.usedPercent
                ?? 0
            let endPercent = interpolatedUsagePercent(in: forecast.points, at: endMinutes)
                ?? startPercent
            appendLineSegment(
                QuotaForecastLineSegment(
                    startDate: weeklyStartDate.addingTimeInterval(startMinutes * 60),
                    endDate: weeklyStartDate.addingTimeInterval(endMinutes * 60),
                    startUsedPercent: startPercent,
                    endUsedPercent: endPercent,
                    kind: segmentKind(
                        startMinutes: startMinutes,
                        endMinutes: endMinutes,
                        candidates: forecast.candidates,
                        cutoffMinutes: cutoffMinutes
                    )
                ),
                into: &segments
            )
        }
        return segments
    }

    private static func forecastLineOffsets(
        forecast: ScenarioForecast,
        nowMinutes: Double,
        resetMinutes: Double
    ) -> [Double] {
        var offsets = [nowMinutes, resetMinutes]
        offsets += forecast.points.map(\.offsetMinutes)
        for candidate in forecast.candidates {
            offsets.append(candidate.startMinutes)
            offsets.append(candidate.startMinutes + candidate.durationMinutes)
        }

        return uniqueOffsets(offsets.compactMap { offset -> Double? in
            guard offset.isFinite else {
                return nil
            }
            return min(resetMinutes, max(nowMinutes, offset))
        })
    }

    private static func segmentKind(
        startMinutes: Double,
        endMinutes: Double,
        candidates: [FutureSessionCandidate],
        cutoffMinutes: Double
    ) -> QuotaForecastLineSegmentKind {
        let activeCandidates = candidates.filter { candidate in
            guard candidate.gainPercent > 0.001 else {
                return false
            }
            let candidateStart = max(candidate.startMinutes, cutoffMinutes)
            let candidateEnd = candidate.startMinutes + max(1, candidate.durationMinutes)
            return candidateEnd > startMinutes + 0.001
                && candidateStart < endMinutes - 0.001
        }

        guard activeCandidates.isEmpty == false else {
            return .projectedIdle
        }
        if activeCandidates.contains(where: { $0.source == .continuation }) {
            return .currentProjectedActivity
        }
        return .projectedActivity
    }

    private static func forecastRuns(
        from forecast: ScenarioForecast,
        weeklyStartDate: Date,
        resetDate: Date
    ) -> [QuotaForecastRun] {
        forecast.candidates.compactMap { candidate in
            let startDate = weeklyStartDate.addingTimeInterval(candidate.startMinutes * 60)
            let endDate = min(
                resetDate,
                weeklyStartDate.addingTimeInterval((candidate.startMinutes + max(1, candidate.durationMinutes)) * 60)
            )
            guard endDate > startDate else {
                return nil
            }

            let startUsedPercent = interpolatedUsagePercent(in: forecast.points, at: candidate.startMinutes)
                ?? forecast.points.first?.usedPercent
                ?? 0
            let endOffset = endDate.timeIntervalSince(weeklyStartDate) / 60
            let endUsedPercent = interpolatedUsagePercent(in: forecast.points, at: endOffset)
                ?? startUsedPercent
            return QuotaForecastRun(
                startDate: startDate,
                endDate: endDate,
                startUsedPercent: startUsedPercent,
                endUsedPercent: endUsedPercent
            )
        }
    }

    private static func corridorPoints(
        result: UsageForecastResult,
        weeklyStartDate: Date,
        now: Date,
        resetDate: Date
    ) -> [QuotaForecastCorridorPoint] {
        let nowMinutes = now.timeIntervalSince(weeklyStartDate) / 60
        let resetMinutes = resetDate.timeIntervalSince(weeklyStartDate) / 60
        let offsets = uniqueOffsets(
            ([nowMinutes, resetMinutes] + result.optimistic.points.map(\.offsetMinutes) + result.pessimistic.points.map(\.offsetMinutes))
                .map { min(resetMinutes, max(nowMinutes, $0)) }
        )

        return offsets.map { offset in
            let low = interpolatedUsagePercent(in: result.optimistic.points, at: offset)
                ?? result.currentUsedPercent
            let high = interpolatedUsagePercent(in: result.pessimistic.points, at: offset)
                ?? low
            return QuotaForecastCorridorPoint(
                date: weeklyStartDate.addingTimeInterval(offset * 60),
                averageUsedPercent: (low + high) / 2,
                lowerUsedPercent: min(low, high),
                upperUsedPercent: max(low, high)
            )
        }
    }

    private static func observedIntensityRuns(
        from sessions: [UsageSession],
        weeklyStartDate: Date,
        now: Date
    ) -> [QuotaForecastRun] {
        sessions.compactMap { session in
            guard session.isIntense else {
                return nil
            }

            let startDate = weeklyStartDate.addingTimeInterval(session.startMinutes * 60)
            let endMinutes = max(session.endMinutes, session.startMinutes + session.durationMinutes)
            let endDate = min(now, weeklyStartDate.addingTimeInterval(endMinutes * 60))
            guard endDate > startDate else {
                return nil
            }

            let firstEvent = session.events.first
            let lastEvent = session.events.last
            return QuotaForecastRun(
                startDate: startDate,
                endDate: endDate,
                startUsedPercent: firstEvent.map { $0.usedPercent - $0.deltaPercent } ?? 0,
                endUsedPercent: lastEvent?.usedPercent ?? firstEvent?.usedPercent ?? 0
            )
        }
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

    private static func uniqueOffsets(_ offsets: [Double]) -> [Double] {
        var unique: [Double] = []
        for offset in offsets.sorted() {
            if let last = unique.last,
               abs(offset - last) < 1.0 / 120.0 {
                continue
            }
            unique.append(offset)
        }
        return unique
    }
}

private struct ForecastInputSample: Sendable {
    var date: Date
    var usedPercent: Double
    var limitId: String?
    var limitName: String?
    var planType: String?
}
