import CloudKit
import Foundation
import Security
import TokenCoffeeCore

struct QuotaSampleSyncOutcome: Sendable {
    let samples: [QuotaSample]
    let status: QuotaSyncStatus
}

struct CloudQuotaSampleSyncService: Sendable {
    private let retentionPolicy: QuotaSampleRetentionPolicy

    init(retentionPolicy: QuotaSampleRetentionPolicy = .standard) {
        self.retentionPolicy = retentionPolicy
    }

    var isConfigured: Bool {
        Self.hasCloudKitEntitlement()
    }

    func sync(localSamples: [QuotaSample]) async -> QuotaSampleSyncOutcome {
        let now = Date()
        let normalizedLocalSamples = QuotaSampleStore.mergedSamples(localSamples, policy: retentionPolicy, now: now)
        guard isConfigured else {
            return QuotaSampleSyncOutcome(samples: normalizedLocalSamples, status: .localOnly)
        }

        do {
            let container = CKContainer.default()
            let accountStatus = try await fetchAccountStatus(container: container)
            guard accountStatus == .available else {
                return QuotaSampleSyncOutcome(
                    samples: normalizedLocalSamples,
                    status: .unavailable(accountStatus.quotaSyncDescription)
                )
            }

            let database = container.privateCloudDatabase
            let remoteRecords = try await fetchRemoteRecords(database: database)
            let remoteSamples = remoteRecords.compactMap(\.sample)
            let mergedSamples = QuotaSampleStore.mergedSamples(
                normalizedLocalSamples + remoteSamples,
                policy: retentionPolicy,
                now: now
            )
            let retainedRecordNames = Set(mergedSamples.map(\.syncRecordName))
            let remoteRecordNames = Set(remoteRecords.compactMap { $0.sample?.syncRecordName })
            let samplesToUpload = mergedSamples.filter { remoteRecordNames.contains($0.syncRecordName) == false }
            let recordIDsToDelete = remoteRecords.compactMap { remoteRecord -> CKRecord.ID? in
                retainedRecordNames.contains(remoteRecord.recordName) ? nil : remoteRecord.recordID
            }
            try await applyChanges(saving: samplesToUpload, deleting: recordIDsToDelete, to: database)

            return QuotaSampleSyncOutcome(samples: mergedSamples, status: .synced(now))
        } catch {
            return QuotaSampleSyncOutcome(samples: normalizedLocalSamples, status: .failed(error.quotaSyncDescription))
        }
    }

    private func fetchAccountStatus(container: CKContainer) async throws -> CKAccountStatus {
        try await withCheckedThrowingContinuation { continuation in
            container.accountStatus { accountStatus, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: accountStatus)
                }
            }
        }
    }

    private func fetchRemoteRecords(database: CKDatabase) async throws -> [CloudQuotaSampleRemoteRecord] {
        let query = CKQuery(recordType: CloudQuotaSampleRecord.recordType, predicate: NSPredicate(value: true))

        var cursor: CKQueryOperation.Cursor?
        var records: [CloudQuotaSampleRemoteRecord] = []
        repeat {
            let response: (
                matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)],
                queryCursor: CKQueryOperation.Cursor?
            )
            if let cursor {
                response = try await database.records(
                    continuingMatchFrom: cursor,
                    desiredKeys: CloudQuotaSampleRecord.desiredKeys,
                    resultsLimit: 400
                )
            } else {
                response = try await database.records(
                    matching: query,
                    desiredKeys: CloudQuotaSampleRecord.desiredKeys,
                    resultsLimit: 400
                )
            }

            for (recordID, result) in response.matchResults {
                let record = try result.get()
                records.append(CloudQuotaSampleRemoteRecord(recordID: recordID, sample: CloudQuotaSampleRecord.sample(from: record)))
            }
            cursor = response.queryCursor
        } while cursor != nil

        return records
    }

    private func applyChanges(
        saving samples: [QuotaSample],
        deleting recordIDs: [CKRecord.ID],
        to database: CKDatabase
    ) async throws {
        let records = samples.map(CloudQuotaSampleRecord.record(from:))
        try await modify(records: records, deleting: [], in: database)
        try await modify(records: [], deleting: recordIDs, in: database)
    }

    private func modify(records: [CKRecord], deleting recordIDs: [CKRecord.ID], in database: CKDatabase) async throws {
        guard records.isEmpty == false || recordIDs.isEmpty == false else {
            return
        }

        let batchSize = 200
        var recordStartIndex = 0
        while recordStartIndex < records.count {
            let endIndex = min(recordStartIndex + batchSize, records.count)
            let response = try await database.modifyRecords(
                saving: Array(records[recordStartIndex..<endIndex]),
                deleting: [],
                savePolicy: .changedKeys,
                atomically: false
            )
            for result in response.saveResults.values {
                _ = try result.get()
            }
            recordStartIndex = endIndex
        }

        var deleteStartIndex = 0
        while deleteStartIndex < recordIDs.count {
            let endIndex = min(deleteStartIndex + batchSize, recordIDs.count)
            let response = try await database.modifyRecords(
                saving: [],
                deleting: Array(recordIDs[deleteStartIndex..<endIndex]),
                savePolicy: .changedKeys,
                atomically: false
            )
            for result in response.deleteResults.values {
                _ = try result.get()
            }
            deleteStartIndex = endIndex
        }
    }

    private static func hasCloudKitEntitlement() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let services = SecTaskCopyValueForEntitlement(
                task,
                "com.apple.developer.icloud-services" as CFString,
                nil
              ) as? [String] else {
            return false
        }
        return services.contains("CloudKit")
    }
}

