import Foundation

enum PrototypeLayout: String, CaseIterable, Identifiable {
    case pocket, strip, gallery, lanes, overview, tallOverview

    var id: String { rawValue }
    var title: String {
        switch self {
        case .pocket: "Pocket"
        case .strip: "Strip"
        case .gallery: "Gallery"
        case .lanes: "Lanes"
        case .overview: "Overview"
        case .tallOverview: "Tall overview"
        }
    }
    var size: CGSize {
        switch self {
        case .pocket: CGSize(width: 280, height: 144)
        case .strip: CGSize(width: 880, height: 144)
        case .gallery: CGSize(width: 480, height: 272)
        case .lanes: CGSize(width: 320, height: 560)
        case .overview: CGSize(width: 640, height: 480)
        case .tallOverview: CGSize(width: 320, height: 820)
        }
    }
    var followsActivity: Bool { self == .gallery || self == .lanes }

    struct Resolution {
        let layout: PrototypeLayout
        let size: CGSize
    }

    /// An edited chart count is not a resize gesture. Keep the chosen chart style
    /// and grow to its minimums before considering another arrangement.
    static func resolveCountChange(_ proposed: CGSize, retaining current: Self, count: Int,
                                   fitting screen: CGSize) -> Resolution {
        if let size = current.fittedSize(proposed, count: count, screen: screen) {
            return Resolution(layout: current, size: size)
        }
        return resolve(proposed, retaining: current, count: count, fitting: screen)
    }

    static func resolve(_ proposed: CGSize, retaining current: Self, count: Int,
                        fitting screen: CGSize) -> Resolution {
        let options = allCases.compactMap { layout -> Resolution? in
            layout.fittedSize(proposed, count: count, screen: screen).map { Resolution(layout: layout, size: $0) }
        }
        // Keep a usable arrangement. Size alone is not a reason to replace it.
        // A roughly 2% boundary margin prevents tiny drags from flipping arrangements.
        if let retained = options.first(where: { $0.layout == current }), distance(retained.size, proposed) < 0.0004 {
            return retained
        }
        let fitting = options.filter { distance($0.size, proposed) < 0.000001 }
        if let best = fitting.min(by: { distance($0.layout.size, proposed) < distance($1.layout.size, proposed) }) {
            return best
        }
        // When nothing fits exactly, correct as little as possible in proportional dimensions.
        return options.min { distance($0.size, proposed) < distance($1.size, proposed) }
            ?? Resolution(layout: .pocket, size: CGSize(width: min(280, screen.width), height: min(144, screen.height)))
    }

    private static func distance(_ a: CGSize, _ b: CGSize) -> CGFloat {
        pow((a.width - b.width) / max(1, b.width), 2) + pow((a.height - b.height) / max(1, b.height), 2)
    }

    // Tile widths/heights are affine functions of window dimensions. Their minimum
    // sizes and aspect bounds form half-planes; intersect them with the screen bounds.
    // This finds the nearest usable size without a search grid or iterative resize loop.
    func fittedSize(_ proposed: CGSize, count: Int, screen: CGSize) -> CGSize? {
        var polygon = [CGPoint(x: 280, y: 144), CGPoint(x: screen.width, y: 144),
                       CGPoint(x: screen.width, y: screen.height), CGPoint(x: 280, y: screen.height)]
        guard screen.width >= 280, screen.height >= 144 else { return nil }
        var acceptsProposed = proposed.width >= 280 && proposed.height >= 144
            && proposed.width <= screen.width && proposed.height <= screen.height
        func clip(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat) {
            if a * proposed.width + b * proposed.height > c + 0.00001 { acceptsProposed = false }
            guard !polygon.isEmpty else { return }
            var output: [CGPoint] = []
            var previous = polygon.last!
            var previousValue = a * previous.x + b * previous.y - c
            for point in polygon {
                let value = a * point.x + b * point.y - c
                if (value <= 0) != (previousValue <= 0) {
                    let t = previousValue / (previousValue - value)
                    output.append(CGPoint(x: previous.x + t * (point.x - previous.x),
                                          y: previous.y + t * (point.y - previous.y)))
                }
                if value <= 0 { output.append(point) }
                previous = point
                previousValue = value
            }
            polygon = output
        }
        let reference = tiles(count: count, primary: 0, secondary: count > 1 ? 1 : 0)
        let small = tiles(count: count, primary: 0, secondary: count > 1 ? 1 : 0, in: CGSize(width: 1000, height: 1000))
        let large = tiles(count: count, primary: 0, secondary: count > 1 ? 1 : 0, in: CGSize(width: 2000, height: 2000))
        for index in reference.indices {
            let w = (large[index].frame.width - small[index].frame.width) / 1000
            let h = (large[index].frame.height - small[index].frame.height) / 1000
            let x = small[index].frame.width - w * 1000
            let y = small[index].frame.height - h * 1000
            let kind = reference[index].kind
            let minimum = kind.minimumSize
            let minAspect = kind.aspectRange.lowerBound
            let maxAspect = kind.aspectRange.upperBound
            clip(-w, 0, x - minimum.width)
            clip(0, -h, y - minimum.height)
            clip(-w, minAspect * h, x - minAspect * y)
            clip(w, -maxAspect * h, maxAspect * y - x)
            if self == .pocket { clip(0, h, 110 - y) }
        }
        guard !polygon.isEmpty else { return nil }
        let target = CGPoint(x: proposed.width, y: proposed.height)
        if acceptsProposed { return proposed }
        let sx = max(1, proposed.width), sy = max(1, proposed.height)
        let nearest = polygon.indices.map { index -> CGSize in
            let a = polygon[index], b = polygon[(index + 1) % polygon.count]
            let dx = (b.x - a.x) / sx, dy = (b.y - a.y) / sy
            let denominator = dx * dx + dy * dy
            let t = denominator > 0 ? min(1, max(0, ((target.x - a.x) / sx * dx + (target.y - a.y) / sy * dy) / denominator)) : 0
            return CGSize(width: a.x + t * (b.x - a.x), height: a.y + t * (b.y - a.y))
        }.min { Self.distance($0, proposed) < Self.distance($1, proposed) }!
        return nearest
    }

