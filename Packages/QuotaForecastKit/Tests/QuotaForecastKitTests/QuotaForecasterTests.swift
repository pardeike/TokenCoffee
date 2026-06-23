import XCTest
@testable import QuotaForecastKit

final class QuotaForecasterTests: XCTestCase {
    func testPaths() throws {
        var configuration = QuotaForecastConfiguration()
        configuration.ensembleSize = 64
        configuration.randomSeed = 42
        let observed: [Double] = [0, 0, 1, 3, 3, 3, 4, 4, 8, 10, 10, 10, 12]
        let result = try QuotaForecaster(configuration: configuration)
            .forecast(observed: observed, totalCount: 36)
        XCTAssertEqual(result.optimistic.fullSeries.count, 36)
        XCTAssertEqual(Array(result.optimistic.fullSeries.prefix(observed.count)), observed)
        XCTAssertTrue(monotone(result.optimistic.fullSeries))
        XCTAssertTrue(monotone(result.pessimistic.fullSeries))
        for index in observed.count ..< 36 {
            XCTAssertGreaterThanOrEqual(result.pessimistic.fullSeries[index], result.optimistic.fullSeries[index])
        }
    }

    func testDeterminism() throws {
        var configuration = QuotaForecastConfiguration()
        configuration.ensembleSize = 48
        configuration.randomSeed = 123456
        let forecaster = QuotaForecaster(configuration: configuration)
        let observed: [Double] = [0, 1, 2, 2, 2, 5, 9, 9, 10, 10, 15]
        XCTAssertEqual(try forecaster.forecast(observed: observed, totalCount: 28),
                       try forecaster.forecast(observed: observed, totalCount: 28))
    }

    func testFlatAndRepairAndCap() throws {
        var configuration = QuotaForecastConfiguration()
        configuration.ensembleSize = 16
        let flat = try QuotaForecaster(configuration: configuration)
            .forecast(observed: [0, 0, 0], totalCount: 8)
        XCTAssertEqual(flat.optimistic.fullSeries, Array(repeating: 0, count: 8))
        XCTAssertEqual(flat.optimistic.futureValues, Array(repeating: 0, count: 5))

        let repaired = try QuotaForecaster(configuration: configuration)
            .forecast(observed: [0, 2, 1, 3], totalCount: 8)
        XCTAssertEqual(Array(repaired.optimistic.fullSeries.prefix(4)), [0, 2, 2, 3])
        XCTAssertTrue(repaired.diagnostics.inputWasRepaired)

        configuration.allowOverrun = false
        configuration.softQuota = 100
        let capped = try QuotaForecaster(configuration: configuration)
            .forecast(observed: [0, 20, 40, 60, 80, 95], totalCount: 18)
        XCTAssertLessThanOrEqual(capped.pessimistic.endpoint, 100)
    }

    private func monotone(_ values: [Double]) -> Bool {
        zip(values, values.dropFirst()).allSatisfy { $0 <= $1 }
    }
}
