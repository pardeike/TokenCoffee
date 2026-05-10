import Foundation
import TokenUsageForecast

public enum QuotaForecastDiagnosticExporter {
    public static func makeDiagnosticsData(
        snapshot: RateLimitSnapshot?,
        samples: [QuotaSample],
        now: Date = Date(),
        generatedAt: Date = Date(),
        syncStatusDescription: String? = nil
    ) throws -> Data {
        let projection = QuotaProjectionEngine.make(snapshot: snapshot, samples: samples, now: now)
        let packageContext = makePackageContext(snapshot: snapshot, samples: samples, now: now)
        let packageResult: UsageForecastResult?
        let packageError: String?

        if let input = packageContext.input {
            if input.hasUsageIncreases {
                do {
                    packageResult = try TokenUsageForecastAdapter.forecast(input.snapshot)
                    packageError = nil
                } catch {
                    packageResult = nil
                    packageError = error.localizedDescription
                }
            } else {
                packageResult = nil
                packageError = "No usage increases found in forecast input."
            }
        } else {
            packageResult = nil
            packageError = packageContext.errorDescription
        }

        let payload = QuotaForecastDiagnosticsPayload(
            generatedAt: generatedAt,
            now: now,
            syncStatus: syncStatusDescription,
            window: packageContext.window,
            samples: ForecastSampleSummary(
                storedSampleCount: samples.count,
                currentWindowSampleCount: packageContext.currentWindowSampleCount,
                inputSampleCount: packageContext.input?.snapshot.samples.count ?? 0,
                firstInputOffsetSeconds: packageContext.input?.snapshot.samples.first?.offsetSeconds,
                lastInputOffsetSeconds: packageContext.input?.snapshot.samples.last?.offsetSeconds
            ),
            display: ForecastDisplaySummary(
                currentWeeklyUsedPercent: projection.currentWeeklyUsedPercent,
                fallbackProjectedWeeklyUsedPercentAtReset: projection.projectedWeeklyUsedPercentAtReset,
                displayedLowProjectedWeeklyUsedPercentAtReset: projection.cycleRunForecast?.lowProjectedWeeklyUsedPercentAtReset
                    ?? projection.projectedWeeklyUsedPercentAtReset,
                displayedHighProjectedWeeklyUsedPercentAtReset: projection.cycleRunForecast?.highProjectedWeeklyUsedPercentAtReset
                    ?? projection.projectedWeeklyUsedPercentAtReset,
                paceState: projection.paceState.rawValue
            ),
            packageParameters: .defaults,
            packageInput: packageContext.input?.snapshot,
            packageResult: packageResult,
            packageError: packageError
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(payload)
    }

    private static func makePackageContext(
        snapshot: RateLimitSnapshot?,
        samples: [QuotaSample],
        now: Date
    ) -> ForecastPackageContext {
        guard let snapshot else {
            return ForecastPackageContext(
                window: nil,
                currentWindowSampleCount: 0,
                input: nil,
                errorDescription: "No quota snapshot."
            )
        }

        guard let weekly = snapshot.secondary else {
            return ForecastPackageContext(
                window: nil,
                currentWindowSampleCount: 0,
                input: nil,
                errorDescription: "Quota snapshot has no weekly window."
            )
        }

        let current = weekly.usedPercent
        guard let resetDate = weekly.resetDate,
              let durationMinutes = weekly.windowDurationMins,
              durationMinutes > 0 else {
            return ForecastPackageContext(
                window: nil,
                currentWindowSampleCount: 0,
                input: nil,
                errorDescription: "Quota snapshot has no valid weekly reset/window duration."
            )
        }

        let startDate = resetDate.addingTimeInterval(-TimeInterval(durationMinutes * 60))
        let elapsedWindowSeconds = now.timeIntervalSince(startDate)
        let currentWindowSamples = QuotaProjectionEngine.currentWindowSamples(
            snapshot: snapshot,
            startDate: startDate,
            resetDate: resetDate,
            now: now,
            samples: samples
        )
        let input = TokenUsageForecastAdapter.makeForecastInput(
            current: current,
            startDate: startDate,
            resetDate: resetDate,
            now: now,
            samples: currentWindowSamples
        )

        return ForecastPackageContext(
            window: ForecastWindowSummary(
                weeklyStartDate: startDate,
                weeklyResetDate: resetDate,
                weeklyWindowMinutes: durationMinutes,
                elapsedWindowSeconds: elapsedWindowSeconds
            ),
            currentWindowSampleCount: currentWindowSamples.count,
            input: input,
            errorDescription: input == nil ? "No usable forecast input." : nil
        )
    }
}

private struct ForecastPackageContext {
    let window: ForecastWindowSummary?
    let currentWindowSampleCount: Int
    let input: TokenUsageForecastInput?
    let errorDescription: String?
}

private struct QuotaForecastDiagnosticsPayload: Encodable {
    let generatedAt: Date
    let now: Date
    let syncStatus: String?
    let window: ForecastWindowSummary?
    let samples: ForecastSampleSummary
    let display: ForecastDisplaySummary
    let packageParameters: ForecastParameters
    let packageInput: UsageLimitSnapshot?
    let packageResult: UsageForecastResult?
    let packageError: String?
}

private struct ForecastWindowSummary: Encodable {
    let weeklyStartDate: Date
    let weeklyResetDate: Date
    let weeklyWindowMinutes: Int
    let elapsedWindowSeconds: TimeInterval
}

private struct ForecastSampleSummary: Encodable {
    let storedSampleCount: Int
    let currentWindowSampleCount: Int
    let inputSampleCount: Int
    let firstInputOffsetSeconds: Double?
    let lastInputOffsetSeconds: Double?
}

private struct ForecastDisplaySummary: Encodable {
    let currentWeeklyUsedPercent: Double
    let fallbackProjectedWeeklyUsedPercentAtReset: Double?
    let displayedLowProjectedWeeklyUsedPercentAtReset: Double?
    let displayedHighProjectedWeeklyUsedPercentAtReset: Double?
    let paceState: String
}