private struct CloudQuotaSampleRemoteRecord: Sendable {
    let recordID: CKRecord.ID
    let sample: QuotaSample?

    var recordName: String {
        recordID.recordName
    }
}

private enum CloudQuotaSampleRecord {
    static let recordType = "QuotaSample"
    static let desiredKeys: [CKRecord.FieldKey] = [
        Field.capturedAt,
        Field.limitId,
        Field.limitName,
        Field.weeklyUsedPercent,
        Field.weeklyWindowMinutes,
        Field.weeklyResetsAt,
        Field.fiveHourUsedPercent,
        Field.fiveHourWindowMinutes,
        Field.fiveHourResetsAt,
        Field.planType,
        Field.rateLimitReachedType
    ]

    enum Field {
        static let capturedAt = "capturedAt"
        static let limitId = "limitId"
        static let limitName = "limitName"
        static let weeklyUsedPercent = "weeklyUsedPercent"
        static let weeklyWindowMinutes = "weeklyWindowMinutes"
        static let weeklyResetsAt = "weeklyResetsAt"
        static let fiveHourUsedPercent = "fiveHourUsedPercent"
        static let fiveHourWindowMinutes = "fiveHourWindowMinutes"
        static let fiveHourResetsAt = "fiveHourResetsAt"
        static let planType = "planType"
        static let rateLimitReachedType = "rateLimitReachedType"
    }

    static func record(from sample: QuotaSample) -> CKRecord {
        let recordID = CKRecord.ID(recordName: sample.syncRecordName)
        let record = CKRecord(recordType: recordType, recordID: recordID)
        record[Field.capturedAt] = sample.capturedAt
        record[Field.limitId] = sample.limitId
        record[Field.limitName] = sample.limitName
        record[Field.weeklyUsedPercent] = sample.weeklyUsedPercent
        record[Field.weeklyWindowMinutes] = sample.weeklyWindowMinutes
        record[Field.weeklyResetsAt] = sample.weeklyResetsAt
        record[Field.fiveHourUsedPercent] = sample.fiveHourUsedPercent
        record[Field.fiveHourWindowMinutes] = sample.fiveHourWindowMinutes
        record[Field.fiveHourResetsAt] = sample.fiveHourResetsAt
        record[Field.planType] = sample.planType
        record[Field.rateLimitReachedType] = sample.rateLimitReachedType
        return record
    }

    static func sample(from record: CKRecord) -> QuotaSample? {
        let capturedAt: Date? = record[Field.capturedAt]
        let limitId: String? = record[Field.limitId]
        let weeklyUsedPercent: Double? = record[Field.weeklyUsedPercent]
        guard let capturedAt,
              let limitId,
              let weeklyUsedPercent else {
            return nil
        }

        return QuotaSample(
            capturedAt: capturedAt,
            limitId: limitId,
            limitName: record[Field.limitName],
            weeklyUsedPercent: weeklyUsedPercent,
            weeklyWindowMinutes: record[Field.weeklyWindowMinutes],
            weeklyResetsAt: record[Field.weeklyResetsAt],
            fiveHourUsedPercent: record[Field.fiveHourUsedPercent],
            fiveHourWindowMinutes: record[Field.fiveHourWindowMinutes],
            fiveHourResetsAt: record[Field.fiveHourResetsAt],
            planType: record[Field.planType],
            rateLimitReachedType: record[Field.rateLimitReachedType]
        )
    }
}

private extension CKAccountStatus {
    var quotaSyncDescription: String {
        switch self {
        case .available:
            "available"
        case .couldNotDetermine:
            "iCloud unavailable"
        case .noAccount:
            "no iCloud account"
        case .restricted:
            "iCloud restricted"
        case .temporarilyUnavailable:
            "iCloud temporarily unavailable"
        @unknown default:
            "iCloud unavailable"
        }
    }
}

private extension Error {
    var quotaSyncDescription: String {
        let nsError = self as NSError
        if nsError.domain == CKError.errorDomain,
           let ckError = CKError.Code(rawValue: nsError.code) {
            switch ckError {
            case .notAuthenticated:
                return "not signed in to iCloud"
            case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited:
                return "CloudKit temporarily unavailable"
            case .permissionFailure:
                return "CloudKit permission denied"
            default:
                break
            }
        }
        return localizedDescription
    }
}
