import XCTest
@testable import TokenHelperCore

final class QuotaSampleStoreTests: XCTestCase {
    func testAppendsLoadsAndIgnoresCorruptLines() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("samples.jsonl")
        let store = QuotaSampleStore(fileURL: fileURL)
        let sample = QuotaSample(
            capturedAt: Date(timeIntervalSince1970: 123),
            limitId: "codex",
            limitName: nil,
            weeklyUsedPercent: 12,
            weeklyWindowMinutes: 10_080,
            weeklyResetsAt: Date(timeIntervalSince1970: 456),
            fiveHourUsedPercent: 4,
            fiveHourWindowMinutes: 300,
            fiveHourResetsAt: Date(timeIntervalSince1970: 200),
            planType: "pro",
            rateLimitReachedType: nil
        )

        try store.append(sample)
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not-json\n".utf8))
        try handle.close()

        let loaded = try store.load()

        XCTAssertEqual(loaded, [sample])
        try? FileManager.default.removeItem(at: directory)
    }
}

