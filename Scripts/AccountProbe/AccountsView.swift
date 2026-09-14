import AppKit
import SwiftUI

@MainActor
final class AccountsModel: ObservableObject {
    enum Page: Equatable { case list, detail(UUID), codex, claude }
    @Published var page = Page.list
    @Published private(set) var registry: AccountRegistry
    @Published private(set) var busy = false
    @Published private(set) var message = ""
    @Published private(set) var loginCode: String?
    @Published private(set) var loginURL: URL?
    @Published private(set) var readings: [UUID: [String]] = [:]
    @Published private(set) var checkedAt: [UUID: Date] = [:]
    @Published private(set) var errors: [UUID: String] = [:]
    private let root: URL
    private var registryURL: URL { root.appendingPathComponent("accounts.json") }
    private var task: Task<Void, Never>?

    init(root: URL, initialClaudeDirectory: UUID) throws {
        self.root = root
        registry = try AccountRegistry.load(from: root.appendingPathComponent("accounts.json"),
                                             initialClaudeDirectory: initialClaudeDirectory)
        if registry.pendingCodexID != nil {
            busy = true
            task = Task {
                do {
                    try await cleanPendingLogin()
                    message = "The unfinished sign-in was cancelled. Your linked accounts are unchanged."
                } catch {
                    message = "Could not clean up the unfinished sign-in. Restart to try again."
                }
                busy = false
                task = nil
            }
        }
    }

    func stop() { task?.cancel() }

    func show(_ page: Page) {
        guard !busy else { return }
        message = ""
        self.page = page
    }

    func back() {
        task?.cancel()
        loginCode = nil
        loginURL = nil
        message = ""
        page = .list
    }

