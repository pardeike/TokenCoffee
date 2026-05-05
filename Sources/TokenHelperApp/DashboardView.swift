import AppKit
import Charts
import SwiftUI
import TokenHelperCore

struct DashboardView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            powerControls

            if let powerErrorMessage = model.powerErrorMessage {
                Text(powerErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            quotaSection
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: 480, height: 272, alignment: .topLeading)
        .background(.regularMaterial)
    }

    private var powerControls: some View {
        HStack(spacing: 8) {
            Picker("Power", selection: Binding(
                get: { model.powerMode },
                set: { model.setPowerMode($0) }
            )) {
                Text("Off").tag(PowerSessionMode.off)
                Text("Mac awake").tag(PowerSessionMode.keepAwake)
                Text("Screen on").tag(PowerSessionMode.keepAwakeDisplay)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .font(.system(size: 12, weight: .semibold))
            .frame(width: 248)

            Spacer(minLength: 0)

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Quit")
        }
        .frame(maxWidth: .infinity)
    }

    private var quotaSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            quotaReadout
            QuotaGraphView(
                samples: model.graphSamples,
                projection: model.projection,
                snapshot: model.quotaSnapshot
            )
            .frame(height: 146)
            .padding(.bottom, 4)
            quotaFooter
        }
    }

    private var quotaReadout: some View {
        let projection = model.projection
        let estimate = projection.cycleRunForecast?.projectedWeeklyUsedPercentAtReset
        let readoutColor = estimate.map(estimateColor) ?? paceColor(projection.paceState)
        return HStack(alignment: .lastTextBaseline, spacing: 8) {
            Text(percent(projection.currentWeeklyUsedPercent))
                .font(.system(size: 32, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(readoutColor)

            if let estimate {
                Text("estimate \(percent(estimate))")
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .help("Cycle-run forecast at renew")
            }

            Spacer()

            HStack(spacing: 4) {
                Image(systemName: "calendar")
                Text(renewalValue)
            }
            .font(.headline.monospacedDigit())
            .foregroundStyle(.primary)
            .help("Weekly renew date")
        }
    }

    private var quotaFooter: some View {
        HStack(spacing: 10) {
            Label(primaryLegendValue, systemImage: "clock")
                .foregroundStyle(.secondary)
                .help("5h usage and reset time")

            if model.lastQuotaErrorDate != nil, let lastQuotaRefresh = model.lastQuotaRefresh {
                Label("stale \(DateFormatter.panelTime.string(from: lastQuotaRefresh))", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }

            Spacer(minLength: 0)

            Text(paceText(model.projection.paceState))
                .foregroundStyle(paceColor(model.projection.paceState))
        }
        .font(.caption.monospacedDigit())
        .lineLimit(1)
    }

    private var renewalValue: String {
        guard let resetDate = model.projection.weeklyResetDate else {
            return model.lastQuotaErrorDate == nil ? "--:--" : "offline"
        }
        return DateFormatter.panelDate.string(from: resetDate)
    }

    private var primaryLegendValue: String {
        guard let primary = model.quotaSnapshot?.primary else {
            return "5h --"
        }
        let reset = primary.resetDate.map { " -> \(DateFormatter.panelTime.string(from: $0))" } ?? ""
        return "5h \(percent(primary.usedPercent))\(reset)"
    }

    private func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    private func paceText(_ state: QuotaPaceState) -> String {
        switch state {
        case .noData:
            "no data"
        case .fine:
            "fine"
        case .watch:
            "watch"
        case .slowDown:
            "slow down"
        }
    }

    private func paceColor(_ state: QuotaPaceState) -> Color {
        switch state {
        case .noData:
            .secondary
        case .fine:
            .green
        case .watch:
            .orange
        case .slowDown:
            .red
        }
    }

    private func estimateColor(_ estimate: Double) -> Color {
        estimate > 100 ? .red : .green
    }
}

private struct QuotaGraphView: View {
    let samples: [QuotaSample]
    let projection: QuotaProjection
    let snapshot: RateLimitSnapshot?

    var body: some View {
        if let resetDate = projection.weeklyResetDate {
            let startDate = graphStartDate(resetDate: resetDate)
            let now = Date()
            Chart {
                ForEach(dayBands(startDate: startDate, resetDate: resetDate)) { band in
                    RectangleMark(
                        xStart: .value("Start", band.startDate),
                        xEnd: .value("End", band.endDate),
                        yStart: .value("Low", 0),
                        yEnd: .value("High", 105)
                    )
                    .foregroundStyle(band.isHighlighted ? Color.white.opacity(0.035) : Color.clear)
                }

                ForEach(dayBoundaries(startDate: startDate, resetDate: resetDate)) { boundary in
                    RuleMark(x: .value("Day", boundary.date))
                        .foregroundStyle(.secondary.opacity(0.16))
                        .lineStyle(StrokeStyle(lineWidth: 0.5))
                }

                if let cycleForecast = projection.cycleRunForecast {
                    ForEach(cycleForecast.corridorPoints, id: \.date) { point in
                        AreaMark(
                            x: .value("Time", point.date),
                            yStart: .value("Low", graphPercent(point.lowerUsedPercent)),
                            yEnd: .value("High", graphPercent(point.upperUsedPercent))
                        )
                        .foregroundStyle(Color.blue.opacity(0.11))
                        .interpolationMethod(.linear)
                    }
                }

                ForEach(actualPoints) { point in
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Percent", point.percent),
                        series: .value("Series", point.series)
                    )
                    .foregroundStyle(.blue)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }

                ForEach(actualPoints) { point in
                    PointMark(
                        x: .value("Time", point.date),
                        y: .value("Percent", point.percent)
                    )
                    .foregroundStyle(.blue)
                    .symbolSize(12)
                }

                if let projected = projection.projectedWeeklyUsedPercentAtReset {
                    ForEach(projectionSegments(now: now, resetDate: resetDate, projected: projected)) { segment in
                        ForEach(segment.points) { point in
                            LineMark(
                                x: .value("Time", point.date),
                                y: .value("Percent", point.percent),
                                series: .value("Series", segment.id)
                            )
                            .foregroundStyle(segment.color)
                            .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                        }
                    }
                }

                RuleMark(y: .value("Limit", 100))
                    .foregroundStyle(.red.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1))

                RuleMark(x: .value("Deadline", resetDate))
                    .foregroundStyle(.red.opacity(0.85))
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .butt))
            }
            .chartXScale(domain: startDate ... resetDate)
            .chartYScale(domain: 0 ... 105)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(.secondary.opacity(0.32))
                    AxisTick(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(.secondary.opacity(0.4))
                    if let number = value.as(Double.self) {
                        AxisValueLabel {
                            Text("\(Int(number))")
                                .font(.system(size: 9, weight: .medium).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .offset(y: number == 0 ? -4 : 0)
                        }
                    }
                }
            }
            .chartPlotStyle { plotArea in
                plotArea.overlay {
                    if let cycleForecast = projection.cycleRunForecast {
                        CycleForecastLineOverlay(
                            forecast: cycleForecast,
                            startDate: startDate,
                            resetDate: resetDate,
                            currentDate: actualPoints.last?.date ?? now,
                            currentUsedPercent: actualPoints.last?.percent ?? graphPercent(projection.currentWeeklyUsedPercent),
                            ceiling: graphCeiling
                        )
                        .allowsHitTesting(false)
                    }
                }
            }
            .clipped()
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary.opacity(0.35))
                Text("No data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func graphStartDate(resetDate: Date) -> Date {
        resetDate.addingTimeInterval(-7 * 24 * 60 * 60)
    }

    private func dayBands(startDate: Date, resetDate: Date) -> [DayBand] {
        let segmentDuration = resetDate.timeIntervalSince(startDate) / 7
        return (0..<7).map { index in
            let segmentStart = startDate.addingTimeInterval(TimeInterval(index) * segmentDuration)
            let segmentEnd = index == 6
                ? resetDate
                : startDate.addingTimeInterval(TimeInterval(index + 1) * segmentDuration)
            return DayBand(
                index: index,
                startDate: segmentStart,
                endDate: segmentEnd,
                isHighlighted: index.isMultiple(of: 2)
            )
        }
    }

    private func dayBoundaries(startDate: Date, resetDate: Date) -> [DayBoundary] {
        let segmentDuration = resetDate.timeIntervalSince(startDate) / 7
        return (1..<7).map { index in
            DayBoundary(
                index: index,
                date: startDate.addingTimeInterval(TimeInterval(index) * segmentDuration)
            )
        }
    }

    private var actualPoints: [GraphPoint] {
        let stored = samples.map {
            GraphPoint(date: $0.capturedAt, percent: graphPercent($0.weeklyUsedPercent), series: "actual")
        }
        if stored.isEmpty,
           let weekly = snapshot?.secondary {
            return [GraphPoint(date: Date(), percent: graphPercent(weekly.usedPercent), series: "actual")]
        }
        return stored
    }

    private func projectionSegments(now: Date, resetDate: Date, projected: Double) -> [ProjectionSegment] {
        let current = projection.currentWeeklyUsedPercent
        let totalDuration = resetDate.timeIntervalSince(now)
        guard totalDuration > 0,
              current < graphCeiling else {
            return []
        }

        let startPoint = GraphPoint(date: now, percent: graphPercent(current), series: "projected-safe")
        let visibleEndPoint = visibleProjectionEndPoint(
            now: now,
            resetDate: resetDate,
            current: current,
            projected: projected
        )

        if current >= 100 {
            return [ProjectionSegment(id: "projected-over", color: Color.red.opacity(0.6), points: [startPoint, visibleEndPoint])]
        }

        if projected <= current {
            return [ProjectionSegment(id: "projected-safe", color: Color.yellow.opacity(0.36), points: [startPoint, visibleEndPoint])]
        }

        guard projected > 100 else {
            return [ProjectionSegment(id: "projected-safe", color: Color.yellow.opacity(0.36), points: [startPoint, visibleEndPoint])]
        }

        let crossingFraction = (100 - current) / (projected - current)
        let crossingDate = now.addingTimeInterval(totalDuration * crossingFraction)
        let crossingPoint = GraphPoint(date: crossingDate, percent: 100, series: "projected-crossing")
        return [
            ProjectionSegment(id: "projected-safe", color: Color.yellow.opacity(0.36), points: [startPoint, crossingPoint]),
            ProjectionSegment(id: "projected-over", color: Color.red.opacity(0.6), points: [crossingPoint, visibleEndPoint])
        ]
    }

    private func visibleProjectionEndPoint(
        now: Date,
        resetDate: Date,
        current: Double,
        projected: Double
    ) -> GraphPoint {
        guard projected > graphCeiling,
              projected > current else {
            return GraphPoint(date: resetDate, percent: graphPercent(projected), series: "projected-limit")
        }

        let totalDuration = resetDate.timeIntervalSince(now)
        let ceilingFraction = (graphCeiling - current) / (projected - current)
        let ceilingDate = now.addingTimeInterval(totalDuration * ceilingFraction)
        return GraphPoint(date: ceilingDate, percent: graphCeiling, series: "projected-ceiling")
    }

    private func graphPercent(_ value: Double) -> Double {
        min(graphCeiling, max(0, value))
    }

    private var graphCeiling: Double { 105 }
}

