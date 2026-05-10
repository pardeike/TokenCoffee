import Foundation

public struct DemoQuotaScenario: Equatable, Sendable {
    public let now: Date
    public let snapshot: RateLimitSnapshot
    public let samples: [QuotaSample]
    public let account: CodexAccountSnapshot?

    public init(
        now: Date,
        snapshot: RateLimitSnapshot,
        samples: [QuotaSample],
        account: CodexAccountSnapshot?
    ) {
        self.now = now
        self.snapshot = snapshot
        self.samples = samples
        self.account = account
    }
}

public struct DemoQuotaData: Decodable, Equatable, Sendable {
    public let limitId: String
    public let limitName: String?
    public let planType: String?
    public let weeklyWindowMinutes: Int
    public let elapsedWindowMinutes: Int
    public let elapsedWindowSeconds: Int?
    public let weeklyUsedPercent: Double
    public let fiveHourUsedPercent: Double
    public let fiveHourResetOffsetMinutes: Int
    public let fiveHourResetOffsetSeconds: Int?
    public let samples: [DemoQuotaSamplePoint]

    public init(
        limitId: String,
        limitName: String?,
        planType: String?,
        weeklyWindowMinutes: Int,
        elapsedWindowMinutes: Int,
        elapsedWindowSeconds: Int? = nil,
        weeklyUsedPercent: Double,
        fiveHourUsedPercent: Double,
        fiveHourResetOffsetMinutes: Int,
        fiveHourResetOffsetSeconds: Int? = nil,
        samples: [DemoQuotaSamplePoint]
    ) {
        self.limitId = limitId
        self.limitName = limitName
        self.planType = planType
        self.weeklyWindowMinutes = weeklyWindowMinutes
        self.elapsedWindowMinutes = elapsedWindowMinutes
        self.elapsedWindowSeconds = elapsedWindowSeconds
        self.weeklyUsedPercent = weeklyUsedPercent
        self.fiveHourUsedPercent = fiveHourUsedPercent
        self.fiveHourResetOffsetMinutes = fiveHourResetOffsetMinutes
        self.fiveHourResetOffsetSeconds = fiveHourResetOffsetSeconds
        self.samples = samples
    }

    public func makeScenario(
        referenceDate: Date = Self.referenceDate()
    ) throws -> DemoQuotaScenario {
        let weeklyWindowSeconds = weeklyWindowMinutes * 60
        let observedWindowSeconds = elapsedWindowSeconds ?? elapsedWindowMinutes * 60
        let fiveHourResetOffsetSeconds = fiveHourResetOffsetSeconds ?? fiveHourResetOffsetMinutes * 60

        guard weeklyWindowMinutes > 0,
              observedWindowSeconds > 0,
              observedWindowSeconds < weeklyWindowSeconds else {
            throw DemoQuotaDataError.invalidWindow
        }
        guard samples.isEmpty == false else {
            throw DemoQuotaDataError.noSamples
        }

        let now = referenceDate
        let windowStart = now.addingTimeInterval(-TimeInterval(observedWindowSeconds))
        let weeklyReset = windowStart.addingTimeInterval(TimeInterval(weeklyWindowSeconds))
        let fiveHourReset = now.addingTimeInterval(TimeInterval(fiveHourResetOffsetSeconds))
        let weeklyResetTimestamp = Int(weeklyReset.timeIntervalSince1970.rounded())
        let fiveHourResetTimestamp = Int(fiveHourReset.timeIntervalSince1970.rounded())

        var previousOffsetSeconds: Int?
        var quotaSamples: [QuotaSample] = []
        for point in samples {
            let pointOffsetSeconds = point.timeOffsetSeconds
            guard pointOffsetSeconds >= 0,
                  pointOffsetSeconds <= observedWindowSeconds else {
                throw DemoQuotaDataError.sampleOutsideObservedWindow(offsetMinutes: point.offsetMinutes)
            }
            if let previousOffsetSeconds,
               pointOffsetSeconds <= previousOffsetSeconds {
                throw DemoQuotaDataError.samplesNotIncreasing
            }
            previousOffsetSeconds = pointOffsetSeconds
            quotaSamples.append(makeSample(
                at: windowStart.addingTimeInterval(TimeInterval(pointOffsetSeconds)),
                weeklyUsedPercent: point.weeklyUsedPercent,
                weeklyReset: weeklyReset,
                fiveHourReset: fiveHourReset
            ))
        }

        if let last = samples.last,
           last.timeOffsetSeconds == observedWindowSeconds {
            guard abs(last.weeklyUsedPercent - weeklyUsedPercent) < 0.001 else {
                throw DemoQuotaDataError.finalSampleMismatch
            }
        } else {
            quotaSamples.append(makeSample(
                at: now,
                weeklyUsedPercent: weeklyUsedPercent,
                weeklyReset: weeklyReset,
                fiveHourReset: fiveHourReset
            ))
        }

        let snapshot = RateLimitSnapshot(
            limitId: limitId,
            limitName: limitName,
            primary: RateLimitWindow(
                usedPercent: fiveHourUsedPercent,
                windowDurationMins: 300,
                resetsAt: fiveHourResetTimestamp
            ),
            secondary: RateLimitWindow(
                usedPercent: weeklyUsedPercent,
                windowDurationMins: weeklyWindowMinutes,
                resetsAt: weeklyResetTimestamp
            ),
            credits: CreditsSnapshot(hasCredits: true, unlimited: false, balance: nil),
            planType: planType,
            rateLimitReachedType: nil
        )

        return DemoQuotaScenario(
            now: now,
            snapshot: snapshot,
            samples: quotaSamples,
            account: CodexAccountSnapshot(type: "chatgpt", email: nil, planType: planType)
        )
    }

