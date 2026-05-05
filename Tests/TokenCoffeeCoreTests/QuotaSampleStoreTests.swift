import XCTest
@testable import TokenCoffeeCore

final class QuotaSampleStoreTests: XCTestCase {
    func testAppendsLoadsAndIgnoresCorruptLines() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("samples.jsonl")
        let store = QuotaSampleStore(fileURL: fileURL)
        let sample = makeSample(capturedAt: 123, usedPercent: 12)

        try store.append(sample)
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not-json\n".utf8))
        try handle.close()

        let loaded = try store.load(policy: .countOnly(2_000))

        XCTAssertEqual(loaded, [sample])
        try? FileManager.default.removeItem(at: directory)
    }

    func testSyncIdentityAndRecordNameAreStableAcrossSubsecondDates() {
        let first = makeSample(capturedAt: 123.1, limitId: "codex/pro", resetAt: 456.2)
        let second = makeSample(capturedAt: 123.4, limitId: "codex/pro", resetAt: 456.4)

        XCTAssertEqual(first.syncIdentity, second.syncIdentity)
        XCTAssertEqual(first.syncRecordName, "quota_codex_pro_123_456")
    }

    func testMergeDedupeSortsAndRewritesStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("samples.jsonl")
        let store = QuotaSampleStore(fileURL: fileURL)
        let newest = makeSample(capturedAt: 300, usedPercent: 30)
        let duplicate = makeSample(capturedAt: 200.1, usedPercent: 20)
        let duplicateReplacement = makeSample(capturedAt: 200.4, usedPercent: 21)
        let oldest = makeSample(capturedAt: 100, usedPercent: 10)

        try store.append(duplicate)
        let merged = try store.merge([newest, duplicateReplacement, oldest], policy: .countOnly(2_000))
        let reloaded = try store.load(policy: .countOnly(2_000))

        XCTAssertEqual(merged, [oldest, duplicateReplacement, newest])
        XCTAssertEqual(reloaded, merged)
        XCTAssertFalse(String(decoding: try Data(contentsOf: fileURL), as: UTF8.self).contains("\"weeklyUsedPercent\":20"))
        try? FileManager.default.removeItem(at: directory)
    }

    func testMergeAppliesAgeRetentionAndHardCap() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("samples.jsonl")
        let store = QuotaSampleStore(fileURL: fileURL)
        let policy = QuotaSampleRetentionPolicy(maximumSampleAge: 120, maximumSampleCount: 2)
        let now = Date(timeIntervalSince1970: 1_000)

        let tooOld = makeSample(capturedAt: 800, usedPercent: 1)
        let olderRetained = makeSample(capturedAt: 900, usedPercent: 2)
        let firstRetained = makeSample(capturedAt: 940, usedPercent: 3)
        let secondRetained = makeSample(capturedAt: 980, usedPercent: 4)

        let merged = try store.merge(
            [tooOld, olderRetained, firstRetained, secondRetained],
            policy: policy,
            now: now
        )

        XCTAssertEqual(merged, [firstRetained, secondRetained])
        XCTAssertEqual(try store.load(policy: .countOnly(10)), [firstRetained, secondRetained])
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeSample(
        capturedAt: TimeInterval,
        limitId: String = "codex",
        resetAt: TimeInterval = 456,
        usedPercent: Double = 12
    ) -> QuotaSample {
        QuotaSample(
            capturedAt: Date(timeIntervalSince1970: capturedAt),
            limitId: limitId,
            limitName: nil,
            weeklyUsedPercent: usedPercent,
            weeklyWindowMinutes: 10_080,
            weeklyResetsAt: Date(timeIntervalSince1970: resetAt),
            fiveHourUsedPercent: 4,
            fiveHourWindowMinutes: 300,
            fiveHourResetsAt: Date(timeIntervalSince1970: 200),
            planType: "pro",
            rateLimitReachedType: nil
        )
    }
}
