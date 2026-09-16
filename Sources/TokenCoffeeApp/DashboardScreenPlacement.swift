import AppKit
import ColorSync

/// Frames are relative to the display, so rearranging monitors preserves placement.
struct DashboardScreenPlacement {
    let frame: NSRect
    let layout: PrototypeLayout

    init(frame: NSRect, layout: PrototypeLayout) {
        self.frame = frame
        self.layout = layout
    }

    init?(defaults: UserDefaults, key: String, screenFrame: NSRect) {
        guard let saved = defaults.dictionary(forKey: key),
              let rect = saved["frame"] as? String,
              let name = saved["layout"] as? String,
              let layout = PrototypeLayout(rawValue: name) else { return nil }
        let relative = NSRectFromString(rect)
        guard relative.minX.isFinite, relative.minY.isFinite,
              relative.width.isFinite, relative.height.isFinite,
              relative.width > 0, relative.height > 0 else { return nil }
        self.frame = relative.offsetBy(dx: screenFrame.minX, dy: screenFrame.minY)
        self.layout = layout
    }

    func save(defaults: UserDefaults, key: String, screenFrame: NSRect) {
        let relative = frame.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
        defaults.set(["frame": NSStringFromRect(relative), "layout": layout.rawValue], forKey: key)
    }

    func fitted(to visibleFrame: NSRect, count: Int) -> DashboardScreenPlacement {
        let resolution = PrototypeLayout.resolve(frame.size, retaining: layout, count: count,
            fitting: CGSize(width: visibleFrame.width - 16, height: visibleFrame.height - 16))
        var fitted = NSRect(origin: frame.origin, size: resolution.size)
        fitted.origin.x = min(max(fitted.minX, visibleFrame.minX + 8), visibleFrame.maxX - fitted.width - 8)
        fitted.origin.y = min(max(fitted.minY, visibleFrame.minY + 8), visibleFrame.maxY - fitted.height - 8)
        return DashboardScreenPlacement(frame: fitted, layout: resolution.layout)
    }

    static func topRight(size: CGSize, layout: PrototypeLayout, visibleFrame: NSRect, count: Int) -> DashboardScreenPlacement {
        let fitted = DashboardScreenPlacement(frame: NSRect(origin: .zero, size: size), layout: layout)
            .fitted(to: visibleFrame, count: count)
        return DashboardScreenPlacement(frame: NSRect(
            x: visibleFrame.maxX - fitted.frame.width - 8,
            y: visibleFrame.maxY - fitted.frame.height - 8,
            width: fitted.frame.width, height: fitted.frame.height), layout: fitted.layout)
    }

    @MainActor static func identifier(for screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
