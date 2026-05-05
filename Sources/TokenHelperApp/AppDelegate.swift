import AppKit
import TokenHelperCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var statusPanelController: StatusPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let sampleStore = (try? QuotaSampleStore.defaultStore()) ?? QuotaSampleStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("tokenhelper-quota-samples.jsonl")
        )
        let powerController = PowerSessionController()
        let model = AppModel(
            powerController: powerController,
            quotaClient: CodexRateLimitClient(),
            sampleStore: sampleStore,
            failSafeInstaller: ClamshellFailSafeInstaller()
        )
        self.model = model
        self.statusPanelController = StatusPanelController(model: model)
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.shutdown()
    }
}

