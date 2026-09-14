import SwiftUI
import TokenCoffeeCore

@main
struct TokenCoffeeApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        if CommandLine.arguments.contains("--verify-account-keychain") {
            do { try AccountKeychainVerification.run(); print("ok"); Darwin.exit(0) }
            catch {
                fputs(LinkedAccountError.message(for: error) + "\n", stderr)
                Darwin.exit(1)
            }
        }
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
