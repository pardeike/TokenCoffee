import Foundation

public struct QuotaSample: Codable, Equatable, Sendable, Identifiable {
    public var id: String {
        "\(capturedAt.timeIntervalSince1970)-\(limitId)"
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
        self.capturedAt = capturedAt
        self.limitId = limitId
        self.limitName = limitName
        self.weeklyUsedPercent = weeklyUsedPercent
        self.weeklyWindowMinutes = weeklyWindowMinutes
        self.weeklyResetsAt = weeklyResetsAt
        self.fiveHourUsedPercent = fiveHourUsedPercent
        self.fiveHourWindowMinutes = fiveHourWindowMinutes
        self.fiveHourResetsAt = fiveHourResetsAt
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
        let directoryURL = baseURL.appendingPathComponent("TokenHelper", isDirectory: true)
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

    public func load(limit: Int = 2_000) throws -> [QuotaSample] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        let data = try Data(contentsOf: fileURL)
        let content = String(decoding: data, as: UTF8.self)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let lines = content.split(whereSeparator: \.isNewline).suffix(limit)
        return lines.compactMap { line in
            try? decoder.decode(QuotaSample.self, from: Data(line.utf8))
        }
    }
}

