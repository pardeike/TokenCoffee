import AppKit
import SwiftUI
import TokenCoffeeCore

struct PrototypeDashboardView: View {
    @ObservedObject var model: PrototypeModel
    let setLayout: (PrototypeLayout) -> Void
    let close: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if model.resizing {
                    schematic(in: geometry.size)
                } else {
                    controls(width: geometry.size.width)
                        .frame(width: geometry.size.width - 24, height: 24)
                        .offset(x: 12, y: 10)
                    if model.showingAbout {
                        VStack(spacing: 4) {
                            Text("Token Coffee prototype").font(.headline)
                            Text("All accounts and power controls are simulated.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(width: geometry.size.width - 24, height: geometry.size.height - 48)
                        .offset(x: 12, y: 42)
                    } else {
                        ForEach(model.tiles) { tile in
                            UsageTileView(title: model.accounts[tile.id].title,
                                                 provider: model.accounts[tile.id].provider,
                                                 snapshot: model.accounts[tile.id].scenario.snapshot,
                                                 samples: model.accounts[tile.id].scenario.samples,
                                                 projection: model.accounts[tile.id].projection,
                                                 now: model.accounts[tile.id].scenario.now, kind: tile.kind,
                                                 status: model.status(for: tile.id),
                                                 prominent: model.layout.followsActivity && tile.id == model.primary,
                                                 inspecting: model.inspectedAccount != nil)
                                .frame(width: tile.frame.width, height: tile.frame.height)
                                .contentShape(Rectangle())
                                .onTapGesture { model.inspect(tile.id) }
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel(model.accounts[tile.id].title)
                                .accessibilityValue("\(Int(model.accounts[tile.id].scenario.snapshot.secondary?.usedPercent ?? 0)) percent weekly used. \(model.status(for: tile.id) ?? "")")
                                .accessibilityHint(model.inspectedAccount == nil ? "Show account detail" : "Use Back to return to all accounts")
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAction { model.inspect(tile.id) }
                                .offset(x: tile.frame.minX, y: tile.frame.minY)
                        }
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: model.primary)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: model.secondary)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .onHover { model.hovering = $0 }
        }
    }

    private func controls(width: CGFloat) -> some View {
        HStack(spacing: 8) {
            if model.inspectedAccount != nil || model.showingAbout {
                Button("Back") { model.back() }.buttonStyle(.bordered)
                    .accessibilityIdentifier("prototype.back")
                Spacer(minLength: 4)
            } else if width >= 460 {
                Picker("Simulated power mode", selection: $model.powerMode) {
                    Text("Off").tag(PowerSessionMode.off)
                    Text("Keep Mac awake").tag(PowerSessionMode.keepAwake)
                    Text("Keep screen on").tag(PowerSessionMode.keepAwakeDisplay)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 375)
                Spacer(minLength: 4)
            } else {
                Picker("Simulated power mode", selection: $model.powerMode) {
                    Text("Off").tag(PowerSessionMode.off)
                    Text("Mac awake").tag(PowerSessionMode.keepAwake)
                    Text("Screen on").tag(PowerSessionMode.keepAwakeDisplay)
                }
                .labelsHidden().frame(width: 124)
                Spacer(minLength: 4)
            }
            PrototypeMenuButton(model: model, setLayout: setLayout, close: close)
                .frame(width: 24, height: 24)
        }
        .font(.system(size: 12))
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
    }

    private func schematic(in size: CGSize) -> some View {
        let scaleX = size.width / model.previewSize.width
        let scaleY = size.height / model.previewSize.height
        return ZStack(alignment: .topLeading) {
            schematicTile(frame: CGRect(x: 12, y: 10, width: model.previewSize.width - 24, height: 24),
                          symbol: model.inspectedAccount == nil ? "switch.2" : "arrow.uturn.backward", scaleX: scaleX, scaleY: scaleY)
            if model.showingAbout {
                schematicTile(frame: CGRect(x: 12, y: 42, width: model.previewSize.width - 24, height: model.previewSize.height - 48),
                              symbol: "info.circle", scaleX: scaleX, scaleY: scaleY)
            } else {
                ForEach(model.tiles) { tile in
                    schematicTile(frame: tile.frame, symbol: tile.kind.symbol, scaleX: scaleX, scaleY: scaleY)
                }
            }
        }
        .accessibilityLabel("Resizing: \(model.layout.title)")
    }

    private func schematicTile(frame: CGRect, symbol: String, scaleX: CGFloat, scaleY: CGFloat) -> some View {
        let width = frame.width * scaleX
        let height = frame.height * scaleY
        return RoundedRectangle(cornerRadius: 5)
            .strokeBorder(Color.secondary.opacity(0.45), lineWidth: 1)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: min(30, max(12, height * 0.24)), weight: .light))
                    .foregroundStyle(.secondary)
            }
            .frame(width: width, height: height)
            .offset(x: frame.minX * scaleX, y: frame.minY * scaleY)
    }
}

private struct PrototypeMenuButton: NSViewRepresentable {
    let model: PrototypeModel
    let setLayout: (PrototypeLayout) -> Void
    let close: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: "line.3.horizontal.circle.fill", accessibilityDescription: "Prototype menu")!, target: context.coordinator, action: #selector(Coordinator.openMenu(_:)))
        button.isBordered = false
        button.toolTip = "Prototype menu"
        button.setAccessibilityIdentifier("prototype.menu")
        return button
    }
    func updateNSView(_ view: NSButton, context: Context) { context.coordinator.parent = self }
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor final class Coordinator: NSObject {
        var parent: PrototypeMenuButton
        init(_ parent: PrototypeMenuButton) { self.parent = parent }
        @objc func openMenu(_ sender: NSButton) {
            let model = parent.model
            model.menuOpen = true
            defer { model.menuOpen = false }
            let menu = NSMenu()
            menu.addItem(NSMenuItem(title: "Prototype · simulated accounts", action: nil, keyEquivalent: ""))
            menu.addItem(.separator())
            for count in 1...4 {
                let item = action("\(count) account\(count == 1 ? "" : "s")") { model.setCount(count) }
                item.state = model.count == count ? .on : .off
                menu.addItem(item)
            }
            menu.addItem(.separator())
            for scenario in PrototypeModel.Scenario.allCases {
                let item = action(scenario.rawValue) { model.scenario = scenario }
                item.state = model.scenario == scenario ? .on : .off
                menu.addItem(item)
            }
            menu.addItem(.separator())
            for layout in PrototypeLayout.allCases {
                let item = action(layout.title) { [parent] in parent.setLayout(layout) }
                item.state = model.layout == layout ? .on : .off
                menu.addItem(item)
            }
            menu.addItem(action("Restore Default Size") { [parent] in parent.setLayout(.gallery) })
            menu.addItem(.separator())
            menu.addItem(action("About") { model.showingAbout = true })
            menu.addItem(action("Close Window", parent.close))
            menu.addItem(action("Quit Prototype") { NSApp.terminate(nil) })
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
        }
        private func action(_ title: String, _ handler: @escaping () -> Void) -> NSMenuItem {
            PrototypeMenuItem(title: title, handler: handler)
        }
    }
}

@MainActor private final class PrototypeMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { handler() }
}