private struct DayBand: Identifiable {
    let index: Int
    let startDate: Date
    let endDate: Date
    let isHighlighted: Bool

    var id: Int { index }
}

private struct DayBoundary: Identifiable {
    let index: Int
    let date: Date

    var id: Int { index }
}

private struct ProjectionSegment: Identifiable {
    let id: String
    let color: Color
    let points: [GraphPoint]
}

private struct GraphPoint: Identifiable {
    let date: Date
    let percent: Double
    let series: String

    var id: String {
        "\(series)-\(date.timeIntervalSince1970)"
    }
}

private struct CycleForecastLineOverlay: View {
    let forecast: QuotaCycleRunForecast
    let startDate: Date
    let resetDate: Date
    let currentDate: Date
    let currentUsedPercent: Double
    let ceiling: Double

    private let threshold = 100.0

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                guard size.width > 0,
                      size.height > 0,
                      resetDate > startDate else {
                    return
                }

                let averagePath = averagePath(in: size)
                drawThresholded(
                    path: averagePath,
                    in: size,
                    context: &context,
                    belowColor: .blue.opacity(0.28),
                    aboveColor: .red.opacity(0.46),
                    lineWidth: 4.5,
                    lineCap: .butt,
                    lineJoin: .bevel
                )
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private func averagePath(in size: CGSize) -> Path {
        var path = Path()
        var lastEnd: CGPoint?
        let runs = forecast.averageRuns
            .sorted { $0.startDate < $1.startDate }
            .filter { $0.endDate > $0.startDate }

        if let first = runs.first {
            let current = plotPoint(date: currentDate, percent: currentUsedPercent, in: size)
            let firstStart = plotPoint(date: first.startDate, percent: first.startUsedPercent, in: size)
            path.move(to: current)
            path.addLine(to: CGPoint(x: firstStart.x, y: current.y))
            lastEnd = CGPoint(x: firstStart.x, y: current.y)
        }

        for run in runs {
            let start = plotPoint(date: run.startDate, percent: run.startUsedPercent, in: size)
            let end = plotPoint(date: run.endDate, percent: run.endUsedPercent, in: size)
            if let lastEnd {
                let connector = CGPoint(x: start.x, y: lastEnd.y)
                path.addLine(to: connector)
            } else {
                path.move(to: start)
            }
            path.addLine(to: end)
            lastEnd = end
        }
        return path
    }

