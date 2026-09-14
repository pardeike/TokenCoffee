import AppKit
import SwiftUI
import TokenCoffeeCore

struct UsageTileView: View {
    let title: String
    let provider: String
    let snapshot: RateLimitSnapshot
    let samples: [QuotaSample]
    let projection: QuotaProjection
    let now: Date
    let kind: PrototypeTile.Kind
    let status: String?
    let prominent: Bool
    let inspecting: Bool
    var accent: Color? = nil
    private var used: Double { snapshot.secondary?.usedPercent ?? 0 }
    private var fiveHour: Double { status?.hasPrefix("5h limit") == true ? 100 : snapshot.primary?.usedPercent ?? 0 }
    private var tint: Color { status != nil ? .orange : (used >= 100 || projection.paceState == .slowDown ? .red : .cyan) }

    var body: some View {
        GeometryReader { geometry in
            let micro = kind == .micro && !inspecting
            let shallow = geometry.size.height < 120
            VStack(alignment: .leading, spacing: micro ? 2 : 4) {
                HStack(spacing: 4) {
                    Text(title).lineLimit(1).truncationMode(.middle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(accent ?? UsageProviderStyle.color(for: provider))
                    Spacer(minLength: 0)
                    if micro { Text("\(Int(used))%").font(.system(size: 12, weight: .semibold)).monospacedDigit() }
                }
                if !micro {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(Int(used))%")
                            .font(.system(size: shallow ? 20 : 28, weight: .semibold, design: .rounded))
                            .foregroundStyle(tint).monospacedDigit()
                        if kind == .detail, geometry.size.width > 240, !shallow {
                            Text(estimate).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if shallow { Text(status ?? sessionText).font(.system(size: 11)).foregroundStyle(status == nil ? Color.secondary : Color.orange).lineLimit(1) }
                    }
                }
                if kind == .detail && !shallow && geometry.size.width >= 220 {
                    QuotaGraphView(samples: samples, projection: projection,
                                   snapshot: snapshot, now: now, historyColor: accent ?? .blue)
                } else {
                    UsageSparkline(samples: samples, projection: projection, showForecast: !micro, historyColor: accent ?? .cyan)
                }
                if !micro && !shallow {
                    HStack(spacing: 4) {
                        Text(status ?? sessionText)
                            .foregroundStyle(status == nil ? Color.secondary : Color.orange)
                        Spacer(minLength: 0)
                        if let date = projection.weeklyResetDate {
                            Text(date, format: .dateTime.weekday(.abbreviated).hour().minute())
                                .foregroundStyle(.secondary)
                        }
                    }.font(.system(size: 11)).lineLimit(1)
                } else if micro, let status {
                    Text(status).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(1)
                }
            }
            .padding(micro ? 3 : 6)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .background(.primary.opacity(prominent && !inspecting ? 0.045 : 0.015), in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(.primary.opacity(0.07), lineWidth: 0.5) }
            .clipped()
        }
        .help("\(provider) · \(title), \(Int(used))% allowance used. \(sessionText). \(status ?? "")")
    }

    var sessionText: String {
        if snapshot.limitId == "session", snapshot.secondary?.windowDurationMins == 300 {
            return used >= 100 ? "Limit reached" : "5-hour window"
        }
        guard let session = snapshot.primary else { return "--" }
        let hours = (session.windowDurationMins ?? 300) / 60
        return "\(hours)h \(Int(fiveHour))%"
    }

    private var estimate: String {
        if let forecast = projection.cycleRunForecast {
            return "estimate \(Int(forecast.lowProjectedWeeklyUsedPercentAtReset))–\(Int(forecast.highProjectedWeeklyUsedPercentAtReset))%"
        }
        return projection.projectedWeeklyUsedPercentAtReset.map { "estimate \(Int($0))%" } ?? "Collecting history"
    }
}

enum UsageProviderStyle {
    static func color(for provider: String) -> Color {
        guard provider == "Claude" || provider == "Codex" else { return .secondary }
        return Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            if provider == "Claude" {
                return dark ? NSColor(srgbRed: 0.91, green: 0.62, blue: 0.48, alpha: 1)
                    : NSColor(srgbRed: 0.62, green: 0.28, blue: 0.17, alpha: 1)
            }
            return dark ? NSColor(srgbRed: 0.37, green: 0.80, blue: 0.67, alpha: 1)
                : NSColor(srgbRed: 0.08, green: 0.43, blue: 0.33, alpha: 1)
        })
    }
}

private struct UsageSparkline: View {
    let samples: [QuotaSample]
    let projection: QuotaProjection
    let showForecast: Bool
    let historyColor: Color
    var body: some View {
        Canvas { context, size in
            guard let first = samples.first, let last = samples.last else { return }
            let end = showForecast ? projection.weeklyResetDate ?? last.capturedAt : last.capturedAt
            let span = max(1, end.timeIntervalSince(first.capturedAt))
            func point(_ date: Date, _ percent: Double) -> CGPoint {
                CGPoint(x: date.timeIntervalSince(first.capturedAt) / span * size.width,
                        y: size.height - min(130, max(0, percent)) / 130 * max(1, size.height - 3) - 1)
            }
            var path = Path()
            path.move(to: point(first.capturedAt, first.weeklyUsedPercent))
            for sample in samples.dropFirst() { path.addLine(to: point(sample.capturedAt, sample.weeklyUsedPercent)) }
            context.stroke(path, with: .color(historyColor), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            let latest = point(last.capturedAt, last.weeklyUsedPercent)
            context.fill(Path(ellipseIn: CGRect(x: max(0, latest.x - 2), y: latest.y - 2, width: 4, height: 4)), with: .color(historyColor))
            if showForecast, let estimate = projection.cycleRunForecast?.highProjectedWeeklyUsedPercentAtReset
                ?? projection.projectedWeeklyUsedPercentAtReset {
                var forecast = Path()
                forecast.move(to: point(last.capturedAt, last.weeklyUsedPercent))
                forecast.addLine(to: point(end, estimate))
                context.stroke(forecast, with: .color(estimate > 100 ? .orange : .green), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            }
        }
        .accessibilityLabel("Usage history and forecast")
    }
}
