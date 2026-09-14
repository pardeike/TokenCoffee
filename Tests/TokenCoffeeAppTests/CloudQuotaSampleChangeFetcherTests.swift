import CloudKit
import XCTest
@testable import Token_Coffee
@testable import TokenCoffeeCore

@MainActor
final class CloudQuotaSampleChangeFetcherTests: XCTestCase {
    func testCatchUpFollowsFortyPagesWithoutIntervalWaits() async throws {
        let pages = (1...40).map { index in
            page(index, moreComing: index < 40, samples: [sample(index)])
        }
        let source = PageSource(pages: pages)

        let result = try await CloudQuotaSampleChangeFetcher.fetch(state: .empty) {
            try await source.fetch($0)
        }

        XCTAssertTrue(result.state.isCaughtUp)
        XCTAssertEqual(result.records.count, 40)
        XCTAssertEqual(result.state.remoteSamplesByRecordName.count, 40)
        let tokens = await source.requestedTokens
        XCTAssertEqual(tokens, [nil] + (1..<40).map { token($0) })
    }

    func testDeletionOnlyAndEmptyPagesContinueUntilEnd() async throws {
        let old = sample(1)
        var state = CloudQuotaSampleSyncState.empty
        state.remoteSamplesByRecordName[old.syncRecordName] = CloudQuotaSampleRemoteMetadata(
            recordName: old.syncRecordName, sample: old
        )
        let source = PageSource(pages: [
            page(1, moreComing: true, deletions: [old.syncRecordName]),
            page(2, moreComing: true),
            page(3, moreComing: false, samples: [sample(3)])
        ])

        let result = try await CloudQuotaSampleChangeFetcher.fetch(state: state) {
            try await source.fetch($0)
        }

        XCTAssertTrue(result.state.isCaughtUp)
        XCTAssertNil(result.state.remoteSamplesByRecordName[old.syncRecordName])
        XCTAssertEqual(result.records.compactMap(\.sample), [sample(3)])
    }

    func testLaterDeletionDoesNotResurrectSampleFromEarlierPage() async throws {
        let removed = sample(1)
        let source = PageSource(pages: [
            page(1, moreComing: true, samples: [removed]),
            page(2, moreComing: false, deletions: [removed.syncRecordName])
        ])

        let result = try await CloudQuotaSampleChangeFetcher.fetch(state: .empty) {
            try await source.fetch($0)
        }

        XCTAssertTrue(result.records.isEmpty)
        XCTAssertTrue(result.state.remoteSamplesByRecordName.isEmpty)
    }

    func testPageBudgetReturnsCheckpointAndNextBurstResumesImmediately() async throws {
        let source = PageSource(pages: [
            page(1, moreComing: true), page(2, moreComing: true), page(3, moreComing: false)
        ])
        var first = try await CloudQuotaSampleChangeFetcher.fetch(state: .empty, pageLimit: 2) {
            try await source.fetch($0)
        }.state
        first.lastSuccessfulSyncAt = Date()
        XCTAssertFalse(first.isCaughtUp)
        XCTAssertTrue(CloudQuotaSampleSyncPolicy.shouldRunSync(state: first, now: first.lastSuccessfulSyncAt!))

        let second = try await CloudQuotaSampleChangeFetcher.fetch(state: first) {
            try await source.fetch($0)
        }

        XCTAssertTrue(second.state.isCaughtUp)
        let tokens = await source.requestedTokens
        XCTAssertEqual(tokens, [nil, token(1), token(2)])
    }

    func testTimeBudgetYieldsAfterCompletedPage() async throws {
        let source = PageSource(pages: [page(1, moreComing: true), page(2, moreComing: false)])

        let result = try await CloudQuotaSampleChangeFetcher.fetch(state: .empty, timeBudget: .zero) {
            try await source.fetch($0)
        }

        XCTAssertFalse(result.state.isCaughtUp)
        XCTAssertEqual(result.state.zoneChangeTokenData, token(1))
        let count = await source.requestedTokens.count
        XCTAssertEqual(count, 1)
    }

    func testRateLimitOnLaterPageLeavesCommittedCursorAndHistoryTogether() async throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        var initial = CloudQuotaSampleSyncState.empty
        initial.zoneChangeTokenData = token(1)
        initial.cachedSamples = [sample(1)]
        try store.save(initial)
        let error = NSError(domain: CKError.errorDomain, code: CKError.Code.requestRateLimited.rawValue,
                            userInfo: [CKErrorRetryAfterKey: 42])
        let source = PageSource(pages: [page(2, moreComing: true, samples: [sample(2)])], error: error)

