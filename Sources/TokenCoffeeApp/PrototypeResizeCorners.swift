import AppKit

/// Native resizing still handles the straight edges. These hit targets cover the
/// rounded corners where AppKit can show a resize cursor without starting a drag.
@MainActor
final class PrototypeResizeCorners: NSView {
    var begin: (() -> Void)?
    var end: (() -> Void)?
    private var drag: (frame: NSRect, mouse: NSPoint, left: Bool, bottom: Bool)?
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let pan = CornerPanGestureRecognizer(target: self, action: #selector(resize(_:)))
        pan.buttonMask = 1
        addGestureRecognizer(pan)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var corners: [(CGRect, Bool, Bool, NSCursor.FrameResizePosition)] {
        let side: CGFloat = 14
        return [
            (CGRect(x: 0, y: 0, width: side, height: side), true, true, .bottomLeft),
            (CGRect(x: bounds.width - side, y: 0, width: side, height: side), false, true, .bottomRight),
            (CGRect(x: 0, y: bounds.height - side, width: side, height: side), true, false, .topLeft),
            (CGRect(x: bounds.width - side, y: bounds.height - side, width: side, height: side), false, false, .topRight)
        ]
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return corners.contains { $0.0.contains(local) } ? self : nil
    }

    override func resetCursorRects() {
        for (rect, _, _, position) in corners {
            addCursorRect(rect, cursor: .frameResize(position: position, directions: .all))
        }
    }

    @objc private func resize(_ pan: CornerPanGestureRecognizer) {
        guard let window else { return }
        if pan.state == .began {
            guard let (_, left, bottom, _) = corners.first(where: { $0.0.contains(pan.startInView) }) else { return }
            drag = (window.frame, pan.startOnScreen, left, bottom)
            begin?()
        }
        guard let drag else { return }
        if pan.state == .began || pan.state == .changed || pan.state == .ended {
            let mouse = NSEvent.mouseLocation
            let dx = mouse.x - drag.mouse.x, dy = mouse.y - drag.mouse.y
            let width = max(window.minSize.width, drag.frame.width + (drag.left ? -dx : dx))
            let height = max(window.minSize.height, drag.frame.height + (drag.bottom ? -dy : dy))
            window.setFrame(NSRect(x: drag.left ? drag.frame.maxX - width : drag.frame.minX,
                                   y: drag.bottom ? drag.frame.maxY - height : drag.frame.minY,
                                   width: width, height: height), display: true)
        }
        if pan.state == .ended || pan.state == .cancelled || pan.state == .failed {
            self.drag = nil
            end?()
            window.invalidateCursorRects(for: self)
        }
    }
}

@MainActor private final class CornerPanGestureRecognizer: NSPanGestureRecognizer {
    var startInView = NSPoint.zero
    var startOnScreen = NSPoint.zero

    override func mouseDown(with event: NSEvent) {
        // Recognition begins after movement. Capture the actual down location so a
        // fast first movement outside the small corner doesn't reject the gesture.
        startInView = view?.convert(event.locationInWindow, from: nil) ?? .zero
        startOnScreen = NSEvent.mouseLocation
        super.mouseDown(with: event)
    }
}
