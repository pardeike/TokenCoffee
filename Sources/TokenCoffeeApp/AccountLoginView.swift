import AppKit
import SwiftUI
import TokenCoffeeCore

// A sheet and its target are one value, never independently updated state.
struct AccountLoginRequest: Identifiable {
    let id = UUID()
    let account: LinkedUsageAccount?
}

struct AccountLoginView: View {
    @ObservedObject var model: LinkedDashboardModel
    let request: AccountLoginRequest
    private var account: LinkedUsageAccount? { request.account }
    let linked: (UUID) -> Void
    let cancel: () -> Void
    @State private var provider = "Claude"
    @State private var login: LinkedAccountLogin?
    @State private var code = ""
    @State private var message: String?
    @State private var working = false
    @State private var task: Task<Void, Never>?
    @State private var dismissing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(account == nil ? "Add Account" : "Sign In Again").font(.title2)
            if let account {
                Text(account.provider + " · " + account.name).font(.headline)
                Text("Use the same account to keep its predictors and history. A different account will not replace it.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Provider", selection: $provider) {
                    Text("Claude").tag("Claude")
                    Text("Codex").tag("Codex")
                }.pickerStyle(.radioGroup).disabled(login != nil || working)
                    .accessibilityIdentifier("account.login.provider")
                Text("Link an existing subscription account. TokenCoffee keeps its own login and does not change the accounts used by your coding tools.")
                    .foregroundStyle(.secondary)
            }
            if let login {
                if let deviceCode = login.deviceCode {
                    Text(deviceCode).font(.system(size: 24, design: .monospaced)).textSelection(.enabled)
                    Text("Enter this code in the browser. Check which account you are signing in to. Codex may require device-code sign-in to be enabled in its security settings.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Authorize in your browser, then return here and paste the complete code#state.")
                    Text("Authorization code").font(.caption)
                    SecureField("Authorization code", text: $code)
                        .textFieldStyle(.roundedBorder).accessibilityIdentifier("account.login.code")
                        .disabled(working)
                }
                Button("Open Sign-In Page") { open(login.url) }
                    .disabled(working || dismissing).accessibilityIdentifier("account.login.open")
            }
            if let message { Text(message).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            if working { HStack { ProgressView().controlSize(.small); Text("\(account == nil ? "Linking" : "Reconnecting") account and fetching usage…").font(.caption) } }
            HStack {
                Button("Cancel", role: .cancel) {
                    dismissing = true
                    task?.cancel()
                    Task {
                        // Await cancellation so a late network completion cannot
                        // publish a pending login after the sheet has disappeared.
                        await task?.value
                        await model.cancelAccountLogin()
                        cancel()
                    }
                }.disabled(dismissing).accessibilityIdentifier("account.login.cancel")
                Spacer()
                if login == nil {
                    Button(message == nil ? "Continue in Browser" : "Start New Sign-In", action: begin)
                        .disabled(working || model.refreshing || dismissing)
                        .accessibilityIdentifier("account.login.begin")
                } else if login?.deviceCode == nil {
                    Button(account == nil ? "Link & Fetch Usage" : "Reconnect & Fetch Usage", action: complete)
                        .disabled(working || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || dismissing)
                        .accessibilityIdentifier("account.login.complete")
                } else if !working {
                    Button("Try Again", action: complete).disabled(dismissing)
                }
            }
        }.padding(24).frame(width: 440)
        .interactiveDismissDisabled()
        .onDisappear { code = ""; task?.cancel() }
    }

    private func open(_ url: URL) {
        if !NSWorkspace.shared.open(url) { message = "The browser could not open. Try Open Sign-In Page again." }
    }
    private func begin() {
        working = true; message = nil
        task = Task {
            do {
                let result = try await model.beginAccountLogin(provider: account?.provider ?? provider, replacing: request.account?.id)
                try Task.checkCancellation()
                login = result
                open(result.url)
                if result.deviceCode != nil {
                    let id = try await model.completeAccountLogin(result, code: "")
                    if !dismissing { linked(id) }
                }
            } catch { await failed(error) }
            working = false
        }
    }
    private func complete() {
        guard let login else { return }
        working = true; message = nil
        let input = code
        code = ""
        task = Task {
            do {
                let id = try await model.completeAccountLogin(login, code: input)
                if !dismissing { linked(id) }
            } catch {
                if case LinkedAccountError.invalidCode = error { code = input }
                await failed(error)
            }
            working = false
        }
    }

    private func failed(_ error: Error) async {
        // Only local code validation is safe to retry with the same grant.
        // Network/commit failures may already have consumed the browser code.
        if case LinkedAccountError.invalidCode = error {
            if !dismissing { message = LinkedAccountError.message(for: error) }
            return
        }
        await model.cancelAccountLogin()
        login = nil; code = ""
        if !dismissing {
            message = LinkedAccountError.message(for: error) + " Start a new browser sign-in to try again."
        }
    }
}
