import AppKit
import Combine
import TokenCoffeeCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var statusPanelController: StatusPanelController?
    private var screenBlankingController: ScreenBlankingController?
    private var screenBlankingCancellable: AnyCancellable?
    private var prototypeModel: PrototypeModel?
    private var linkedModel: LinkedDashboardModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        guard !Self.isRunningUnitTests else {
            return
        }

        if CommandLine.arguments.contains("--prototype") || CommandLine.arguments.contains("--linked-accounts") {
            NSLog("Prototype startup is retired. Launch Token Coffee normally.")
            NSApp.terminate(nil)
            return
        }

        if CommandLine.arguments.contains("--linked-accounts") {
            // Only the explicitly signed validation bundle can use the existing
            // sandbox account registry. Never fall back to external CLI profiles.
            guard Bundle.main.bundleIdentifier == "com.pardeike.TokenCoffee.AccountProbe" else {
                NSLog("Linked account validation requires the isolated account bundle identity.")
                NSApp.terminate(nil)
                return
            }
            do {
                let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                    appropriateFor: nil, create: true).appendingPathComponent("TokenCoffeeAccountProbe")
                let linked = LinkedDashboardModel(service: try LinkedUsageService(root: root))
                linkedModel = linked
                statusPanelController = StatusPanelController(linked: linked)
                linked.start()
                statusPanelController?.showPrototype()
            } catch {
                NSLog("Linked account registry is unavailable or invalid; existing accounts were not modified.")
                NSApp.terminate(nil)
            }
            return
        }

        if CommandLine.arguments.contains("--prototype") {
            let prototype = PrototypeModel()
            prototypeModel = prototype
            statusPanelController = StatusPanelController(prototype: prototype)
            prototype.start()
            statusPanelController?.showPrototype()
            return
        }

        let sampleStore = (try? QuotaSampleStore.defaultStore()) ?? QuotaSampleStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("tokencoffee-quota-samples.jsonl")
        )
        let powerController = PowerSessionController()
        let startsInDemoMode = CommandLine.arguments.contains("--demo")
        let demoScenario = Self.bundledDemoScenario(logErrors: startsInDemoMode)
        let model = AppModel(
            powerController: powerController,
            quotaClient: CodexRateLimitClient(),
            sampleStore: sampleStore,
            sampleSyncService: CloudQuotaSampleSyncService(),
            failSafeInstaller: ClamshellFailSafeInstaller(),
            demoScenario: demoScenario,
            startsInDemoMode: startsInDemoMode
        )
        let screenBlankingController = ScreenBlankingController()
        self.model = model
        // Configure ownership before opening the panel: panel-open refresh must
        // not start the legacy quota client beside the new account reader.
        model.start(managesQuota: startsInDemoMode)
        if startsInDemoMode {
            self.statusPanelController = StatusPanelController(model: model)
        } else {
            do {
                let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                    appropriateFor: nil, create: true).appendingPathComponent("TokenCoffee/multi-account")
                try Self.importTransferredSettings(root: root)
                let service = try LinkedUsageService(root: root, historySync: LinkedHistoryCloudSync(root: root))
                let linked = LinkedDashboardModel(service: service, power: model)
                linkedModel = linked
                statusPanelController = StatusPanelController(linked: linked)
                linked.start()
                statusPanelController?.showDashboard()
            } catch {
                let alert = NSAlert()
                alert.messageText = "Token Coffee could not load its accounts"
                alert.informativeText = "Existing account data has been kept. Check access to Token Coffee's application data and restart."
                alert.runModal()
                NSApp.terminate(nil)
                return
            }
        }
        self.screenBlankingController = screenBlankingController
        self.screenBlankingCancellable = Publishers.CombineLatest(
            model.$powerMode,
            model.$screenBlackoutDelay
        )
            .sink { [weak screenBlankingController] configuration in
                let (powerMode, blackoutDelay) = configuration
                Task { @MainActor in
                    screenBlankingController?.setConfiguration(
                        powerMode: powerMode,
                        blackoutDelay: blackoutDelay
                    )
                }
            }
    }

    private static func importTransferredSettings(root: URL) throws {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "multiAccount.settingsTransferred") else { return }
        let url = root.appendingPathComponent("transferred-settings.plist")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        guard let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw CocoaError(.coderReadCorrupt)
        }
        for (key, value) in values where key.hasPrefix("linkedDashboard.") || key == "NSWindow Frame LinkedAccountManagement" {
            if defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
        }
        defaults.set(true, forKey: "multiAccount.settingsTransferred")
    }

    func applicationWillTerminate(_ notification: Notification) {
        linkedModel?.stop()
        prototypeModel?.stop()
        screenBlankingCancellable?.cancel()
        screenBlankingController?.shutdown()
        model?.shutdown()
    }

    private static func bundledDemoScenario(logErrors: Bool) -> DemoQuotaScenario? {
        guard let url = Bundle.main.url(forResource: "DemoQuotaData", withExtension: "json") else {
            if logErrors {
                NSLog("Token Coffee demo mode requested, but DemoQuotaData.json is missing.")
            }
            return nil
        }

        do {
            let data = try Data(contentsOf: url)
            let demoData = try JSONDecoder().decode(DemoQuotaData.self, from: data)
            return try demoData.makeScenario()
        } catch {
            if logErrors {
                NSLog("Token Coffee demo mode requested, but demo data could not be loaded: \(error.localizedDescription)")
            }
            return nil
        }
    }

    private static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
