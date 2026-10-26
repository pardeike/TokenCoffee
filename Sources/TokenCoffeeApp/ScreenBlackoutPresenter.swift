import AppKit
import CoreGraphics

@MainActor
protocol ScreenBlackoutPresenting: AnyObject {
    var isVisible: Bool { get }
    var onDismiss: (() -> Void)? { get set }
    func show()
    func hide()
}

@MainActor
final class ScreenBlackoutPresenter: ScreenBlackoutPresenting {
    private(set) var isVisible = false
    var onDismiss: (() -> Void)?
    private var windows: [NSWindow] = []
    private var inputMonitor: Any?
    private var previousApplication: NSRunningApplication?

    func show() {
        guard !isVisible else { return }
        previousApplication = NSWorkspace.shared.frontmostApplication
        if let screen = NSScreen.screens.max(by: { $0.frame.maxX < $1.frame.maxX }) {
            let bounds = screen.frame
            CGWarpMouseCursorPosition(CGPoint(x: bounds.maxX - 1, y: bounds.maxY - 1))
        }
        isVisible = true
        windows = NSScreen.screens.map { screen in
            let window = ScreenBlackoutWindow(contentRect: screen.frame, styleMask: [.borderless],
                                             backing: .buffered, defer: false, screen: screen)
            window.backgroundColor = .black
            window.isOpaque = true
            window.hasShadow = false
            window.acceptsMouseMovedEvents = true
            window.hidesOnDeactivate = false
            window.animationBehavior = .none
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.orderFrontRegardless()
            return window
        }
        windows.first?.makeKey()
        NSApp.activate()
        // The cover owns the next input event. It needs no global keyboard monitor
        // and consumes the event that uncovers the desktop, like display wake.
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown,
            .otherMouseDown, .mouseMoved, .scrollWheel
        ]) { [weak self] _ in
            guard let self, self.isVisible else { return nil }
            self.hide()
            self.onDismiss?()
            return nil
        }
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor); self.inputMonitor = nil }
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        if let previousApplication, previousApplication.processIdentifier != getpid(), !previousApplication.isTerminated {
            previousApplication.activate(options: [])
        }
        previousApplication = nil
    }
}

private final class ScreenBlackoutWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
