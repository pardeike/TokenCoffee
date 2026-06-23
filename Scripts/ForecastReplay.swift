import AppKit
import Foundation
import ImageIO
import TokenCoffeeCore
import UniformTypeIdentifiers

private struct Options {
    var samplesPath = "/Users/ap/Library/Containers/com.pardeike.TokenCoffee/Data/Library/Application Support/TokenCoffee/quota-samples.jsonl"
    var outputPath: String?
    var stepHours = 4.0
    var width = 1200
    var height = 700
}

private struct ReplayWindow {
    let limitId: String
    let limitName: String?
    let planType: String?
    let startDate: Date
    let resetDate: Date
    let latestDate: Date
    let windowMinutes: Int
    let samples: [QuotaSample]
}

private struct ReplayFrame {
    let index: Int
    let checkpoint: Date
    let currentSample: QuotaSample
    let knownSamples: [QuotaSample]
    let projection: QuotaProjection

    var currentPercent: Double {
        currentSample.weeklyUsedPercent
    }
}

private struct Point {
    let date: Date
    let usedPercent: Double
}

private struct HotRun {
    let startDate: Date
    let endDate: Date
}

private enum ReplayError: Error, CustomStringConvertible {
    case usage(String)
    case noSamples(URL)
    case noCurrentWindow
    case noFrames
    case imageEncoding(URL, String)

    var description: String {
        switch self {
        case .usage(let message):
            return message
        case .noSamples(let url):
            return "No quota samples could be loaded from \(url.path)."
        case .noCurrentWindow:
            return "Could not find a current weekly quota window in the sample file."
        case .noFrames:
            return "The current window has no usable 4-hour replay checkpoints."
        case .imageEncoding(let url, let stage):
            return "Could not encode PNG at \(url.path) (\(stage))."
        }
    }
}

private final class ReplayRenderer {
    private let width: CGFloat
    private let height: CGFloat
    private let chartRect: CGRect
    private let yMaximum: Double
    private let window: ReplayWindow
    private let dateFormatter: DateFormatter
    private let fileDateFormatter: DateFormatter

    init(width: Int, height: Int, yMaximum: Double, window: ReplayWindow) {
        self.width = CGFloat(width)
        self.height = CGFloat(height)
        self.yMaximum = yMaximum
        self.window = window
        self.chartRect = CGRect(
            x: 82,
            y: 136,
            width: CGFloat(width) - 126,
            height: CGFloat(height) - 286
        )

        let formatter = DateFormatter()
        formatter.dateFormat = "EEE HH:mm"
        formatter.timeZone = .current
        self.dateFormatter = formatter

        let fileFormatter = DateFormatter()
        fileFormatter.dateFormat = "yyyyMMdd-HHmm"
        fileFormatter.timeZone = .current
        self.fileDateFormatter = fileFormatter
    }