    func rename(_ account: ProbeAccount, to name: String) {
        guard !busy else { return }
        var updated = account
        updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try save(registry.replacing(updated))
            message = "Name saved."
        } catch { message = "Could not save the name. Use a nonempty name and try again." }
    }

    private func save(_ next: AccountRegistry) throws {
        try next.saving(to: registryURL)
        registry = next
    }

    private func cleanPendingLogin() async throws {
        guard let id = registry.pendingCodexID else { return }
        try await KeychainCodexAuthTokenStore(service: ScopedCodexTokens.service, account: id.uuidString).delete()
        var next = registry
        next.pendingCodexID = nil
        try save(next)
    }

    func linkCodex() {
        guard !busy, registry.pendingCodexID == nil else { return }
        busy = true
        message = "Preparing secure sign-in…"
        task = Task {
            do {
                let id = UUID()
                var pending = registry
                pending.pendingCodexID = id
                try save(pending)
                let service = CodexNativeAuthService(configuration: .defaultConfiguration(),
                    httpClient: URLSessionCodexHTTPClient(), tokenStore: PendingCodexTokens())
                let code = try await service.requestDeviceCode()
                try Task.checkCancellation()
                loginCode = code.userCode
                loginURL = code.verificationURL
                message = "Use this code in your browser. Check that you sign in to the account you want to add."
                if !NSWorkspace.shared.open(code.verificationURL) {
                    message = "The browser could not open. Use Open sign-in page to try again."
                }
                let tokens = try await service.completeDeviceCodeLogin(code)
                try Task.checkCancellation()
                let identity = try ScopedCodexTokens.identity(tokens)
                let snapshot = service.accountSnapshot(for: tokens)
                let account = ProbeAccount(id: id, provider: .codex,
                    name: snapshot.email ?? "Codex account", email: snapshot.email,
                    plan: snapshot.planType, identity: identity)
                var next = registry
                next.pendingCodexID = nil
                next = try next.replacing(account)
                try await ScopedCodexTokens(id: id, expectedIdentity: identity).save(tokens)
                try Task.checkCancellation()
                try save(next)
                loginCode = nil
                loginURL = nil
                page = .detail(id)
                message = "Account linked. Refresh usage to check its allowance."
            } catch {
                let cancelled = Task.isCancelled
                do {
                    try await cleanPendingLogin()
                    message = cancelled ? "Sign-in cancelled. Your linked accounts are unchanged." : Self.explanation(error)
                } catch {
                    message = "Sign-in stopped, but private credential cleanup failed. Restart before trying again."
                }
                loginCode = nil
                loginURL = nil
            }
            busy = false
            task = nil
        }
    }

    func refresh(_ account: ProbeAccount) {
        guard !busy else { return }
        busy = true
        message = ""
        task = Task {
            do {
                var updated = account
                let windows: [String]
                switch account.provider {
                case .claude:
                    guard let directory = account.claudeDirectory else {
                        throw NativeUsage.Failure(diagnostic: "invalid_private_profile")
                    }
                    let profile = root.appendingPathComponent(directory.uuidString)
                        .appendingPathComponent("claude-account-a")
                    let result = try await NativeUsage.fetchAccount(profilePath: profile.path,
                                                                    expectedIdentity: account.identity)
                    updated.identity = result.0.identity
                    updated.email = result.0.email
                    if updated.name == "Claude account" { updated.name = result.0.email }
                    windows = result.1
                case .codex:
                    guard let identity = account.identity else {
                        throw NativeUsage.Failure(diagnostic: "account_identity_unavailable")
                    }
                    let client = CodexRateLimitClient(configuration: .defaultConfiguration(),
                        httpClient: URLSessionCodexHTTPClient(),
                        tokenStore: ScopedCodexTokens(id: account.id, expectedIdentity: identity))
                    let result = try await client.fetch()
                    updated.email = result.account?.email
                    updated.plan = result.account?.planType
                    let snapshot = result.response.codexSnapshot
                    windows = [snapshot.primary, snapshot.secondary].compactMap { window in
                        guard let window else { return nil }
                        let duration = window.windowDurationMins.map { $0 >= 1440 ? "\($0 / 1440)-day" : "\($0 / 60)-hour" } ?? "Allowance"
                        let reset = window.resetDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "unknown"
                        return "\(duration): \(window.usedPercent)% used; resets \(reset)"
                    }
                    guard !windows.isEmpty else { throw NativeUsage.Failure(diagnostic: "missing_usage_windows") }
                }
                try Task.checkCancellation()
                try save(registry.replacing(updated))
                readings[account.id] = windows
                checkedAt[account.id] = Date()
                errors[account.id] = nil
            } catch {
                if !Task.isCancelled { errors[account.id] = Self.explanation(error) }
            }
            busy = false
            task = nil
        }
    }

    static func explanation(_ error: Error) -> String {
        if let failure = error as? NativeUsage.Failure {
            switch failure.diagnostic {
            case "account_already_linked": return "This account is already linked. Linking it again would share the same allowance."
            case "account_identity_changed": return "The credential now belongs to a different account. Usage was not assigned to this account."
            case "credential_expired; no_refresh_attempted": return "Claude sign-in has expired. This prototype leaves renewal to the official Claude client."
            case "http_status=429; no_retry": return "The provider asked us to wait. No automatic retry will run."
            default: return "Could not read this private account (\(failure.diagnostic)). Your normal coding accounts were not used."
            }
        }
        // Provider errors can contain raw HTTP bodies. Never display or log those.
        if error as? CodexRateLimitClient.ClientError == .needsSignIn {
            return "This Codex account needs sign-in again. Relinking existing accounts is not connected in this prototype yet."
        }
        if case CodexNativeAuthError.loginTimedOut = error { return "Sign-in timed out. Start again when you are ready." }
        return "The operation could not finish. Check your connection and try again. No account was replaced."
    }
}

struct AccountsView: View {
    @ObservedObject var model: AccountsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                if model.page != .list { Button("Back") { model.back() } }
                Text(title).font(.title2.weight(.semibold))
                Spacer()
                if model.busy { ProgressView().controlSize(.small).accessibilityLabel("Working") }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch model.page {
                    case .list: accountList
                    case .detail(let id):
                        if let account = model.registry.accounts.first(where: { $0.id == id }) {
                            AccountDetail(model: model, account: account).id(id)
                        }
                    case .codex: codexLogin
                    case .claude:
                        Text("Additional Claude accounts") .font(.headline)
                        Text("The linked Claude account already uses its own private profile. Its usage is read directly over HTTPS.")
                        Text("Adding another Claude account still needs the official client's isolated login flow. That flow is not connected to this helper-free prototype yet.")
                        Text("No default terminal account or browser cookies will be imported.").foregroundStyle(.secondary)
                    }
                    if !model.message.isEmpty {
                        Text(model.message).font(.callout).foregroundStyle(.secondary)
                            .textSelection(.enabled).accessibilityIdentifier("accountMessage")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Private account prototype · Your coding accounts are unchanged")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(minWidth: 510, minHeight: 310)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var title: String {
        switch model.page {
        case .list: "Accounts"
        case .detail: "Account details"
        case .codex: "Link Codex account"
        case .claude: "Link Claude account"
        }
    }

