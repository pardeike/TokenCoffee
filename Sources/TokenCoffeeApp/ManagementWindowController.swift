import AppKit
import SwiftUI
import TokenCoffeeCore

enum ManagementSection: String, CaseIterable {
    case predictors = "Predictors", accounts = "Accounts"
}

@MainActor
final class ManagementState: ObservableObject {
    @Published var section: ManagementSection = .predictors
    @Published var predictorID: UUID?
    @Published var accountID: UUID?
    @Published var newPredictor: Predictor?
    @Published var editorVersion = UUID()
    @Published var selectionVersion = UUID()
    @Published var dirty = false
    @Published var busy = false
    var navigate: (@escaping () -> Void) -> Void = { $0() }
}

@MainActor
final class ManagementWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    static let contentSize = NSSize(width: 760, height: 500)
    let state = ManagementState()
    private lazy var sections = NSSegmentedControl(labels: ["Predictors", "Accounts"], trackingMode: .selectOne,
        target: self, action: #selector(changeSection(_:)))

    init(model: LinkedDashboardModel) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Token Coffee Settings"
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.tabbingMode = .disallowed
        window.contentMinSize = Self.contentSize
        window.contentMaxSize = Self.contentSize
        let hosting = NSHostingView(rootView: ManagementView(model: model, state: state))
        hosting.sizingOptions = []
        window.contentView = hosting
        sections.selectedSegment = 0
        sections.setAccessibilityIdentifier("management.sections")
        let toolbar = NSToolbar(identifier: "LinkedManagementToolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.setContentSize(Self.contentSize)
        window.center()
        window.setFrameUsingName("LinkedAccountManagement")
        window.setFrameAutosaveName("LinkedAccountManagement")
        // Frame restoration owns position only; this dialog has one content size.
        window.setContentSize(Self.contentSize)
        window.delegate = self
        state.predictorID = model.predictors.items.first?.id
        state.accountID = model.accounts.first?.id
        state.navigate = { [weak self] action in self?.navigate(action) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ section: ManagementSection) {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if state.section != section { navigate { [weak self] in self?.select(section) } }
    }

    private func select(_ section: ManagementSection) {
        state.section = section
        sections.selectedSegment = section == .predictors ? 0 : 1
    }

    @objc private func changeSection(_ sender: NSSegmentedControl) {
        let section: ManagementSection = sender.selectedSegment == 0 ? .predictors : .accounts
        sender.selectedSegment = state.section == .predictors ? 0 : 1
        guard section != state.section else { return }
        navigate { [weak self] in self?.select(section) }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, NSToolbarItem.Identifier("sections")]
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, NSToolbarItem.Identifier("sections"), .flexibleSpace]
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard identifier.rawValue == "sections" else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Sections"
        item.view = sections
        return item
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // A login sheet owns its pending authorization. Dismiss through its
        // Cancel action so the task and in-memory login are both released.
        guard sender.attachedSheet == nil else { return false }
        guard state.dirty || state.busy else { return true }
        navigate { sender.close() }
        return false
    }

    private func navigate(_ action: @escaping () -> Void) {
        guard let window, !state.busy, window.attachedSheet == nil else { NSSound.beep(); return }
        guard state.dirty else { action(); return }
        let alert = NSAlert()
        alert.messageText = "Discard unsaved changes?"
        alert.informativeText = "The changes in this editor have not been saved."
        alert.addButton(withTitle: "Keep Editing")
        alert.addButton(withTitle: "Discard Changes")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.state.selectionVersion = UUID()
            guard response == .alertSecondButtonReturn else { return }
            self.state.dirty = false
            self.state.newPredictor = nil
            self.state.editorVersion = UUID()
            action()
        }
    }
}

private struct ManagementView: View {
    @ObservedObject var model: LinkedDashboardModel
    @ObservedObject var state: ManagementState

    var body: some View {
        Group {
            switch state.section {
            case .predictors: PredictorSettingsView(model: model, store: model.predictors, state: state)
            case .accounts: AccountManagementView(model: model, state: state)
            }
        }.padding(12)
    }
}

private struct AccountManagementView: View {
    @ObservedObject var model: LinkedDashboardModel
    @ObservedObject var state: ManagementState
    @State private var loginRequest: AccountLoginRequest?
    @State private var removing = false

