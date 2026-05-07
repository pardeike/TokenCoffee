import AppKit
import TokenCoffeeCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var statusPanelController: StatusPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let sampleStore = (try? QuotaSampleStore.defaultStore()) ?? QuotaSampleStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("tokencoffee-quota-samples.jsonl")
        )
        let powerController = PowerSessionController()
        let demoScenario = Self.demoScenarioIfRequested()
        let model = AppModel(
            powerController: powerController,
            quotaClient: CodexRateLimitClient(),
            sampleStore: sampleStore,
            sampleSyncService: CloudQuotaSampleSyncService(),
            failSafeInstaller: ClamshellFailSafeInstaller(),
            demoScenario: demoScenario
        )
        self.model = model
        self.statusPanelController = StatusPanelController(model: model)
        DispatchQueue.main.async { [weak model] in
            model?.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.shutdown()
    }

    private static func demoScenarioIfRequested() -> DemoQuotaScenario? {
        guard CommandLine.arguments.contains("--demo") else {
            return nil
        }

        guard let url = Bundle.main.url(forResource: "DemoQuotaData", withExtension: "json") else {
            NSLog("Token Coffee demo mode requested, but DemoQuotaData.json is missing.")
            return nil
        }

        do {
            let data = try Data(contentsOf: url)
            let demoData = try JSONDecoder().decode(DemoQuotaData.self, from: data)
            return try demoData.makeScenario()
        } catch {
            NSLog("Token Coffee demo mode requested, but demo data could not be loaded: \(error.localizedDescription)")
            return nil
        }
    }
}
