import AppKit
import Combine
import SwiftUI
import TokenCoffeeCore

@MainActor
final class StatusPanelController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let statusItem: NSStatusItem
    private let panel: NSPanel
    private var cancellables: Set<AnyCancellable> = []

    init(model: AppModel) {
        self.model = model
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.panel = PersistentPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 272),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        super.init()

        if let button = statusItem.button {
            button.title = ""
            button.imagePosition = .imageOnly
            updateStatusIcon(for: model.powerMode)
            button.target = self
            button.action = #selector(togglePanel)
        }

        model.$powerMode
            .dropFirst()
            .sink { [weak self] mode in
                Task { @MainActor [weak self] in
                    self?.updateStatusIcon(for: mode)
                }
            }
            .store(in: &cancellables)

        panel.delegate = self
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: DashboardView(model: model))
    }

    @objc private func togglePanel() {
        if panel.isVisible {
            panel.orderOut(nil)
            model.setPanelVisible(false)
        } else {
            positionPanel()
            NSApp.activate()
            panel.makeKeyAndOrderFront(nil)
            model.setPanelVisible(true)
        }
    }

    func windowWillClose(_ notification: Notification) {
        model.setPanelVisible(false)
    }

    private func positionPanel() {
        guard let button = statusItem.button,
              let buttonWindow = button.window,
              let screen = buttonWindow.screen ?? NSScreen.main else {
            panel.center()
            return
        }

        let buttonFrameInWindow = button.convert(button.bounds, to: nil)
        let buttonFrameOnScreen = buttonWindow.convertToScreen(buttonFrameInWindow)
        let panelSize = panel.frame.size
        let visibleFrame = screen.visibleFrame
        let proposedX = buttonFrameOnScreen.midX - panelSize.width / 2
        let x = min(max(proposedX, visibleFrame.minX + 8), visibleFrame.maxX - panelSize.width - 8)
        let y = buttonFrameOnScreen.minY - panelSize.height - 8
        panel.setFrameOrigin(NSPoint(x: x, y: max(y, visibleFrame.minY + 8)))
    }

    private func updateStatusIcon(for mode: PowerSessionMode) {
        guard let button = statusItem.button else {
            return
        }

        let isActive = mode != .off
        button.title = ""
        button.image = StatusItemIcon.makeImage(isActive: isActive)
        button.imagePosition = .imageOnly
        button.toolTip = isActive ? "Keeping awake" : "Idle"
    }
}

private enum StatusItemIcon {
    private static let imageSize = NSSize(width: 22, height: 18)

    static func makeImage(isActive: Bool) -> NSImage {
        let imageName = isActive ? "StatusIconOn" : "StatusIconOff"
        if let source = NSImage(named: NSImage.Name(imageName)),
           let image = source.copy() as? NSImage {
            image.isTemplate = true
            image.size = imageSize
            return image
        }

        if let fallback = NSImage(
            systemSymbolName: isActive ? "cup.and.saucer.fill" : "cup.and.saucer",
            accessibilityDescription: nil
        ) {
            fallback.isTemplate = true
            fallback.size = imageSize
            return fallback
        }

        let empty = NSImage(size: imageSize)
        empty.isTemplate = true
        return empty
    }
}

private final class PersistentPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
