import AppKit
import SwiftUI
import TokenCoffeeCore

struct LinkedDashboardView: View {
    @ObservedObject var model: LinkedDashboardModel
    @ObservedObject var geometry: DashboardLayoutState
    let setLayout: (PrototypeLayout) -> Void
    let showManagement: (ManagementSection) -> Void
    let close: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { bounds in
            ZStack(alignment: .topLeading) {
                if geometry.resizing {
                    schematic(in: bounds.size)
                } else {
                    controls.frame(width: bounds.size.width - 24, height: 24).offset(x: 12, y: 10)
                    if geometry.showingAbout {
                        Text("Token Coffee\nAccounts and predictors\nUsage history syncs through your private iCloud database when available.")
                            .font(.system(size: 12)).multilineTextAlignment(.center)
                            .frame(width: bounds.size.width - 24, height: bounds.size.height - 54).offset(x: 12, y: 42)
                    } else if model.pagePredictors.isEmpty {
                        VStack(spacing: 10) {
                            Text(model.refreshing ? "Reading linked accounts…" : "Choose the limits you want to follow.")
                            Button("Add Predictor") { showManagement(.predictors) }
                                .accessibilityIdentifier("dashboard.addPredictor")
                        }.font(.system(size: 12)).multilineTextAlignment(.center)
                            .frame(width: bounds.size.width - 24, height: bounds.size.height - 54).offset(x: 12, y: 42)
                    } else {
                        ForEach(geometry.tiles) { tile in
                            if model.pagePredictors.indices.contains(tile.id) {
                                let predictor = model.pagePredictors[tile.id]
                                if let diagram = model.diagram(for: predictor) {
                                let stale = model.errors[diagram.accountID] != nil || Date().timeIntervalSince(diagram.capturedAt) > 660
                                UsageTileView(title: predictor.name, provider: model.provider(diagram), snapshot: diagram.snapshot,
                                    samples: diagram.samples,
                                    projection: QuotaProjectionEngine.make(snapshot: diagram.snapshot, samples: diagram.samples, now: Date()),
                                    now: Date(), kind: tile.kind,
                                    status: stale ? "Stale · " + diagram.capturedAt.formatted(date: .omitted, time: .shortened) : diagram.syncMessage,
                                    prominent: geometry.layout.followsActivity && tile.id == geometry.primary,
                                    inspecting: geometry.inspectedAccount != nil, accent: predictor.color.value)
                                    .frame(width: tile.frame.width, height: tile.frame.height)
                                    .contentShape(Rectangle())
                                    .onTapGesture { geometry.inspect(tile.id) }
                                    .accessibilityElement(children: .combine)
                                    .accessibilityLabel(model.provider(diagram) + " · " + predictor.name)
                                    .accessibilityValue("\(Int(diagram.snapshot.secondary?.usedPercent ?? 0)) percent used")
                                    .accessibilityAddTraits(.isButton)
                                    .accessibilityAction { geometry.inspect(tile.id) }
                                    .offset(x: tile.frame.minX, y: tile.frame.minY)
                                } else {
                                    VStack(spacing: 6) {
                                        Text(predictor.name).foregroundStyle(predictor.color.value)
                                        Text(model.refreshing ? "Reading…" : "Value unavailable").foregroundStyle(.secondary)
                                    }.font(.system(size: 12)).multilineTextAlignment(.center)
                                        .frame(width: tile.frame.width, height: tile.frame.height)
                                        .offset(x: tile.frame.minX, y: tile.frame.minY)
                                }
                            }
                        }
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: geometry.primary)
                    }
                }
            }
            .frame(width: bounds.size.width, height: bounds.size.height, alignment: .topLeading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .onHover { geometry.hovering = $0 }
        }
    }

    private var controls: some View {
        HStack(spacing: 6) {
            if geometry.inspectedAccount != nil || geometry.showingAbout {
                Button("Back") { geometry.menuOpen = false; geometry.back() }
                    .accessibilityIdentifier("dashboard.back")
            } else {
                if let power = model.power { DashboardPowerControls(model: power) }
                else {
                    Text("\(model.accounts.count) accounts · \(model.predictors.items.count) predictors")
                        .foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if model.pageCount > 1 {
                Button("\(model.page + 1)/\(model.pageCount)") { model.nextPage() }.help("Next group of diagrams")
            }
            LinkedDashboardMenu(model: model, setLayout: setLayout, showManagement: showManagement, close: close).frame(width: 24, height: 24)
        }
        .font(.system(size: 12))
        .contentShape(Rectangle()).gesture(WindowDragGesture())
    }

    private func schematic(in size: CGSize) -> some View {
        let sx = size.width / geometry.previewSize.width
        let sy = size.height / geometry.previewSize.height
        return ZStack(alignment: .topLeading) {
            if geometry.showingAbout {
                Rectangle().strokeBorder(.secondary.opacity(0.45), lineWidth: 1)
                    .overlay { Image(systemName: "info.circle").foregroundStyle(.secondary) }
                    .padding(12)
            } else {
                ForEach(geometry.tiles) { tile in
                    RoundedRectangle(cornerRadius: 5).strokeBorder(.secondary.opacity(0.45), lineWidth: 1)
                        .overlay { Image(systemName: tile.kind.symbol).font(.system(size: 24, weight: .light)).foregroundStyle(.secondary) }
                        .frame(width: tile.frame.width * sx, height: tile.frame.height * sy)
                        .offset(x: tile.frame.minX * sx, y: tile.frame.minY * sy)
                }
            }
        }.frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

struct AccountNameEditor: View {
    @ObservedObject var model: LinkedDashboardModel
    let account: LinkedUsageAccount
    @State private var draft: String
    @State private var saving = false
    @State private var failed = false
    let changed: (Bool) -> Void
    let savingChanged: (Bool) -> Void

    init(model: LinkedDashboardModel, account: LinkedUsageAccount,
         changed: @escaping (Bool) -> Void, savingChanged: @escaping (Bool) -> Void) {
        self.model = model
        self.account = account
        _draft = State(initialValue: account.name)
        self.changed = changed
        self.savingChanged = savingChanged
    }
    private var clean: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var valid: Bool { !clean.isEmpty && clean.count <= 60 && !clean.contains(where: { $0.isNewline }) }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Name").font(.caption)
                TextField("Account name", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("account.name." + account.id.uuidString)
                    .disabled(saving)
            }
            if draft != account.name {
                HStack {
                    Button(saving ? "Saving…" : "Save") {
                        saving = true
                        failed = false
                        Task {
                            if await model.rename(account, to: clean) { draft = clean; changed(false) }
                            else { failed = true }
                            saving = false
                        }
                    }.disabled(!valid || saving)
                    .accessibilityIdentifier("account.save." + account.id.uuidString)
                    Button("Cancel") { draft = account.name; failed = false }.disabled(saving)
                }
                if !valid { Text("Use 1–60 characters on one line.").font(.caption).foregroundStyle(.secondary) }
                if failed { Text("Could not save the name. Please try again.").font(.caption).foregroundStyle(.red) }
            }
        }
        .onChange(of: account.name) { _, name in draft = name }
        .onChange(of: draft) { _, _ in changed(draft != account.name) }
        .onChange(of: saving) { _, value in savingChanged(value) }
    }
}

private struct LinkedDashboardMenu: NSViewRepresentable {
    let model: LinkedDashboardModel
    let setLayout: (PrototypeLayout) -> Void
    let showManagement: (ManagementSection) -> Void
    let close: () -> Void
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: "line.3.horizontal.circle.fill", accessibilityDescription: "Dashboard menu")!,
            target: context.coordinator, action: #selector(Coordinator.open(_:)))
        button.isBordered = false
        button.setAccessibilityIdentifier("dashboard.menu")
        return button
    }
    func updateNSView(_ view: NSButton, context: Context) { context.coordinator.parent = self }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    @MainActor final class Coordinator: NSObject {
        var parent: LinkedDashboardMenu
        init(_ parent: LinkedDashboardMenu) { self.parent = parent }
        @objc func open(_ sender: NSButton) {
            let model = parent.model
            model.geometry.menuOpen = true
            defer { model.geometry.menuOpen = false }
            let menu = NSMenu()
            if let power = model.power {
                let blackout = NSMenuItem(title: "Screen blackout", action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                for delay in ScreenBlackoutDelay.allCases {
                    let title = delay.inactivityThreshold.map { "After \(Int($0 / 60)) min" } ?? "Off"
                    let item = LinkedMenuItem(title) { power.setScreenBlackoutDelay(delay) }
                    item.state = power.screenBlackoutDelay == delay ? .on : .off
                    submenu.addItem(item)
                }
                blackout.submenu = submenu
                menu.addItem(blackout)
                if let error = power.powerErrorMessage {
                    let item = NSMenuItem(title: error, action: nil, keyEquivalent: "")
                    item.isEnabled = false; menu.addItem(item)
                }
                menu.addItem(.separator())
            }
            menu.addItem(LinkedMenuItem("Predictors…") { [parent] in parent.showManagement(.predictors) })
            menu.addItem(LinkedMenuItem("Accounts…") { [parent] in parent.showManagement(.accounts) })
            menu.addItem(.separator())
            for layout in PrototypeLayout.allCases {
                let item = LinkedMenuItem(layout.title) { [parent] in parent.setLayout(layout) }
                item.state = model.geometry.layout == layout ? .on : .off
                menu.addItem(item)
            }
            menu.addItem(.separator())
            menu.addItem(LinkedMenuItem("About") { model.geometry.showingAbout = true })
            menu.addItem(LinkedMenuItem("Close Window", parent.close))
            menu.addItem(LinkedMenuItem("Quit Token Coffee") { NSApp.terminate(nil) })
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
        }
    }
}

private struct DashboardPowerControls: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Picker("Power", selection: Binding(get: { model.powerMode }, set: { model.setPowerMode($0) })) {
            Text("Off").tag(PowerSessionMode.off)
            Text("Mac awake").tag(PowerSessionMode.keepAwake)
            Text("Screen on").tag(PowerSessionMode.keepAwakeDisplay)
        }.pickerStyle(.segmented).labelsHidden().controlSize(.small)
            .accessibilityIdentifier("dashboard.power")
            .help(model.powerErrorMessage ?? "Keep the Mac awake or keep its screen on")
    }
}

@MainActor private final class LinkedMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { handler() }
}