    func tiles(count: Int, primary: Int, secondary: Int, detail: Int? = nil, in availableSize: CGSize? = nil) -> [PrototypeTile] {
        let count = min(6, max(1, count))
        let size = availableSize ?? size
        let area = CGRect(x: 12, y: 42, width: size.width - 24, height: size.height - 48)
        if let detail {
            return [PrototypeTile(id: detail, frame: area, kind: .detail)]
        }
        if count == 1 { return [PrototypeTile(id: 0, frame: area, kind: self == .pocket || self == .strip ? .preview : .detail)] }
        let primary = min(max(0, primary), count - 1)
        let secondary = min(max(0, secondary), count - 1)
        switch self {
        case .strip:
            return divided(area, indices: Array(0..<count), horizontal: true, kind: .preview)
        case .pocket:
            if count == 2 { return divided(area, indices: [0, 1], horizontal: true, kind: .micro) }
            let top = CGRect(x: area.minX, y: area.minY, width: area.width, height: (area.height - 8) / 2)
            let bottom = top.offsetBy(dx: 0, dy: top.height + 8)
            let split = (count + 1) / 2
            return divided(top, indices: Array(0..<split), horizontal: true, kind: .micro)
                + divided(bottom, indices: Array(split..<count), horizontal: true, kind: .micro)
        case .gallery:
            let width = (area.width - 8) * 2 / 3
            let main = CGRect(x: area.minX, y: area.minY, width: width, height: area.height)
            let side = CGRect(x: main.maxX + 8, y: area.minY, width: area.width - width - 8, height: area.height)
            let peers = (0..<count).filter { $0 != primary }
            return [PrototypeTile(id: primary, frame: main, kind: .detail)]
                + weighted(side, indices: peers, weights: peers.map { $0 == secondary ? 2 : 1 }, primary: -1)
        case .lanes:
            let indices = Array(0..<count)
            return weighted(area, indices: indices, weights: indices.map { $0 == primary ? 4 : ($0 == secondary ? 2 : 1) }, primary: primary)
        case .overview:
            if count >= 5 {
                let row = CGRect(x: area.minX, y: area.minY, width: area.width, height: (area.height - 16) / 3)
                let firstCount = count == 5 ? 1 : 2
                return divided(row, indices: Array(0..<firstCount), horizontal: true, kind: .detail)
                    + divided(row.offsetBy(dx: 0, dy: row.height + 8), indices: Array(firstCount..<(firstCount + 2)), horizontal: true, kind: .detail)
                    + divided(row.offsetBy(dx: 0, dy: 2 * (row.height + 8)), indices: Array((firstCount + 2)..<count), horizontal: true, kind: .detail)
            }
            if count == 2 { return divided(area, indices: [0, 1], horizontal: true, kind: .detail) }
            if count == 3 { return divided(area, indices: [0, 1, 2], horizontal: false, kind: .detail) }
            let top = CGRect(x: area.minX, y: area.minY, width: area.width, height: (area.height - 8) / 2)
            return divided(top, indices: [0, 1], horizontal: true, kind: .detail)
                + divided(top.offsetBy(dx: 0, dy: top.height + 8), indices: [2, 3], horizontal: true, kind: .detail)
        case .tallOverview:
            return divided(area, indices: Array(0..<count), horizontal: false, kind: .detail)
        }
    }

    private func divided(_ area: CGRect, indices: [Int], horizontal: Bool, kind: PrototypeTile.Kind) -> [PrototypeTile] {
        let length = ((horizontal ? area.width : area.height) - CGFloat(indices.count - 1) * 8) / CGFloat(indices.count)
        return indices.enumerated().map { offset, id in
            let frame = horizontal
                ? CGRect(x: area.minX + CGFloat(offset) * (length + 8), y: area.minY, width: length, height: area.height)
                : CGRect(x: area.minX, y: area.minY + CGFloat(offset) * (length + 8), width: area.width, height: length)
            return PrototypeTile(id: id, frame: frame, kind: kind)
        }
    }

    private func weighted(_ area: CGRect, indices: [Int], weights: [CGFloat], primary: Int) -> [PrototypeTile] {
        let unit = (area.height - CGFloat(indices.count - 1) * 8) / weights.reduce(0, +)
        var y = area.minY
        return zip(indices, weights).map { id, weight in
            let height = unit * weight
            defer { y += height + 8 }
            return PrototypeTile(id: id, frame: CGRect(x: area.minX, y: y, width: area.width, height: height),
                                 kind: id == primary ? .detail : (weight >= 2 ? .preview : .micro))
        }
    }
}

struct PrototypeTile: Identifiable {
    enum Kind {
        case micro, preview, detail
        var minimumSize: CGSize {
            switch self {
            case .micro: CGSize(width: 120, height: 44)
            case .preview: CGSize(width: 120, height: 80)
            case .detail: CGSize(width: 220, height: 120)
            }
        }
        var aspectRange: ClosedRange<CGFloat> {
            switch self {
            case .micro: 1...12
            case .preview: 1...6
            case .detail: 1.05...5
            }
        }
        var symbol: String {
            switch self {
            case .micro: "percent"
            case .preview: "waveform.path"
            case .detail: "chart.xyaxis.line"
            }
        }
    }
    let id: Int
    let frame: CGRect
    let kind: Kind
}
