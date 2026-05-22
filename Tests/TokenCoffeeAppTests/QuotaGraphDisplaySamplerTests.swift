import XCTest
@testable import Token_Coffee
@testable import TokenCoffeeCore

final class QuotaGraphDisplaySamplerTests: XCTestCase {
    func testSamplerLeavesShortSeriesUnchanged() {
        let samples = makeSamples(count: 3)

        let displaySamples = QuotaGraphDisplaySampler.displaySamples(
            from: samples,
            maximumPointCount: 4
        )

        XCTAssertEqual(displaySamples, samples)
    }

    func testSamplerCapsLargeSeriesAndPreservesEdges() {
        let samples = makeSamples(count: 10)

        let displaySamples = QuotaGraphDisplaySampler.displaySamples(
            from: samples,
            maximumPointCount: 4
        )

        XCTAssertEqual(displaySamples.count, 4)
        XCTAssertEqual(displaySamples.first, samples.first)
        XCTAssertEqual(displaySamples.last, samples.last)
        XCTAssertEqual(displaySamples.map(\.capturedAt), displaySamples.map(\.capturedAt).sorted())
    }

    func testSamplerKeepsMostRecentPointWhenOnlyOnePointIsAllowed() {
        let samples = makeSamples(count: 5)

        let displaySamples = QuotaGraphDisplaySampler.displaySamples(
            from: samples,
            maximumPointCount: 1
        )

        XCTAssertEqual(displaySamples, [samples[4]])
    }

    private func makeSamples(count: Int) -> [QuotaSample] {
        (0..<count).map { index in
            QuotaSample(
                capturedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                limitId: "codex",
                limitName: nil,
                weeklyUsedPercent: Double(index),
                weeklyWindowMinutes: 10_080,
                weeklyResetsAt: Date(timeIntervalSince1970: 10_080),
                fiveHourUsedPercent: 4,
                fiveHourWindowMinutes: 300,
                fiveHourResetsAt: Date(timeIntervalSince1970: 300),
                planType: "pro",
                rateLimitReachedType: nil
            )
        }
    }
}