    public static func referenceDate(
        containing date: Date = Date(),
        calendar inputCalendar: Calendar = .current
    ) -> Date {
        var calendar = inputCalendar
        calendar.locale = Locale(identifier: "en_US_POSIX")
        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = 12
        components.minute = 0
        components.second = 0
        components.nanosecond = 0
        return calendar.date(from: components) ?? date
    }

    private func makeSample(
        at capturedAt: Date,
        weeklyUsedPercent: Double,
        weeklyReset: Date,
        fiveHourReset: Date
    ) -> QuotaSample {
        QuotaSample(
            capturedAt: capturedAt,
            limitId: limitId,
            limitName: limitName,
            weeklyUsedPercent: weeklyUsedPercent,
            weeklyWindowMinutes: weeklyWindowMinutes,
            weeklyResetsAt: weeklyReset,
            fiveHourUsedPercent: fiveHourUsedPercent,
            fiveHourWindowMinutes: 300,
            fiveHourResetsAt: fiveHourReset,
            planType: planType,
            rateLimitReachedType: nil
        )
    }
}

public struct DemoQuotaSamplePoint: Decodable, Equatable, Sendable {
    public let offsetMinutes: Int
    public let offsetSeconds: Int?
    public let weeklyUsedPercent: Double

    public init(offsetMinutes: Int, offsetSeconds: Int? = nil, weeklyUsedPercent: Double) {
        self.offsetMinutes = offsetMinutes
        self.offsetSeconds = offsetSeconds
        self.weeklyUsedPercent = weeklyUsedPercent
    }

    var timeOffsetSeconds: Int {
        offsetSeconds ?? offsetMinutes * 60
    }
}

public enum DemoQuotaDataError: Error, Equatable, LocalizedError, Sendable {
    case invalidWindow
    case noSamples
    case sampleOutsideObservedWindow(offsetMinutes: Int)
    case samplesNotIncreasing
    case finalSampleMismatch

    public var errorDescription: String? {
        switch self {
        case .invalidWindow:
            "Demo quota data has an invalid weekly window."
        case .noSamples:
            "Demo quota data does not contain sample points."
        case let .sampleOutsideObservedWindow(offsetMinutes):
            "Demo quota sample at minute \(offsetMinutes) is outside the observed window."
        case .samplesNotIncreasing:
            "Demo quota sample offsets must be strictly increasing."
        case .finalSampleMismatch:
            "Demo quota final sample does not match the snapshot usage."
        }
    }
}