    func render(frame: ReplayFrame, to url: URL) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let cgContext = CGContext(
            data: nil,
            width: Int(width),
            height: Int(height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ReplayError.imageEncoding(url, "cg context")
        }
        let context = NSGraphicsContext(cgContext: cgContext, flipped: false)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context

        drawBackground()
        drawGrid()
        drawFutureActual(frame: frame)
        drawKnownHotRuns(frame: frame)
        drawForecast(frame: frame)
        drawKnownActual(frame: frame)
        drawCheckpoint(frame.checkpoint)
        drawHeader(frame: frame)
        drawFooter(frame: frame)

        NSGraphicsContext.restoreGraphicsState()
        cgContext.flush()

        guard let cgImage = cgContext.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ReplayError.imageEncoding(url, "cgImage or destination")
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ReplayError.imageEncoding(url, "finalize")
        }
    }

    func fileName(for frame: ReplayFrame) -> String {
        let elapsed = Int((frame.checkpoint.timeIntervalSince(window.startDate) / 3600).rounded())
        let stamp = fileDateFormatter.string(from: frame.checkpoint)
        return String(format: "frame-%03d_0-%03dh_%@.png", frame.index, elapsed, stamp)
    }

    private func drawBackground() {
        NSColor(calibratedRed: 0.05, green: 0.05, blue: 0.055, alpha: 1).setFill()
        NSBezierPath(rect: CGRect(x: 0, y: 0, width: width, height: height)).fill()

        NSColor(calibratedRed: 0.14, green: 0.14, blue: 0.145, alpha: 1).setFill()
        NSBezierPath(roundedRect: CGRect(x: 28, y: 28, width: width - 56, height: height - 56), xRadius: 26, yRadius: 26).fill()

        NSColor(calibratedWhite: 1, alpha: 0.18).setStroke()
        let border = NSBezierPath(roundedRect: CGRect(x: 28.5, y: 28.5, width: width - 57, height: height - 57), xRadius: 26, yRadius: 26)
        border.lineWidth = 2
        border.stroke()

        drawDayBands()
    }

    private func drawDayBands() {
        var index = 0
        var bandStart = window.startDate
        while bandStart < window.resetDate {
            let bandEnd = min(window.resetDate, bandStart.addingTimeInterval(24 * 60 * 60))
            if index.isMultiple(of: 2) == false {
                let rect = CGRect(
                    x: x(for: bandStart),
                    y: chartRect.minY,
                    width: max(1, x(for: bandEnd) - x(for: bandStart)),
                    height: chartRect.height
                )
                NSColor(calibratedWhite: 1, alpha: 0.045).setFill()
                NSBezierPath(rect: rect).fill()
            }
            index += 1
            bandStart = bandEnd
        }
    }

    private func drawGrid() {
        NSColor(calibratedWhite: 1, alpha: 0.075).setStroke()
        let outline = NSBezierPath(rect: chartRect)
        outline.lineWidth = 1
        outline.stroke()

        let yTicks = stride(from: 0.0, through: yMaximum, by: 25.0).map { $0 }
        for tick in yTicks {
            let y = y(for: tick)
            let line = NSBezierPath()
            line.move(to: CGPoint(x: chartRect.minX, y: y))
            line.line(to: CGPoint(x: chartRect.maxX, y: y))
            line.lineWidth = tick == 100 ? 1.4 : 0.8
            (tick == 100
                ? NSColor(calibratedRed: 1, green: 0.23, blue: 0.25, alpha: 0.78)
                : NSColor(calibratedWhite: 1, alpha: 0.08)
            ).setStroke()
            line.stroke()
            drawText(
                String(format: "%.0f", tick),
                in: CGRect(x: 32, y: y - 8, width: 40, height: 18),
                size: 15,
                color: NSColor(calibratedWhite: 1, alpha: 0.36),
                alignment: .right
            )
        }

        var tickDate = window.startDate
        while tickDate <= window.resetDate.addingTimeInterval(1) {
            let x = x(for: tickDate)
            let line = NSBezierPath()
            line.move(to: CGPoint(x: x, y: chartRect.minY))
            line.line(to: CGPoint(x: x, y: chartRect.maxY))
            line.lineWidth = 0.8
            NSColor(calibratedWhite: 1, alpha: 0.07).setStroke()
            line.stroke()
            drawText(
                dateFormatter.string(from: tickDate),
                in: CGRect(x: x - 42, y: chartRect.minY - 31, width: 84, height: 18),
                size: 12,
                color: NSColor(calibratedWhite: 1, alpha: 0.42),
                alignment: .center
            )
            tickDate = tickDate.addingTimeInterval(24 * 60 * 60)
        }
    }

    private func drawKnownHotRuns(frame: ReplayFrame) {
        let observedRuns = frame.projection.cycleRunForecast?.observedIntensityRuns ?? []
        let runs = observedRuns.map { HotRun(startDate: $0.startDate, endDate: $0.endDate) }
        for run in runs {
            let startX = x(for: max(run.startDate, window.startDate))
            let endX = x(for: min(run.endDate, frame.checkpoint))
            guard endX > startX else {
                continue
            }
            let rect = CGRect(x: startX, y: chartRect.minY, width: max(2, endX - startX), height: chartRect.height)
            NSColor(calibratedRed: 1.0, green: 0.48, blue: 0.08, alpha: 0.22).setFill()
            NSBezierPath(rect: rect).fill()
        }
    }

    private func drawFutureActual(frame: ReplayFrame) {
        let currentPoint = Point(date: frame.checkpoint, usedPercent: frame.currentPercent)
        let points = [currentPoint] + window.samples
            .filter { $0.capturedAt > frame.checkpoint }
            .map { Point(date: $0.capturedAt, usedPercent: $0.weeklyUsedPercent) }
        drawLine(
            points: points,
            color: NSColor(calibratedRed: 0.17, green: 0.58, blue: 1.0, alpha: 0.34),
            lineWidth: 3.2,
            dash: [9, 7]
        )
    }

    private func drawKnownActual(frame: ReplayFrame) {
        var points = frame.knownSamples.map { Point(date: $0.capturedAt, usedPercent: $0.weeklyUsedPercent) }
        if points.last?.date != frame.checkpoint {
            points.append(Point(date: frame.checkpoint, usedPercent: frame.currentPercent))
        }
        drawLine(
            points: points,
            color: NSColor(calibratedRed: 0.06, green: 0.57, blue: 1.0, alpha: 1),
            lineWidth: 5,
            dash: nil
        )
    }

    private func drawForecast(frame: ReplayFrame) {
        guard let forecast = frame.projection.cycleRunForecast else {
            return
        }

        if forecast.corridorPoints.count >= 2 {
            let highPoints = forecast.corridorPoints.map {
                CGPoint(x: x(for: $0.date), y: y(for: $0.upperUsedPercent))
            }
            let lowPoints = forecast.corridorPoints.reversed().map {
                CGPoint(x: x(for: $0.date), y: y(for: $0.lowerUsedPercent))
            }
            let path = NSBezierPath()
            path.move(to: highPoints[0])
            for point in highPoints.dropFirst() {
                path.line(to: point)
            }
            for point in lowPoints {
                path.line(to: point)
            }
            path.close()
            NSColor(calibratedRed: 0.08, green: 0.42, blue: 0.76, alpha: 0.18).setFill()
            path.fill()
        }

        drawSegments(
            forecast.lowLineSegments,
            color: NSColor(calibratedRed: 0.08, green: 0.77, blue: 0.54, alpha: 1),
            lineWidth: 4
        )
        let highEndpoint = forecast.highProjectedWeeklyUsedPercentAtReset
        let highColor = highEndpoint >= 100
            ? NSColor(calibratedRed: 1.0, green: 0.27, blue: 0.30, alpha: 1)
            : NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.13, alpha: 1)
        drawSegments(forecast.highLineSegments, color: highColor, lineWidth: 4)
    }

    private func drawCheckpoint(_ date: Date) {
        let line = NSBezierPath()
        let x = x(for: date)
        line.move(to: CGPoint(x: x, y: chartRect.minY))
        line.line(to: CGPoint(x: x, y: chartRect.maxY))
        line.lineWidth = 1.4
        NSColor(calibratedWhite: 1, alpha: 0.36).setStroke()
        line.stroke()
    }

    private func drawHeader(frame: ReplayFrame) {
        let forecast = frame.projection.cycleRunForecast
        let low = forecast?.lowProjectedWeeklyUsedPercentAtReset
        let high = forecast?.highProjectedWeeklyUsedPercentAtReset
        let forecastText: String
        if let low, let high {
            forecastText = String(format: "estimate %.0f-%.0f%%", low, high)
        } else if let projected = frame.projection.projectedWeeklyUsedPercentAtReset {
            forecastText = String(format: "estimate %.0f%%", projected)
        } else {
            forecastText = "estimate unavailable"
        }

        let paceColor: NSColor
        switch frame.projection.paceState {
        case .slowDown:
            paceColor = NSColor(calibratedRed: 1.0, green: 0.27, blue: 0.30, alpha: 1)
        case .watch:
            paceColor = NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.13, alpha: 1)
        case .fine:
            paceColor = NSColor(calibratedRed: 0.08, green: 0.77, blue: 0.54, alpha: 1)
        case .noData:
            paceColor = NSColor(calibratedWhite: 1, alpha: 0.55)
        }

        drawText(
            String(format: "%.0f%%", frame.currentPercent),
            in: CGRect(x: 66, y: height - 150, width: 150, height: 70),
            size: 58,
            color: paceColor,
            weight: .bold
        )
        drawText(
            forecastText,
            in: CGRect(x: 220, y: height - 132, width: 360, height: 38),
            size: 28,
            color: paceColor,
            weight: .bold
        )

        let elapsedHours = frame.checkpoint.timeIntervalSince(window.startDate) / 3600
        let title = String(format: "Replay %03d: 0-%.0fh known", frame.index, elapsedHours)
        drawText(
            title,
            in: CGRect(x: 66, y: height - 70, width: 420, height: 28),
            size: 22,
            color: NSColor(calibratedWhite: 1, alpha: 0.88),
            weight: .semibold
        )
        drawText(
            "forecast from \(dateFormatter.string(from: frame.checkpoint)) to reset \(dateFormatter.string(from: window.resetDate))",
            in: CGRect(x: 66, y: height - 95, width: 560, height: 22),
            size: 15,
            color: NSColor(calibratedWhite: 1, alpha: 0.54)
        )

        let status = frame.projection.paceState == .slowDown
            ? "slow down"
            : (frame.projection.paceState == .watch ? "careful" : "fine")
        drawText(
            status,
            in: CGRect(x: width - 258, y: height - 132, width: 190, height: 34),
            size: 24,
            color: paceColor,
            weight: .semibold,
            alignment: .right
        )
    }

    private func drawFooter(frame: ReplayFrame) {
        let latest = window.samples.last
        let latestText = latest.map {
            String(format: "actual latest %.0f%% at %@", $0.weeklyUsedPercent, dateFormatter.string(from: $0.capturedAt))
        } ?? "actual latest unavailable"
        let details = [
            "solid blue: known data",
            "dashed blue: later actuals",
            "orange bands: known hot moments",
            latestText
        ].joined(separator: "    ")
        drawText(
            details,
            in: CGRect(x: 70, y: 66, width: width - 140, height: 24),
            size: 14,
            color: NSColor(calibratedWhite: 1, alpha: 0.50)
        )

        let sampleText = "\(frame.knownSamples.count) samples known / \(window.samples.count) current-window samples"
        drawText(
            sampleText,
            in: CGRect(x: 70, y: 42, width: width - 140, height: 22),
            size: 13,
            color: NSColor(calibratedWhite: 1, alpha: 0.34)
        )
    }

    private func drawSegments(_ segments: [QuotaForecastLineSegment], color: NSColor, lineWidth: CGFloat) {
        var points: [Point] = []
        if let first = segments.first {
            points.append(Point(date: first.startDate, usedPercent: first.startUsedPercent))
        }
        for segment in segments {
            points.append(Point(date: segment.endDate, usedPercent: segment.endUsedPercent))
        }
        drawLine(points: points, color: color, lineWidth: lineWidth, dash: nil)
    }

    private func drawLine(points: [Point], color: NSColor, lineWidth: CGFloat, dash: [CGFloat]?) {
        guard points.count >= 2 else {
            return
        }
        let path = NSBezierPath()
        path.move(to: CGPoint(x: x(for: points[0].date), y: y(for: points[0].usedPercent)))
        for point in points.dropFirst() {
            path.line(to: CGPoint(x: x(for: point.date), y: y(for: point.usedPercent)))
        }
        path.lineWidth = lineWidth
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        if let dash {
            path.setLineDash(dash, count: dash.count, phase: 0)
        }
        color.setStroke()
        path.stroke()
    }

    private func drawText(
        _ text: String,
        in rect: CGRect,
        size: CGFloat,
        color: NSColor,
        weight: NSFont.Weight = .regular,
        alignment: NSTextAlignment = .left
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        NSString(string: text).draw(in: rect, withAttributes: attributes)
    }

    private func x(for date: Date) -> CGFloat {
        let duration = max(1, window.resetDate.timeIntervalSince(window.startDate))
        let fraction = min(1, max(0, date.timeIntervalSince(window.startDate) / duration))
        return chartRect.minX + CGFloat(fraction) * chartRect.width
    }

    private func y(for usedPercent: Double) -> CGFloat {
        let fraction = min(1, max(0, usedPercent / yMaximum))
        return chartRect.minY + CGFloat(fraction) * chartRect.height
    }
}

