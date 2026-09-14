import CoreGraphics
import Foundation

enum AccountWindowFrame {
    static func restore(_ saved: CGRect, visibleScreens: [CGRect]) -> CGRect? {
        guard [saved.origin.x, saved.origin.y, saved.width, saved.height].allSatisfy(\.isFinite),
              saved.width > 0, saved.height > 0, let fallback = visibleScreens.first else { return nil }
        let screen = visibleScreens.max { left, right in
            area(saved.intersection(left)) < area(saved.intersection(right))
        }.flatMap { saved.intersects($0) ? $0 : nil } ?? fallback
        var frame = saved
        frame.size.width = min(max(saved.width, 510), screen.width)
        frame.size.height = min(max(saved.height, 342), screen.height)
        frame.origin.x = min(max(saved.minX, screen.minX), screen.maxX - frame.width)
        frame.origin.y = min(max(saved.minY, screen.minY), screen.maxY - frame.height)
        return frame
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }
}
