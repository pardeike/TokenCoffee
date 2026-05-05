import SwiftUI
import TokenHelperCore

@main
struct TokenHelperApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        if CommandLine.arguments.contains("--reset-clamshell") {
            try? IOKitPowerAssertionClient().setClamshellSleepDisabled(false)
            TokenHelperDefaults.setClosedDisplayModeEnabled(false)
            Darwin.exit(0)
        }
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