private func main() throws {
    let options = try parseOptions(CommandLine.arguments.dropFirst())
    let samplesURL = URL(fileURLWithPath: options.samplesPath)
    let store = QuotaSampleStore(fileURL: samplesURL)
    let samples = try store.load(policy: .countOnly(500_000), now: Date.distantFuture)
    guard samples.isEmpty == false else {
        throw ReplayError.noSamples(samplesURL)
    }

    let window = try makeReplayWindow(samples: samples)
    let checkpoints = makeCheckpoints(window: window, stepHours: options.stepHours)
    guard checkpoints.isEmpty == false else {
        throw ReplayError.noFrames
    }

    let outputURL = try makeOutputDirectory(path: options.outputPath)
    let yMaximum = niceMaximum(window: window)
    let renderer = ReplayRenderer(width: options.width, height: options.height, yMaximum: yMaximum, window: window)

    var frames: [ReplayFrame] = []
    for checkpoint in checkpoints {
        guard let frame = makeFrame(window: window, checkpoint: checkpoint, index: frames.count + 1) else {
            continue
        }
        writeStatus("Rendering frame \(frame.index)/\(checkpoints.count)")
        let url = outputURL.appendingPathComponent(renderer.fileName(for: frame))
        try renderer.render(frame: frame, to: url)
        frames.append(frame)
    }

    guard frames.isEmpty == false else {
        throw ReplayError.noFrames
    }

    let indexURL = outputURL.appendingPathComponent("README.txt")
    let summary = makeSummary(window: window, frames: frames, yMaximum: yMaximum)
    try summary.write(to: indexURL, atomically: true, encoding: .utf8)

    print("Wrote \(frames.count) replay frames")
    print(outputURL.path)
}

