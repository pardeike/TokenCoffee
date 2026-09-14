import AppKit
import Combine
import SwiftUI
import TokenCoffeeCore

private enum StatusPanelAction {
    case open
    case focus
    case close
}

@MainActor
final class StatusPanelController: NSObject, NSWindowDelegate {
    private let model: AppModel?
    private let prototype: DashboardLayoutState?
    private let linked: LinkedDashboardModel?
    private let statusItem: NSStatusItem
    private let panel: NSPanel
    private var cancellables: Set<AnyCancellable> = []
    private var shouldIgnoreNextExpandedInterfaceEnd = false
    private var pendingExpandedInterfaceAction: StatusPanelAction?
    private var panelWasFocused = false
    private var ignoreStatusItemActionUntil: Date?
    private var resizeStartFrame: NSRect?
    private var restoredPrototypeFrame = false
    private var applyingPrototypeSize = false
    private var managementController: ManagementWindowController?

    init(model: AppModel? = nil, prototype: PrototypeModel? = nil, linked: LinkedDashboardModel? = nil) {
        self.model = model ?? linked?.power
        self.prototype = prototype ?? linked?.geometry
        self.linked = linked
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.panel = PersistentPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 272),
            styleMask: prototype == nil && linked == nil ? [.borderless] : [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )

        super.init()

        if let button = statusItem.button {
            button.title = ""
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            updateStatusIcon(for: self.model?.powerMode ?? prototype?.powerMode ?? .off)
            button.target = self
            button.action = #selector(togglePanel)
            installExpandedInterfaceDelegateIfAvailable()
        }

        if let powerPublisher = self.model?.$powerMode ?? prototype?.$powerMode {
            powerPublisher
            .dropFirst()
            .sink { [weak self] mode in
                Task { @MainActor [weak self] in
                    self?.updateStatusIcon(for: mode)
                }
            }
            .store(in: &cancellables)
        }

