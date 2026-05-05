import Foundation

public struct QuotaSample: Codable, Equatable, Sendable, Identifiable {
    public var id: String {
        syncIdentity
    }

    public var syncIdentity: String {
        "\(limitId)|\(Self.syncTimestamp(capturedAt))|\(Self.syncTimestamp(weeklyResetsAt))"
    }

    public var syncRecordName: String {
        "quota_\(Self.sanitizedIdentifier(limitId))_\(Self.syncTimestamp(capturedAt))_\(Self.syncTimestamp(weeklyResetsAt))"
    }

    public let capturedAt: Date
    public let limitId: String
    public let limitName: String?
    public let weeklyUsedPercent: Double
    public let weeklyWindowMinutes: Int?
    public let weeklyResetsAt: Date?
    public let fiveHourUsedPercent: Double?
    public let fiveHourWindowMinutes: Int?
    public let fiveHourResetsAt: Date?
    public let planType: String?
    public let rateLimitReachedType: String?

    public init(
        capturedAt: Date,
        limitId: String,
        limitName: String?,
        weeklyUsedPercent: Double,
        weeklyWindowMinutes: Int?,
        weeklyResetsAt: Date?,
        fiveHourUsedPercent: Double?,
        fiveHourWindowMinutes: Int?,
        fiveHourResetsAt: Date?,
        planType: String?,
        rateLimitReachedType: String?
    ) {
        self.capturedAt = Self.normalizedDate(capturedAt)
        self.limitId = limitId
        self.limitName = limitName
        self.weeklyUsedPercent = weeklyUsedPercent
        self.weeklyWindowMinutes = weeklyWindowMinutes
        self.weeklyResetsAt = weeklyResetsAt.map(Self.normalizedDate)
        self.fiveHourUsedPercent = fiveHourUsedPercent
        self.fiveHourWindowMinutes = fiveHourWindowMinutes
        self.fiveHourResetsAt = fiveHourResetsAt.map(Self.normalizedDate)
        self.planType = planType
        self.rateLimitReachedType = rateLimitReachedType
    }

    public init?(snapshot: RateLimitSnapshot, capturedAt: Date) {
        guard let weekly = snapshot.secondary else {
            return nil
        }

        self.init(
            capturedAt: capturedAt,
            limitId: snapshot.limitId ?? "codex",
            limitName: snapshot.limitName,
            weeklyUsedPercent: weekly.usedPercent,
            weeklyWindowMinutes: weekly.windowDurationMins,
            weeklyResetsAt: weekly.resetDate,
            fiveHourUsedPercent: snapshot.primary?.usedPercent,
            fiveHourWindowMinutes: snapshot.primary?.windowDurationMins,
            fiveHourResetsAt: snapshot.primary?.resetDate,
            planType: snapshot.planType,
            rateLimitReachedType: snapshot.rateLimitReachedType
        )
    }

    private static func syncTimestamp(_ date: Date?) -> Int64 {
        Int64((date?.timeIntervalSince1970 ?? 0).rounded())
    }

    private static func normalizedDate(_ date: Date) -> Date {
        Date(timeIntervalSince1970: TimeInterval(syncTimestamp(date)))
    }

    private static func sanitizedIdentifier(_ value: String) -> String {
        let characters = value.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "_"
        }
        return String(characters)
    }
}

public struct QuotaSampleRetentionPolicy: Equatable, Sendable {
    public static let standard = QuotaSampleRetentionPolicy(
        maximumSampleAge: 14 * 24 * 60 * 60,
        maximumSampleCount: 25_000
    )

    public let maximumSampleAge: TimeInterval?
    public let maximumSampleCount: Int

    public init(maximumSampleAge: TimeInterval?, maximumSampleCount: Int) {
        self.maximumSampleAge = maximumSampleAge
        self.maximumSampleCount = max(1, maximumSampleCount)
    }

    public static func countOnly(_ maximumSampleCount: Int) -> QuotaSampleRetentionPolicy {
        QuotaSampleRetentionPolicy(maximumSampleAge: nil, maximumSampleCount: maximumSampleCount)
    }
}

public struct QuotaSampleStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func defaultStore(fileManager: FileManager = .default) throws -> QuotaSampleStore {
        let baseURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directoryURL = baseURL.appendingPathComponent("TokenCoffee", isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return QuotaSampleStore(fileURL: directoryURL.appendingPathComponent("quota-samples.jsonl"))
    }

    public func append(_ sample: QuotaSample, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(atPath: fileURL.path, contents: nil)
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(sample)
        data.append(0x0A)

        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
    }

    public func load(
        policy: QuotaSampleRetentionPolicy = .standard,
        now: Date = Date()
    ) throws -> [QuotaSample] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        let data = try Data(contentsOf: fileURL)
        let content = String(decoding: data, as: UTF8.self)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let lines = content.split(whereSeparator: \.isNewline)
        let samples = lines.compactMap { line in
            try? decoder.decode(QuotaSample.self, from: Data(line.utf8))
        }
        return Self.mergedSamples(samples, policy: policy, now: now)
    }

    public func load(limit: Int) throws -> [QuotaSample] {
        try load(policy: .countOnly(limit))
    }

    @discardableResult
    public func merge(
        _ samples: [QuotaSample],
        policy: QuotaSampleRetentionPolicy = .standard,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> [QuotaSample] {
        let localSamples = (try? load(policy: .countOnly(policy.maximumSampleCount * 2), now: now)) ?? []
        let merged = Self.mergedSamples(localSamples + samples, policy: policy, now: now)
        try write(merged, fileManager: fileManager)
        return merged
    }

    @discardableResult
    public func merge(_ samples: [QuotaSample], limit: Int, fileManager: FileManager = .default) throws -> [QuotaSample] {
        try merge(samples, policy: .countOnly(limit), fileManager: fileManager)
    }

    public func write(_ samples: [QuotaSample], fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try samples.reduce(into: Data()) { partialResult, sample in
            partialResult.append(try encoder.encode(sample))
            partialResult.append(0x0A)
        }

        try data.write(to: fileURL, options: [.atomic])
    }

    public static func mergedSamples(
        _ samples: [QuotaSample],
        policy: QuotaSampleRetentionPolicy = .standard,
        now: Date = Date()
    ) -> [QuotaSample] {
        let cutoffDate = policy.maximumSampleAge.map { now.addingTimeInterval(-$0) }
        let retainedSamples = samples.filter { sample in
            guard let cutoffDate else {
                return true
            }
            return sample.capturedAt >= cutoffDate
        }
        let unique = Dictionary(retainedSamples.map { ($0.syncIdentity, $0) }, uniquingKeysWith: { current, replacement in
            replacement.capturedAt >= current.capturedAt ? replacement : current
        })
        let sorted = unique.values.sorted {
            if $0.capturedAt == $1.capturedAt {
                return $0.limitId < $1.limitId
            }
            return $0.capturedAt < $1.capturedAt
        }
        return Array(sorted.suffix(policy.maximumSampleCount))
    }

    public static func mergedSamples(_ samples: [QuotaSample], limit: Int) -> [QuotaSample] {
        mergedSamples(samples, policy: .countOnly(limit))
    }
}