private func parseOptions(_ arguments: ArraySlice<String>) throws -> Options {
    var options = Options()
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
        switch argument {
        case "--samples":
            guard let value = iterator.next() else {
                throw ReplayError.usage("--samples requires a path")
            }
            options.samplesPath = value
        case "--output":
            guard let value = iterator.next() else {
                throw ReplayError.usage("--output requires a directory path")
            }
            options.outputPath = value
        case "--step-hours":
            guard let value = iterator.next(), let number = Double(value), number > 0 else {
                throw ReplayError.usage("--step-hours requires a positive number")
            }
            options.stepHours = number
        case "--width":
            guard let value = iterator.next(), let number = Int(value), number >= 600 else {
                throw ReplayError.usage("--width requires an integer >= 600")
            }
            options.width = number
        case "--height":
            guard let value = iterator.next(), let number = Int(value), number >= 400 else {
                throw ReplayError.usage("--height requires an integer >= 400")
            }
            options.height = number
        case "--help", "-h":
            throw ReplayError.usage("""
            Usage: Scripts/forecast-replay.sh [options]

              --samples PATH       quota-samples.jsonl path
              --output DIR         output directory
              --step-hours HOURS   replay checkpoint spacing, default 4
              --width PX           image width, default 1200
              --height PX          image height, default 700
            """)
        default:
            throw ReplayError.usage("Unknown argument: \(argument)")
        }
    }
    return options
}

