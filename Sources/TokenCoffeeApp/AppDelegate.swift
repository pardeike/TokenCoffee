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
        let model = AppModel(
            powerController: powerController,
            quotaClient: CodexRateLimitClient(),
            sampleStore: sampleStore,
            sampleSyncService: CloudQuotaSampleSyncService(),
            failSafeInstaller: ClamshellFailSafeInstaller()
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
}