    private func drawThresholded(
        path: Path,
        in size: CGSize,
        context: inout GraphicsContext,
        belowColor: Color,
        aboveColor: Color,
        lineWidth: Double,
        lineCap: CGLineCap,
        lineJoin: CGLineJoin
    ) {
        let thresholdY = y(percent: threshold, in: size)
        let style = StrokeStyle(lineWidth: lineWidth, lineCap: lineCap, lineJoin: lineJoin)
        let aboveRect = CGRect(x: 0, y: 0, width: size.width, height: thresholdY)
        let belowRect = CGRect(x: 0, y: thresholdY, width: size.width, height: size.height - thresholdY)

        context.drawLayer { layer in
            layer.clip(to: Path(belowRect))
            layer.stroke(path, with: .color(belowColor), style: style)
        }
        context.drawLayer { layer in
            layer.clip(to: Path(aboveRect))
            layer.stroke(path, with: .color(aboveColor), style: style)
        }
    }

    private func plotPoint(date: Date, percent: Double, in size: CGSize) -> CGPoint {
        CGPoint(
            x: x(date: date, in: size),
            y: y(percent: percent, in: size)
        )
    }

    private func x(date: Date, in size: CGSize) -> Double {
        let duration = resetDate.timeIntervalSince(startDate)
        let fraction = date.timeIntervalSince(startDate) / duration
        return min(1, max(0, fraction)) * size.width
    }

    private func y(percent: Double, in size: CGSize) -> Double {
        let value = min(ceiling, max(0, percent))
        return size.height * (1 - value / ceiling)
    }
}

private extension DateFormatter {
    @MainActor
    static let panelDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE HH:mm"
        return formatter
    }()

    @MainActor
    static let panelTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