private func makeReplayWindow(samples: [QuotaSample]) throws -> ReplayWindow {
    let sorted = samples.sorted { first, second in
        if first.capturedAt == second.capturedAt {
            return first.limitId < second.limitId
        }
        return first.capturedAt < second.capturedAt
    }

    guard let latest = sorted.last(where: { sample in
        sample.weeklyResetsAt != nil
            && sample.weeklyWindowMinutes != nil
            && sample.weeklyUsedPercent.isFinite
    }),
          let resetDate = latest.weeklyResetsAt,
          let windowMinutes = latest.weeklyWindowMinutes else {
        throw ReplayError.noCurrentWindow
    }

    let startDate = resetDate.addingTimeInterval(-TimeInterval(windowMinutes * 60))
    let windowSamples = sorted.filter { sample in
        sample.limitId == latest.limitId
            && sample.capturedAt >= startDate
            && sample.capturedAt <= latest.capturedAt
            && sample.weeklyUsedPercent.isFinite
            && sameReset(sample.weeklyResetsAt, resetDate)
    }

    guard windowSamples.isEmpty == false else {
        throw ReplayError.noCurrentWindow
    }

    return ReplayWindow(
        limitId: latest.limitId,
        limitName: latest.limitName,
        planType: latest.planType,
        startDate: startDate,
        resetDate: resetDate,
        latestDate: latest.capturedAt,
        windowMinutes: windowMinutes,
        samples: deduplicate(samples: windowSamples)
    )
}

private func makeCheckpoints(window: ReplayWindow, stepHours: Double) -> [Date] {
    let step = stepHours * 60 * 60
    var checkpoints: [Date] = []
    var cursor = window.startDate.addingTimeInterval(step)
    while cursor <= window.latestDate {
        checkpoints.append(cursor)
        cursor = cursor.addingTimeInterval(step)
    }

    if let last = checkpoints.last {
        if window.latestDate.timeIntervalSince(last) > 15 * 60 {
            checkpoints.append(window.latestDate)
        }
    } else {
        checkpoints.append(window.latestDate)
    }
    return checkpoints
}

