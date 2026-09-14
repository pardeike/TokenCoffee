import Foundation
import OSLog

struct CloudQuotaSampleChangePage: Sendable {
    let records: [CloudQuotaSampleRemoteRecord]
    let deletedRecordNames: [String]
    let tokenData: Data
    let moreComing: Bool
}

enum CloudQuotaSampleChangeFetchError: LocalizedError, Equatable {
    case noProgress

    var errorDescription: String? {
        "CloudKit catch-up made no progress; retrying"
    }
}

enum CloudQuotaSampleChangeFetcher {
    struct Result: Sendable {
        let state: CloudQuotaSampleSyncState
        let records: [CloudQuotaSampleRemoteRecord]
    }

    // Fetch serially, as CloudKit's fetchAllChanges does. Bound a burst so a
    // large change history cannot monopolize the quota-refresh task. These
    // limits stop between requests; an in-flight request may take longer.
    static func fetch(
        state initialState: CloudQuotaSampleSyncState,
        pageLimit: Int = 100,
        timeBudget: Duration = .seconds(20),
        fetchPage: @Sendable (Data?) async throws -> CloudQuotaSampleChangePage
    ) async throws -> Result {
        var state = initialState
        var recordsByName: [String: CloudQuotaSampleRemoteRecord] = [:]
        let clock = ContinuousClock()
        let started = clock.now

        for pageIndex in 0..<max(1, pageLimit) {
            try Task.checkCancellation()
            let page = try await fetchPage(state.zoneChangeTokenData)
            try Task.checkCancellation()
            if page.moreComing, page.tokenData == state.zoneChangeTokenData {
                throw CloudQuotaSampleChangeFetchError.noProgress
            }
            for record in page.records {
                recordsByName[record.recordName] = record
                state.remoteSamplesByRecordName[record.recordName] = CloudQuotaSampleRemoteMetadata(
                    recordName: record.recordName,
                    sample: record.sample
                )
            }
            for name in page.deletedRecordNames {
                state.remoteSamplesByRecordName.removeValue(forKey: name)
                recordsByName.removeValue(forKey: name)
            }
            state.zoneChangeTokenData = page.tokenData
            state.isCaughtUp = !page.moreComing
            cloudSyncLogger.info(
                "Cloud quota catch-up page fetched; page=\(pageIndex + 1, privacy: .public) modifications=\(page.records.count, privacy: .public) deletions=\(page.deletedRecordNames.count, privacy: .public) moreComing=\(page.moreComing, privacy: .public)"
            )
            if !page.moreComing || started.duration(to: clock.now) >= timeBudget {
                break
            }
        }
        // Only hand the cursor back with all of the samples it covers. If any
        // page fails, the caller retains its previous committed checkpoint.
        return Result(state: state, records: Array(recordsByName.values))
    }
}