    private var accountList: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Link the accounts whose allowance you want to follow.").foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(model.registry.accounts) { account in
                    if account.id != model.registry.accounts.first?.id { Divider().padding(.leading, 66) }
                    HStack(spacing: 12) {
                        AccountAvatar(provider: account.provider)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(account.name).font(.headline).lineLimit(1)
                            Text(subtitle(account)).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 8)
                        Button { model.show(.detail(account.id)) } label: {
                            Image(systemName: "info.circle").font(.title3).foregroundStyle(.secondary)
                        }.buttonStyle(.plain).disabled(model.busy)
                            .accessibilityLabel("Details for \(account.name)")
                    }.padding(14)
                }
            }
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
            HStack {
                Spacer(minLength: 0)
                Button("Link Claude account…") { model.show(.claude) }
                Button("Link Codex account…") { model.show(.codex) }
            }.disabled(model.busy)
        }
    }

    private func subtitle(_ account: ProbeAccount) -> String {
        let state: String
        if model.errors[account.id] != nil { state = "Needs attention" }
        else if let date = model.checkedAt[account.id] { state = "Checked \(date.formatted(date: .omitted, time: .shortened))" }
        else { state = "Usage not checked" }
        return ([account.provider.rawValue, account.plan?.capitalized, state].compactMap { $0 }).joined(separator: " · ")
    }

    private var codexLogin: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sign in with the ChatGPT account you want to monitor. It does not have to be the account used for coding on this Mac.")
            if let code = model.loginCode {
                Text(code).font(.system(size: 25, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                    .padding(16).frame(maxWidth: .infinity).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                if let url = model.loginURL { Button("Open sign-in page") { NSWorkspace.shared.open(url) } }
            } else {
                Text("A separate Keychain entry keeps this login independent of TokenCoffee's normal account and your Codex configuration.")
                    .foregroundStyle(.secondary)
                Button("Continue in browser") { model.linkCodex() }.disabled(model.busy)
            }
            Text("Back cancels an unfinished sign-in. You can link another account afterward.").font(.callout).foregroundStyle(.secondary)
        }
    }
}

private struct AccountAvatar: View {
    let provider: ProbeAccount.Provider
    var body: some View {
        Text(provider == .codex ? "O" : "C")
            .font(.system(size: 19, weight: .medium, design: .rounded))
            .frame(width: 40, height: 40)
            .background(provider == .codex ? Color.teal.opacity(0.24) : Color.orange.opacity(0.24), in: Circle())
            .accessibilityHidden(true)
    }
}

private struct AccountDetail: View {
    @ObservedObject var model: AccountsModel
    let account: ProbeAccount
    @State private var name: String = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                AccountAvatar(provider: account.provider)
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.email ?? account.name).font(.headline).textSelection(.enabled)
                    Text([account.provider.rawValue, account.plan?.capitalized].compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                TextField("Display name", text: $name).textFieldStyle(.roundedBorder)
                Button("Save name") { model.rename(account, to: name) }
                    .disabled(model.busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name == account.name)
            }
            Divider()
            HStack {
                Text("Allowance").font(.headline)
                Spacer()
                Button("Refresh usage") { model.refresh(account) }.disabled(model.busy)
            }
            if let error = model.errors[account.id] { Text(error).foregroundStyle(.orange).font(.callout) }
            if let readings = model.readings[account.id] {
                ForEach(readings, id: \.self) { Text($0).font(.callout).textSelection(.enabled) }
                if let date = model.checkedAt[account.id] {
                    Text("Last successful check \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else { Text("No usage reading yet.").foregroundStyle(.secondary) }
            Text(account.provider == .claude
                 ? "Private Claude profile · Official client owns sign-in and renewal"
                 : "Private Keychain entry · TokenCoffee owns sign-in and renewal")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { name = account.name }
        .onChange(of: account.name) { old, new in
            if name == old { name = new }
        }
    }
}