private func makeFrame(window: ReplayWindow, checkpoint: Date, index: Int) -> ReplayFrame? {
    let knownSamples = window.samples.filter { $0.capturedAt <= checkpoint }
    guard let currentSample = knownSamples.last else {
        return nil
    }

    let snapshot = makeSnapshot(sample: currentSample, window: window)
    let projection = QuotaProjectionEngine.make(
        snapshot: snapshot,
        samples: knownSamples,
        now: checkpoint
    )
    return ReplayFrame(
        index: index,
        checkpoint: checkpoint,
        currentSample: currentSample,
        knownSamples: knownSamples,
        projection: projection
    )
}

private func makeSnapshot(sample: QuotaSample, window: ReplayWindow) -> RateLimitSnapshot {
    let primary: RateLimitWindow?
    if let fiveHourUsedPercent = sample.fiveHourUsedPercent {
        primary = RateLimitWindow(
            usedPercent: fiveHourUsedPercent,
            windowDurationMins: sample.fiveHourWindowMinutes,
            resetsAt: sample.fiveHourResetsAt.map { Int($0.timeIntervalSince1970.rounded()) }
        )
    } else {
        primary = nil
    }

    return RateLimitSnapshot(
        limitId: sample.limitId,
        limitName: sample.limitName ?? window.limitName,
        primary: primary,
        secondary: RateLimitWindow(
            usedPercent: sample.weeklyUsedPercent,
            windowDurationMins: sample.weeklyWindowMinutes ?? window.windowMinutes,
            resetsAt: Int(window.resetDate.timeIntervalSince1970.rounded())
        ),
        credits: nil,
        planType: sample.planType ?? window.planType,
        rateLimitReachedType: sample.rateLimitReachedType
    )
}

private func deduplicate(samples: [QuotaSample]) -> [QuotaSample] {
    var result: [QuotaSample] = []
    for sample in samples {
        if let last = result.last,
           abs(last.capturedAt.timeIntervalSince(sample.capturedAt)) < 0.5 {
            if sample.weeklyUsedPercent >= last.weeklyUsedPercent {
                result[result.count - 1] = sample
            }
        } else {
            result.append(sample)
        }
    }
    return result
}

private func niceMaximum(window: ReplayWindow) -> Double {
    let maximum = max(140, (window.samples.map(\.weeklyUsedPercent).max() ?? 100) + 50)
    return ceil((maximum + 4) / 10) * 10
}

private func makeOutputDirectory(path: String?) throws -> URL {
    let url: URL
    if let path {
        url = URL(fileURLWithPath: path)
    } else {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = .current
        let name = "TokenCoffee-ForecastReplay-\(formatter.string(from: Date()))"
        url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeSummary(window: ReplayWindow, frames: [ReplayFrame], yMaximum: Double) -> String {
    let formatter = ISO8601DateFormatter()
    let first = (frames.first?.checkpoint).map { formatter.string(from: $0) } ?? "n/a"
    let last = (frames.last?.checkpoint).map { formatter.string(from: $0) } ?? "n/a"
    return """
    TokenCoffee forecast replay

    Limit: \(window.limitId)
    Window start: \(formatter.string(from: window.startDate))
    Window reset: \(formatter.string(from: window.resetDate))
    Latest sample: \(formatter.string(from: window.latestDate))
    Frames: \(frames.count)
    First checkpoint: \(first)
    Last checkpoint: \(last)
    Y axis maximum: \(Int(yMaximum))%

    Solid blue is quota data known at the checkpoint.
    Dashed blue is later observed data from the same current window.
    Green/orange forecast lines are the app projection at that checkpoint.
    Orange background bands are hot moments known to the model at that checkpoint.
    """
}

private func sameReset(_ lhs: Date?, _ rhs: Date) -> Bool {
    guard let lhs else {
        return false
    }
    return abs(lhs.timeIntervalSince(rhs)) < 5
}

private func writeStatus(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

do {
    try main()
} catch let error as ReplayError {
    FileHandle.standardError.write(Data("\(error.description)\n".utf8))
    exit(2)
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
