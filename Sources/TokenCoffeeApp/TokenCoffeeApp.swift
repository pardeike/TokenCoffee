import SwiftUI
import TokenCoffeeCore

@main
struct TokenCoffeeApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        if CommandLine.arguments.contains("--reset-clamshell") {
            try? IOKitPowerAssertionClient().setClamshellSleepDisabled(false)
            TokenCoffeeDefaults.setClosedDisplayModeEnabled(false)
            Darwin.exit(0)
        }
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

