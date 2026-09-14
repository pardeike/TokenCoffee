import Combine
import Foundation
import TokenCoffeeCore

struct PrototypeAccount: Identifiable {
    let id: Int
    let provider: String
    let name: String
    let scenario: DemoQuotaScenario
    let projection: QuotaProjection
    var title: String { "\(provider) · \(name)" }
}

@MainActor
final class PrototypeModel: DashboardLayoutState {
    enum Scenario: String, CaseIterable {
        case ongoing = "Ongoing activity", competing = "Competing bursts", quiet = "All quiet"
        case limited = "Short-window limit", stale = "Stale account"
    }
    @Published var scenario: Scenario = .ongoing
    let accounts: [PrototypeAccount]
    private var primaryElapsed: TimeInterval = 0
    private var secondaryElapsed: TimeInterval = 0

    override init() {
        let now = DemoQuotaData.referenceDate()
        let labels = [("Codex", "Personal"), ("Claude", "Work"), ("Codex", "Work"), ("Claude", "Home")]
        let values = [31.0, 62, 44, 18]
        accounts = labels.enumerated().map { index, label in
            let elapsed = [3_000, 5_000, 7_000, 2_000][index]
            let points = (0...60).map { step in
                DemoQuotaSamplePoint(offsetMinutes: elapsed * step / 60,
                                     weeklyUsedPercent: values[index] * pow(Double(step) / 60, [1.6, 0.8, 1.15, 2.2][index]))
            }
            let data = DemoQuotaData(limitId: "prototype-\(index)", limitName: label.0, planType: "pro",
                                     weeklyWindowMinutes: 10_080, elapsedWindowMinutes: elapsed,
                                     weeklyUsedPercent: values[index], fiveHourUsedPercent: [22, 88, 14, 6][index],
                                     fiveHourResetOffsetMinutes: [180, 40, 220, 110][index], samples: points)
            // These fixtures are local constants; invalid data is a programming error.
            let sample = try! data.makeScenario(referenceDate: now)
            return PrototypeAccount(id: index, provider: label.0, name: label.1, scenario: sample,
                                    projection: QuotaProjectionEngine.make(snapshot: sample.snapshot, samples: sample.samples, now: now))
        }
        super.init()
    }

    override func advance(by elapsed: TimeInterval) {
        guard !paused, layout.followsActivity, count > 1 else { return }
        primaryElapsed += elapsed
        secondaryElapsed += elapsed
        if primaryElapsed >= 30, scenario == .ongoing || scenario == .competing {
            primary = (primary + 1) % (scenario == .competing ? min(2, count) : count)
            primaryElapsed = 0
            if secondary == primary { secondary = (primary + 1) % count }
        }
        if secondaryElapsed >= 15 {
            repeat { secondary = (secondary + 1) % count } while secondary == primary
            secondaryElapsed = 0
        }
    }
    override func setCount(_ value: Int) {
        super.setCount(min(4, value))
        primaryElapsed = 0
        secondaryElapsed = 0
    }
    func status(for id: Int) -> String? {
        if scenario == .stale, id == count - 1 { return "Stale · 12m" }
        if scenario == .limited, id == min(1, count - 1) { return "5h limit · 40m" }
        return nil
    }
}
