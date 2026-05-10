import XCTest
@testable import TokenCoffeeCore

final class QuotaForecastDiagnosticExporterTests: XCTestCase {
    func testBundledDemoDiagnosticsExposeExactPackageInputAndDefaults() throws {
        let data = try Data(contentsOf: Self.demoQuotaDataURL)
        let fixture = try JSONDecoder().decode(DemoQuotaData.self, from: data)
        let scenario = try fixture.makeScenario(referenceDate: Date(timeIntervalSince1970: 2_000_000_000))

        let diagnosticsData = try QuotaForecastDiagnosticExporter.makeDiagnosticsData(
            snapshot: scenario.snapshot,
            samples: scenario.samples,
            now: scenario.now,
            generatedAt: scenario.now,
            syncStatusDescription: "localOnly"
        )
        let root = try decodedDictionary(from: diagnosticsData)
        let samplesSummary = try dictionary(root["samples"])
        let packageParameters = try dictionary(root["packageParameters"])
        let packageInput = try dictionary(root["packageInput"])
        let packageSamples = try array(packageInput["samples"])
        let packageResult = try dictionary(root["packageResult"])
        let optimistic = try dictionary(packageResult["optimistic"])
        let pessimistic = try dictionary(packageResult["pessimistic"])

        XCTAssertEqual(int(samplesSummary["storedSampleCount"]), fixture.samples.count)
        XCTAssertEqual(int(samplesSummary["currentWindowSampleCount"]), fixture.samples.count)
        XCTAssertEqual(int(samplesSummary["inputSampleCount"]), fixture.samples.count)
        XCTAssertEqual(packageSamples.count, fixture.samples.count)
        XCTAssertEqual(bool(packageParameters["capForecastAt100Percent"]), false)
        XCTAssertEqual(double(optimistic["finalUsedPercent"]), 103.752, accuracy: 0.001)
        XCTAssertEqual(double(pessimistic["finalUsedPercent"]), 147.377, accuracy: 0.001)
        XCTAssertEqual(double(samplesSummary["firstInputOffsetSeconds"]), Double(fixture.samples[0].timeOffsetSeconds), accuracy: 0.001)
        XCTAssertEqual(double(samplesSummary["lastInputOffsetSeconds"]), Double(fixture.samples.last?.timeOffsetSeconds ?? 0), accuracy: 0.001)
    }

    func testDiagnosticsFiltersPackageInputToCurrentLimitResetAndNow() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let reset = start.addingTimeInterval(7 * 24 * 60 * 60)
        let now = start.addingTimeInterval(3 * 60 * 60)
        let snapshot = snapshot(usedPercent: 10, reset: reset)
        let samples = [
            sample(at: start.addingTimeInterval(60 * 60), usedPercent: 0, reset: reset, limitId: "codex"),
            sample(at: start.addingTimeInterval(90 * 60), usedPercent: 50, reset: reset, limitId: "other"),
            sample(at: start.addingTimeInterval(2 * 60 * 60), usedPercent: 2, reset: reset.addingTimeInterval(60), limitId: "codex"),
            sample(at: start.addingTimeInterval(2 * 60 * 60), usedPercent: 5, reset: reset, limitId: "codex"),
            sample(at: now.addingTimeInterval(60), usedPercent: 9, reset: reset, limitId: "codex")
        ]

        let diagnosticsData = try QuotaForecastDiagnosticExporter.makeDiagnosticsData(
            snapshot: snapshot,
            samples: samples,
            now: now,
            generatedAt: now
        )
        let root = try decodedDictionary(from: diagnosticsData)
        let samplesSummary = try dictionary(root["samples"])
        let packageInput = try dictionary(root["packageInput"])
        let packageSamples = try array(packageInput["samples"])

        XCTAssertEqual(int(samplesSummary["storedSampleCount"]), 5)
        XCTAssertEqual(int(samplesSummary["currentWindowSampleCount"]), 2)
        XCTAssertEqual(int(samplesSummary["inputSampleCount"]), 3)
        XCTAssertEqual(packageSamples.count, 3)
        XCTAssertEqual(double(try dictionary(packageSamples[0])["offsetSeconds"]), 60 * 60, accuracy: 0.001)
        XCTAssertEqual(double(try dictionary(packageSamples[1])["offsetSeconds"]), 2 * 60 * 60, accuracy: 0.001)
        XCTAssertEqual(double(try dictionary(packageSamples[2])["offsetSeconds"]), 3 * 60 * 60, accuracy: 0.001)
        XCTAssertEqual(double(try dictionary(packageSamples[2])["weeklyUsedPercent"]), 10, accuracy: 0.001)
    }

    private static var demoQuotaDataURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TokenCoffeeApp/Resources/DemoQuotaData.json")
    }

    private func snapshot(usedPercent: Double, reset: Date) -> RateLimitSnapshot {
        RateLimitSnapshot(
            limitId: "codex",
            limitName: "Codex",
            primary: RateLimitWindow(usedPercent: 5, windowDurationMins: 300, resetsAt: Int(reset.timeIntervalSince1970) - 3_600),
            secondary: RateLimitWindow(usedPercent: usedPercent, windowDurationMins: 10_080, resetsAt: Int(reset.timeIntervalSince1970)),
            credits: nil,
            planType: "pro",
            rateLimitReachedType: nil
        )
    }

    private func sample(at date: Date, usedPercent: Double, reset: Date, limitId: String) -> QuotaSample {
        QuotaSample(
            capturedAt: date,
            limitId: limitId,
            limitName: limitId == "codex" ? "Codex" : "Other",
            weeklyUsedPercent: usedPercent,
            weeklyWindowMinutes: 10_080,
            weeklyResetsAt: reset,
            fiveHourUsedPercent: 5,
            fiveHourWindowMinutes: 300,
            fiveHourResetsAt: date.addingTimeInterval(60 * 60),
            planType: "pro",
            rateLimitReachedType: nil
        )
    }

    private func decodedDictionary(from data: Data) throws -> [String: Any] {
        try dictionary(JSONSerialization.jsonObject(with: data))
    }

    private func dictionary(
        _ value: Any?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: Any] {
        try XCTUnwrap(value as? [String: Any], file: file, line: line)
    }

    private func array(
        _ value: Any?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [Any] {
        try XCTUnwrap(value as? [Any], file: file, line: line)
    }

    private func int(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    private func double(_ value: Any?) -> Double {
        (value as? NSNumber)?.doubleValue ?? .nan
    }

    private func bool(_ value: Any?) -> Bool? {
        (value as? NSNumber)?.boolValue
    }
}