        do {
            _ = try await CloudQuotaSampleChangeFetcher.fetch(state: store.load()) {
                try await source.fetch($0)
            }
            XCTFail("Expected the second page to be rate limited")
        } catch {
            var retryState = store.load()
            let failedAt = Date()
            CloudQuotaSampleSyncPolicy.apply(error: error, now: failedAt, to: &retryState)
            try store.save(retryState)
            XCTAssertEqual(retryState.zoneChangeTokenData, token(1))
            XCTAssertEqual(retryState.cachedSamples, [sample(1)])
            XCTAssertFalse(CloudQuotaSampleSyncPolicy.shouldRunSync(state: retryState, now: failedAt))
            XCTAssertTrue(CloudQuotaSampleSyncPolicy.shouldRunSync(
                state: retryState, now: failedAt.addingTimeInterval(42)
            ))
        }
        let tokens = await source.requestedTokens
        XCTAssertEqual(tokens, [token(1), token(2)])
    }

    func testNonAdvancingCursorStopsAndBacksOff() async throws {
        var state = CloudQuotaSampleSyncState.empty
        state.zoneChangeTokenData = token(1)
        let source = PageSource(pages: [page(1, moreComing: true)])

        do {
            _ = try await CloudQuotaSampleChangeFetcher.fetch(state: state) {
                try await source.fetch($0)
            }
            XCTFail("Expected no-progress error")
        } catch {
            XCTAssertEqual(error as? CloudQuotaSampleChangeFetchError, .noProgress)
            let now = Date()
            CloudQuotaSampleSyncPolicy.apply(error: error, now: now, to: &state)
            XCTAssertEqual(state.nextAllowedSyncAt, now.addingTimeInterval(300))
            XCTAssertEqual(CloudQuotaSampleSyncPolicy.status(for: state, now: now),
                           .failed("CloudKit catch-up made no progress; retrying"))
        }
        let count = await source.requestedTokens.count
        XCTAssertEqual(count, 1)
    }

    func testCaughtUpClientAlsoDrainsMultiplePages() async throws {
        var state = CloudQuotaSampleSyncState.empty
        state.isCaughtUp = true
        let source = PageSource(pages: [page(1, moreComing: true), page(2, moreComing: false)])

        let result = try await CloudQuotaSampleChangeFetcher.fetch(state: state) {
            try await source.fetch($0)
        }

        XCTAssertTrue(result.state.isCaughtUp)
        let count = await source.requestedTokens.count
        XCTAssertEqual(count, 2)
    }

    func testCancelledCatchUpDoesNotRequestAnotherPage() async throws {
        let source = PageSource(pages: [page(1, moreComing: false)])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await CloudQuotaSampleChangeFetcher.fetch(state: .empty) {
                try await source.fetch($0)
            }
        }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let count = await source.requestedTokens.count
        XCTAssertEqual(count, 0)
    }

    func testStateCheckpointSurvivesMissingJSONLWriteAndOldFilesStillDecode() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        var state = CloudQuotaSampleSyncState.empty
        state.zoneChangeTokenData = token(8)
        state.cachedSamples = [sample(8)]
        try store.save(state)
        // No separate quota-samples.jsonl write: both halves are in this file.
        XCTAssertEqual(store.load(), state)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
        json.removeValue(forKey: "cachedSamples")
        try JSONSerialization.data(withJSONObject: json).write(to: store.fileURL)
        let migrated = store.load()
        XCTAssertEqual(migrated.zoneChangeTokenData, token(8))
        XCTAssertNil(migrated.cachedSamples)
    }

    private func token(_ index: Int) -> Data { Data(String(index).utf8) }

    private func sample(_ index: Int) -> QuotaSample {
        QuotaSample(capturedAt: Date(timeIntervalSince1970: TimeInterval(index * 60)),
                    limitId: "codex", limitName: nil, weeklyUsedPercent: 12, weeklyWindowMinutes: 10_080,
                    weeklyResetsAt: Date(timeIntervalSince1970: 604_800), fiveHourUsedPercent: nil,
                    fiveHourWindowMinutes: nil, fiveHourResetsAt: nil, planType: "pro", rateLimitReachedType: nil)
    }

    private func page(_ index: Int, moreComing: Bool, samples: [QuotaSample] = [],
                      deletions: [String] = []) -> CloudQuotaSampleChangePage {
        CloudQuotaSampleChangePage(records: samples.map {
            CloudQuotaSampleRemoteRecord(recordID: CKRecord.ID(recordName: $0.syncRecordName), sample: $0)
        }, deletedRecordNames: deletions, tokenData: token(index), moreComing: moreComing)
    }

    private func temporaryStore() -> CloudQuotaSampleSyncStateStore {
        CloudQuotaSampleSyncStateStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("sync-state.json"))
    }
}

private actor PageSource {
    private var pages: [CloudQuotaSampleChangePage]
    private let error: NSError?
    private(set) var requestedTokens: [Data?] = []

    init(pages: [CloudQuotaSampleChangePage], error: NSError? = nil) {
        self.pages = pages
        self.error = error
    }

    func fetch(_ token: Data?) throws -> CloudQuotaSampleChangePage {
        requestedTokens.append(token)
        guard !pages.isEmpty else {
            throw error ?? NSError(domain: "UnexpectedPageRequest", code: 1)
        }
        return pages.removeFirst()
    }
}
