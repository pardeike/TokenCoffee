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
    public let weeklyUsedPercent: Double
    public let fiveHourUsedPercent: Double
    public let fiveHourResetOffsetMinutes: Int
    public let samples: [DemoQuotaSamplePoint]

    public init(
        limitId: String,
        limitName: String?,
        planType: String?,
        weeklyWindowMinutes: Int,
        elapsedWindowMinutes: Int,
        weeklyUsedPercent: Double,
        fiveHourUsedPercent: Double,
        fiveHourResetOffsetMinutes: Int,
        samples: [DemoQuotaSamplePoint]
    ) {
        self.limitId = limitId
        self.limitName = limitName
        self.planType = planType
        self.weeklyWindowMinutes = weeklyWindowMinutes
        self.elapsedWindowMinutes = elapsedWindowMinutes
        self.weeklyUsedPercent = weeklyUsedPercent
        self.fiveHourUsedPercent = fiveHourUsedPercent
        self.fiveHourResetOffsetMinutes = fiveHourResetOffsetMinutes
        self.samples = samples
    }

    public func makeScenario(
        referenceDate: Date = Self.referenceDate()
    ) throws -> DemoQuotaScenario {
        guard weeklyWindowMinutes > 0,
              elapsedWindowMinutes > 0,
              elapsedWindowMinutes < weeklyWindowMinutes else {
            throw DemoQuotaDataError.invalidWindow
        }
        guard samples.isEmpty == false else {
            throw DemoQuotaDataError.noSamples
        }

        let now = referenceDate
        let windowStart = now.addingTimeInterval(-TimeInterval(elapsedWindowMinutes * 60))
        let weeklyReset = windowStart.addingTimeInterval(TimeInterval(weeklyWindowMinutes * 60))
        let fiveHourReset = now.addingTimeInterval(TimeInterval(fiveHourResetOffsetMinutes * 60))
        let weeklyResetTimestamp = Int(weeklyReset.timeIntervalSince1970.rounded())
        let fiveHourResetTimestamp = Int(fiveHourReset.timeIntervalSince1970.rounded())

        var previousOffset: Int?
        var quotaSamples: [QuotaSample] = []
        for point in samples {
            guard point.offsetMinutes >= 0,
                  point.offsetMinutes <= elapsedWindowMinutes else {
                throw DemoQuotaDataError.sampleOutsideObservedWindow(offsetMinutes: point.offsetMinutes)
            }
            if let previousOffset,
               point.offsetMinutes <= previousOffset {
                throw DemoQuotaDataError.samplesNotIncreasing
            }
            previousOffset = point.offsetMinutes
            quotaSamples.append(makeSample(
                at: windowStart.addingTimeInterval(TimeInterval(point.offsetMinutes * 60)),
                weeklyUsedPercent: point.weeklyUsedPercent,
                weeklyReset: weeklyReset,
                fiveHourReset: fiveHourReset
            ))
        }

        if let last = samples.last,
           last.offsetMinutes == elapsedWindowMinutes {
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
    public let weeklyUsedPercent: Double

    public init(offsetMinutes: Int, weeklyUsedPercent: Double) {
        self.offsetMinutes = offsetMinutes
        self.weeklyUsedPercent = weeklyUsedPercent
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