    private var account: LinkedUsageAccount? { model.accounts.first { $0.id == state.accountID } }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
            List(selection: Binding(get: { state.accountID }, set: { id in
                guard id != state.accountID else { return }
                state.navigate { state.accountID = id; state.editorVersion = UUID() }
            })) {
                ForEach(model.accounts) { account in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(account.name).lineLimit(1)
                        Text(account.provider).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4).tag(account.id)
                }
            }.listStyle(.inset).id(state.selectionVersion)
                .accessibilityIdentifier("management.accounts")
            Divider()
            HStack(spacing: 10) {
                Button { state.navigate { loginRequest = AccountLoginRequest(account: nil) } } label: { Image(systemName: "plus") }
                    .disabled(model.refreshing || model.linking)
                    .help("Add account").accessibilityLabel("Add account").accessibilityIdentifier("accounts.add")
                Button { state.navigate { removing = true } } label: { Image(systemName: "minus") }
                    .disabled(account == nil || model.refreshing || model.linking)
                    .help("Remove account").accessibilityLabel("Remove account").accessibilityIdentifier("accounts.remove")
                Spacer()
            }.padding(10)
            }.frame(width: 270)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let account {
                        Text(account.provider).font(.title2)
                            .foregroundStyle(UsageProviderStyle.color(for: account.provider))
                        AccountNameEditor(model: model, account: account,
                            changed: { state.dirty = $0 }, savingChanged: { state.busy = $0 })
                            .id(state.editorVersion)
                        if let email = account.email { Text(email).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                        if let plan = account.plan { Text(plan.capitalized).font(.caption).foregroundStyle(.secondary) }
                        HStack {
                            Button("Sign In Again…") { state.navigate { loginRequest = AccountLoginRequest(account: account) } }
                                .disabled(model.refreshing || model.linking)
                                .accessibilityIdentifier("accounts.relink")
                            Button(account.requiresSignIn ? "Sign In to Fetch Usage…" : "Refresh Usage") {
                                if account.requiresSignIn {
                                    state.navigate { loginRequest = AccountLoginRequest(account: account) }
                                } else { Task { await model.refresh(account.id) } }
                            }
                                .disabled(model.refreshing || model.linking)
                                .accessibilityIdentifier("accounts.refresh")
                        }
                        if model.refreshing { HStack { ProgressView().controlSize(.small); Text("Fetching usage…").font(.caption) } }
                        Text("Available values").font(.headline)
                        ForEach(model.sources.filter { $0.accountID == account.id }) { source in
                            HStack {
                                Text(source.title)
                                Spacer()
                                if let reading = model.diagrams.first(where: { $0.id == source.id }),
                                   let window = reading.snapshot.secondary {
                                    Text(window.usedPercent.formatted(.number.precision(.fractionLength(0...1))) + "% used")
                                        .monospacedDigit()
                                } else { Text("--").foregroundStyle(.secondary) }
                            }
                        }
                        if let latest = model.diagrams.filter({ $0.accountID == account.id }).map(\.capturedAt).max() {
                            Text("Last updated \(latest.formatted(date: .abbreviated, time: .standard)).")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("No usage fetched yet. \(account.requiresSignIn ? "Sign in to reconnect this account." : "Use Refresh Usage to fetch current values.")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if model.sources.filter({ $0.accountID == account.id }).isEmpty {
                            Text("Values are discovered after the first successful usage read.").font(.caption).foregroundStyle(.secondary)
                        }
                        if let error = model.errors[account.id] { Text(error).font(.caption).foregroundStyle(.orange) }
                        Text("Account names identify data sources. Predictor names and colours are managed separately.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Select an account, or use + to link a Claude or Codex account.").foregroundStyle(.secondary)
                    }
                    if let message = model.accountMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(22)
            }
        }
        .onAppear { if state.accountID == nil { state.accountID = model.accounts.first?.id } }
        .sheet(item: $loginRequest) { request in
            AccountLoginView(model: model, request: request) { id in
                state.accountID = id; state.editorVersion = UUID(); loginRequest = nil
            } cancel: { loginRequest = nil }
                .id(request.id)
        }
        .alert("Remove this account from TokenCoffee?", isPresented: $removing) {
            Button("Cancel", role: .cancel) { }
            Button("Remove Account", role: .destructive) {
                guard let account else { return }
                state.busy = true
                Task {
                    if await model.removeAccount(account) {
                        state.accountID = model.accounts.first?.id; state.editorVersion = UUID()
                    }
                    state.busy = false
                }
            }
        } message: {
            Text("This removes the account link and its TokenCoffee-managed login, not your provider account or coding-tool logins. Its \(model.predictors.items.filter { $0.accountID == state.accountID }.count) predictors and usage history will be kept. You can reassign or remove those predictors separately.")
        }
    }
}