        panel.delegate = self
        // Transparent rounded corners otherwise let clicks pass through even while
        // AppKit displays its native diagonal resize cursor over the window frame.
        panel.backgroundColor = self.prototype == nil ? .clear : NSColor.black.withAlphaComponent(0.01)
        panel.isOpaque = false
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if let model {
            panel.contentView = NSHostingView(rootView: DashboardView(
            model: model,
            closeWindow: { [weak self] in
                self?.closePanel()
            },
            showAbout: {
                Self.showAboutPanel()
            }
            ))
        } else if let geometry = self.prototype {
            panel.title = linked == nil ? "Token Coffee Prototype" : "Token Coffee"
            panel.contentMinSize = PrototypeLayout.pocket.size
            let root: AnyView
            if let linked {
                root = AnyView(LinkedDashboardView(model: linked, geometry: geometry,
                    setLayout: { [weak self] layout in self?.applyPrototypeLayout(layout) },
                    showManagement: { [weak self] section in self?.showManagement(section) },
                    close: { [weak self] in self?.closePanel() }))
            } else if let prototype {
                root = AnyView(PrototypeDashboardView(model: prototype,
                    setLayout: { [weak self] layout in self?.applyPrototypeLayout(layout) },
                    close: { [weak self] in self?.closePanel() }))
            } else { root = AnyView(EmptyView()) }
            let hosting = NSHostingView(rootView: root)
            hosting.sizingOptions = []
            let content = NSView(frame: NSRect(origin: .zero, size: panel.frame.size))
            hosting.frame = content.bounds
            hosting.autoresizingMask = [.width, .height]
            content.addSubview(hosting)
            let corners = PrototypeResizeCorners(frame: content.bounds)
            corners.autoresizingMask = [.width, .height]
            corners.begin = { [weak self] in
                self?.windowWillStartLiveResize(Notification(name: NSWindow.willStartLiveResizeNotification))
            }
            corners.end = { [weak self] in
                self?.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification))
            }
            content.addSubview(corners)
            panel.contentView = content
            restorePrototypeFrame()
            geometry.$count.dropFirst().sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, let prototype = self.prototype else { return }
                    if self.linked != nil {
                        let result = PrototypeLayout.resolveCountChange(self.panel.frame.size,
                            retaining: prototype.layout, count: prototype.count, fitting: self.availablePrototypeSize)
                        self.applyPrototypeLayout(result.layout, proposedSize: result.size)
                    } else {
                        self.applyPrototypeLayout(prototype.layout, proposedSize: self.panel.frame.size)
                    }
                }
            }.store(in: &cancellables)
        }
    }

    func showPrototype() { if prototype != nil { openPanel() } }
    func showDashboard() { openPanel() }

    private func showManagement(_ section: ManagementSection) {
        guard let linked else { return }
        if managementController == nil { managementController = ManagementWindowController(model: linked) }
        managementController?.show(section)
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        guard let prototype else { return }
        resizeStartFrame = panel.frame
        prototype.previewSize = prototype.windowSize
        prototype.resizing = true
    }

    func windowDidResize(_ notification: Notification) {
        guard let prototype, !applyingPrototypeSize else { return }
        guard panel.inLiveResize || prototype.resizing else {
            applyPrototypeLayout(prototype.layout, proposedSize: panel.frame.size)
            return
        }
        let resolution = PrototypeLayout.resolve(panel.frame.size, retaining: prototype.layout, count: prototype.count,
                                                 fitting: availablePrototypeSize)
        prototype.layout = resolution.layout
        prototype.previewSize = resolution.size
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let prototype else { return }
        applyPrototypeLayout(prototype.layout, proposedSize: panel.frame.size)
        prototype.resizing = false
        resizeStartFrame = nil
    }

    func windowDidMove(_ notification: Notification) {
        guard prototype != nil, !panel.inLiveResize, !applyingPrototypeSize else { return }
        savePrototypeFrame()
    }

    private var availablePrototypeSize: CGSize {
        let frame = (panel.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 900)
        return CGSize(width: frame.width - 16, height: frame.height - 16)
    }

    private func applyPrototypeLayout(_ requested: PrototypeLayout, proposedSize: CGSize? = nil) {
        guard let prototype else { return }
        let resolution = PrototypeLayout.resolve(proposedSize ?? requested.size, retaining: requested,
                                                 count: prototype.count, fitting: availablePrototypeSize)
        var frame = panel.frame
        let anchor = resizeStartFrame ?? frame
        let resizingLeft = resizeStartFrame != nil && abs(frame.minX - anchor.minX) > 1
        let resizingTop = resizeStartFrame != nil && abs(frame.maxY - anchor.maxY) > 1
        let oldMaxX = frame.maxX
        let oldMaxY = frame.maxY
        frame.size = resolution.size
        if resizingLeft { frame.origin.x = oldMaxX - frame.width }
        if !resizingTop { frame.origin.y = oldMaxY - frame.height }
        if let visible = (panel.screen ?? NSScreen.main)?.visibleFrame {
            frame.origin.x = min(max(frame.minX, visible.minX + 8), visible.maxX - frame.width - 8)
            frame.origin.y = min(max(frame.minY, visible.minY + 8), visible.maxY - frame.height - 8)
        }
        applyingPrototypeSize = true
        prototype.layout = resolution.layout
        prototype.windowSize = frame.size
        prototype.previewSize = frame.size
        panel.setFrame(frame, display: true, animate: false)
        applyingPrototypeSize = false
        savePrototypeFrame()
    }

    private func savePrototypeFrame() {
        restoredPrototypeFrame = true
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: framePrefix + ".windowFrame")
        UserDefaults.standard.set(prototype?.layout.rawValue, forKey: framePrefix + ".layout")
    }

    private var framePrefix: String { linked == nil ? "prototype" : "linkedDashboard" }

    private func restorePrototypeFrame() {
        guard let prototype,
              let name = UserDefaults.standard.string(forKey: framePrefix + ".layout"),
              let layout = PrototypeLayout(rawValue: name),
              let saved = UserDefaults.standard.string(forKey: framePrefix + ".windowFrame") else { return }
        let frame = NSRectFromString(saved)
        guard frame.width.isFinite, frame.height.isFinite, frame.minX.isFinite, frame.minY.isFinite,
              frame.width > 0, frame.height > 0 else { return }
        applyingPrototypeSize = true
        panel.setFrame(frame, display: false)
        applyingPrototypeSize = false
        prototype.layout = layout
        restoredPrototypeFrame = true
        applyPrototypeLayout(layout, proposedSize: frame.size)
    }

    @objc private func togglePanel() {
        if shouldIgnoreStatusItemAction() {
            return
        }

        togglePanelFromStatusItem()

        if let expandedInterfaceSession = currentExpandedInterfaceSession() {
            cancelExpandedInterfaceSession(expandedInterfaceSession)
        }
    }

    private func togglePanelFromStatusItem() {
        performPanelAction(panelActionForStatusItem())
    }

    private func panelActionForStatusItem() -> StatusPanelAction {
        guard panel.isVisible else {
            return .open
        }
        return panelWasFocused ? .close : .focus
    }

    private func performPanelAction(_ action: StatusPanelAction) {
        switch action {
        case .open:
            openPanel()
        case .focus:
            focusPanel()
        case .close:
            closePanelWithoutCancellingStatusItem()
        }
    }

    func windowWillClose(_ notification: Notification) {
        panelWasFocused = false
        model?.setPanelVisible(false)
        prototype?.visible = false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        panelWasFocused = true
    }

    func windowDidResignKey(_ notification: Notification) {
        if isStatusItemInteractionInProgress {
            return
        }
        panelWasFocused = false
    }

    private var isStatusItemInteractionInProgress: Bool {
        guard let button = statusItem.button else {
            return false
        }
        if button.isHighlighted {
            return true
        }
        if NSEvent.pressedMouseButtons & 1 != 0,
           let buttonWindow = button.window {
            let buttonFrameInWindow = button.convert(button.bounds, to: nil)
            let buttonFrameOnScreen = buttonWindow.convertToScreen(buttonFrameInWindow)
            if buttonFrameOnScreen.contains(NSEvent.mouseLocation) {
                return true
            }
        }
        return false
    }

    private func closePanel() {
        if let expandedInterfaceSession = currentExpandedInterfaceSession() {
            cancelExpandedInterfaceSession(expandedInterfaceSession)
        }

        closePanelWithoutCancellingStatusItem()
    }

    private func openPanel() {
        if prototype == nil || !restoredPrototypeFrame { positionPanel() }
        focusPanel()
        model?.setPanelVisible(true)
        prototype?.visible = true
    }

    private func focusPanel() {
        panelWasFocused = true
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func closePanelWithoutCancellingStatusItem() {
        panelWasFocused = false
        panel.orderOut(nil)
        model?.setPanelVisible(false)
        prototype?.visible = false
    }

    private func installExpandedInterfaceDelegateIfAvailable() {
        let selector = NSSelectorFromString("setExpandedInterfaceDelegate:")
        guard statusItem.responds(to: selector) else {
            return
        }

        statusItem.setValue(self, forKey: "expandedInterfaceDelegate")
    }

    private func currentExpandedInterfaceSession() -> NSObject? {
        let selector = NSSelectorFromString("expandedInterfaceSession")
        guard statusItem.responds(to: selector) else {
            return nil
        }

        return statusItem.value(forKey: "expandedInterfaceSession") as? NSObject
    }

    private func cancelExpandedInterfaceSession(_ expandedInterfaceSession: NSObject) {
        shouldIgnoreNextExpandedInterfaceEnd = true
        let selector = NSSelectorFromString("cancel")
        if expandedInterfaceSession.responds(to: selector) {
            _ = expandedInterfaceSession.perform(selector)
        }
        clearStatusItemHighlight()
        DispatchQueue.main.async { [weak self] in
            self?.clearStatusItemHighlight()
        }
    }

    private func clearStatusItemHighlight() {
        statusItem.button?.highlight(false)
    }

    private func suppressStatusItemActionFallback() {
        let deadline = Date().addingTimeInterval(0.25)
        ignoreStatusItemActionUntil = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard self?.ignoreStatusItemActionUntil == deadline else {
                return
            }
            self?.ignoreStatusItemActionUntil = nil
        }
    }

    private func shouldIgnoreStatusItemAction() -> Bool {
        guard let deadline = ignoreStatusItemActionUntil else {
            return false
        }

        if Date() < deadline {
            return true
        }

        ignoreStatusItemActionUntil = nil
        return false
    }

    private static func showAboutPanel() {
        let options: [NSApplication.AboutPanelOptionKey: Any] = [
            .credits: aboutCredits()
        ]

        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    private static func aboutCredits() -> NSAttributedString {
        let text = NSMutableAttributedString()
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraphStyle
        ]

        append(
            "Token Coffee is an independent utility for viewing Codex quota status.\n",
            to: text,
            attributes: baseAttributes
        )
        append(
            "Copyright Andreas Pardeike\n",
            to: text,
            attributes: baseAttributes
        )
        append(
            "Codex is not a product of Andreas Pardeike.\n\n",
            to: text,
            attributes: baseAttributes
        )
        append("Support: ", to: text, attributes: baseAttributes)
        append(
            "https://github.com/pardeike/TokenCoffee/blob/main/SUPPORT.md\n\n",
            to: text,
            attributes: linkAttributes(
                url: URL(string: "https://github.com/pardeike/TokenCoffee/blob/main/SUPPORT.md")!,
                baseAttributes: baseAttributes
            )
        )
        append("Privacy Policy: ", to: text, attributes: baseAttributes)
        append(
            "https://github.com/pardeike/TokenCoffee/blob/main/PRIVACY.md",
            to: text,
            attributes: linkAttributes(
                url: URL(string: "https://github.com/pardeike/TokenCoffee/blob/main/PRIVACY.md")!,
                baseAttributes: baseAttributes
            )
        )

        return text
    }

    private static func append(
        _ string: String,
        to text: NSMutableAttributedString,
        attributes: [NSAttributedString.Key: Any]
    ) {
        text.append(NSAttributedString(string: string, attributes: attributes))
    }

    private static func linkAttributes(
        url: URL,
        baseAttributes: [NSAttributedString.Key: Any]
    ) -> [NSAttributedString.Key: Any] {
        var attributes = baseAttributes
        attributes[.link] = url
        attributes[.foregroundColor] = NSColor.linkColor
        attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        return attributes
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
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = isActive ? "Keeping awake" : "Idle"
    }
}

extension StatusPanelController {
    @objc(statusItem:didBeginExpandedInterfaceSession:)
    func statusItem(
        _ statusItem: NSStatusItem,
        didBeginExpandedInterfaceSession expandedInterfaceSession: NSObject
    ) {
        suppressStatusItemActionFallback()
        pendingExpandedInterfaceAction = panelActionForStatusItem()
        cancelExpandedInterfaceSession(expandedInterfaceSession)
    }

    @objc(statusItemDidEndExpandedInterfaceSession:animated:)
    func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) {
        if shouldIgnoreNextExpandedInterfaceEnd {
            shouldIgnoreNextExpandedInterfaceEnd = false
            if let action = pendingExpandedInterfaceAction {
                pendingExpandedInterfaceAction = nil
                DispatchQueue.main.async { [weak self] in
                    self?.performPanelAction(action)
                }
            }
            return
        }

        pendingExpandedInterfaceAction = nil
        closePanelWithoutCancellingStatusItem()
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
