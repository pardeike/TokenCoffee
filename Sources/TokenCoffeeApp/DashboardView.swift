import AppKit
import Charts
import SwiftUI
import TokenCoffeeCore

struct DashboardView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openURL) private var openURL
    @State private var selectedPowerMode: PowerSessionMode = .off
    @State private var isCloseButtonHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            powerControls

            if let powerErrorMessage = model.powerErrorMessage {
                Text(powerErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            contentSection
        }
        .padding(EdgeInsets(top: 12, leading: 12, bottom: 4, trailing: 12))
        .frame(width: 480, height: 272, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var powerControls: some View {
        HStack(spacing: 8) {
            Picker("Power", selection: $selectedPowerMode) {
                Text("Off").tag(PowerSessionMode.off)
                Text("Keep Mac awake").tag(PowerSessionMode.keepAwake)
                Text("Keep screen on").tag(PowerSessionMode.keepAwakeDisplay)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .font(.system(size: 12, weight: .semibold))
            .frame(width: 340)
            .onAppear {
                selectedPowerMode = model.powerMode
            }
            .onChange(of: selectedPowerMode) { _, mode in
                guard mode != model.powerMode else {
                    return
                }
                Task { @MainActor in
                    model.setPowerMode(mode)
                }
            }
            .onReceive(model.$powerMode) { mode in
                guard mode != selectedPowerMode else {
                    return
                }
                selectedPowerMode = mode
            }

            Spacer(minLength: 0)

            Button {
                if NSEvent.modifierFlags.contains(.option) {
                    model.logoutCodex()
                } else {
                    NSApp.terminate(nil)
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.primary.opacity(isCloseButtonHovered ? 0.12 : 0.08))
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.primary.opacity(isCloseButtonHovered ? 0.48 : 0.34))
                }
                .frame(width: 22, height: 22)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { isCloseButtonHovered = $0 }
            .help("Quit")
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var contentSection: some View {
        if showsQuotaDashboard {
            quotaSection
        } else {
            codexAuthSection
        }
    }

    private var showsQuotaDashboard: Bool {
        switch model.codexSignInState {
        case .signedIn:
            return true
        case .unknown:
            return model.quotaSnapshot != nil
        case .needsSignIn, .startingSignIn, .signingIn, .failed:
            return false
        }
    }

    private var quotaSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            quotaReadout
            QuotaGraphView(
                samples: model.graphSamples,
                projection: model.projection,
                snapshot: model.quotaSnapshot,
                now: model.referenceDate
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
                    .foregroundStyle(estimateColor(estimate))
                    .help("Cycle-run forecast at renew")
            }

            Spacer()

            HStack(spacing: 4) {
                Image(systemName: "calendar")
                Text(renewalValue)
            }
            .font(.headline.monospacedDigit())
            .foregroundStyle(.primary)
            .help(model.lastQuotaErrorMessage ?? "Weekly renew date")
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

            if model.lastQuotaErrorDate != nil, let errorMessage = model.lastQuotaErrorMessage {
                Label(shortQuotaErrorMessage(errorMessage), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .help(errorMessage)
            }

            let syncStatusValue = syncStatusDisplay
            Label(syncStatusValue.text, systemImage: syncStatusValue.systemImage)
                .foregroundStyle(syncStatusValue.color)
                .help(syncStatusValue.help)

            Spacer(minLength: 0)

            Text(paceText(model.projection.paceState))
                .foregroundStyle(paceColor(model.projection.paceState))
        }
        .font(.caption.monospacedDigit())
        .lineLimit(1)
    }

    @ViewBuilder
    private var codexAuthSection: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 4)

            switch model.codexSignInState {
            case .unknown:
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.regular)
                    authHeader(
                        title: "Checking Codex",
                        detail: "Looking for an existing ChatGPT sign-in."
                    )
                }

            case .needsSignIn:
                VStack(spacing: 14) {
                    authHeader(
                        systemImage: "person.crop.circle.badge.plus",
                        title: "Sign in to Codex",
                        detail: "Use your ChatGPT account to read Codex usage limits on this Mac."
                    )

                    Button {
                        model.beginCodexSignIn()
                    } label: {
                        Label("Sign in", systemImage: "arrow.right.circle.fill")
                            .frame(minWidth: 112)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .help("Start ChatGPT device-code sign-in")
                }

            case .startingSignIn:
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.regular)
                    authHeader(
                        title: "Starting Sign-In",
                        detail: "Contacting Codex for a device code."
                    )
                }

            case let .signingIn(login):
                VStack(spacing: 10) {
                    authHeader(
                        systemImage: "keyboard",
                        title: "Token Coffee Device Code",
                        detail: "If ChatGPT asks for an Authenticator code, use your Authenticator app first."
                    )

                    Text(login.userCode ?? "Waiting...")
                        .font(.system(size: 28, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity)
                        .help("Codex device code")

                    Text("Enter this code only when the browser asks for a device code.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 10) {
                        Button {
                            if let url = login.verificationURL {
                                openURL(url)
                            }
                        } label: {
                            Label("Open", systemImage: "safari")
                                .frame(minWidth: 82)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(login.verificationURL == nil)
                        .help("Open Codex sign-in page")

                        Button {
                            copyCodexCode(login.userCode)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                                .frame(minWidth: 76)
                        }
                        .buttonStyle(.bordered)
                        .disabled(login.userCode == nil)
                        .help("Copy device code")

                        Button {
                            model.cancelCodexSignIn()
                        } label: {
                            Label("Cancel", systemImage: "xmark.circle")
                                .frame(minWidth: 82)
                        }
                        .buttonStyle(.bordered)
                        .help("Cancel Codex sign-in")
                    }
                    .controlSize(.regular)
                }

            case .signedIn:
                EmptyView()

            case let .failed(message):
                VStack(spacing: 14) {
                    authHeader(
                        systemImage: "exclamationmark.triangle",
                        title: "Sign-In Failed",
                        detail: shortSignInErrorMessage(message),
                        iconColor: .orange
                    )

                    Button {
                        model.beginCodexSignIn()
                    } label: {
                        Label("Try again", systemImage: "arrow.clockwise")
                            .frame(minWidth: 112)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .help(message)
                }
            }

            Spacer(minLength: 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 26)
    }

    private func authHeader(
        systemImage: String? = nil,
        title: String,
        detail: String,
        iconColor: Color = .blue
    ) -> some View {
        VStack(spacing: 7) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 28, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(iconColor)
            }

            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func copyCodexCode(_ code: String?) {
        guard let code else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }

    private func shortSignInErrorMessage(_ message: String) -> String {
        if message.localizedCaseInsensitiveContains("Login was not completed") {
            return "That sign-in expired before Codex finished it."
        }
        if message.localizedCaseInsensitiveContains("Timed out") {
            return "Codex did not respond in time. Try again."
        }
        if message.count <= 96 {
            return message
        }
        return "\(message.prefix(93))..."
    }

    private var syncStatusDisplay: (text: String, systemImage: String, color: Color, help: String) {
        switch model.quotaSyncStatus {
        case .localOnly:
            ("local", "externaldrive", .secondary, "CloudKit sync is disabled for this build")
        case .syncing:
            ("syncing", "arrow.triangle.2.circlepath", .secondary, "Syncing quota samples with iCloud")
        case let .synced(date):
            (
                "iCloud \(DateFormatter.panelTime.string(from: date))",
                "icloud",
                .secondary,
                "Quota samples synced with iCloud"
            )
        case let .unavailable(message):
            ("iCloud off", "icloud.slash", .orange, message)
        case let .failed(message):
            ("sync failed", "exclamationmark.icloud", .orange, message)
        }
    }

    private var renewalValue: String {
        guard let resetDate = model.projection.weeklyResetDate else {
            switch model.codexSignInState {
            case .needsSignIn, .startingSignIn, .signingIn(_):
                return "sign in"
            case .unknown, .signedIn, .failed:
                break
            }
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
            "ok"
        case .watch:
            "careful"
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
        if estimate >= 100 {
            return .red
        }
        if estimate >= 90 {
            return .orange
        }
        return .green
    }

    private func shortQuotaErrorMessage(_ message: String) -> String {
        if message.localizedCaseInsensitiveContains("Timed out") {
            return "Codex timeout"
        }
        if message.localizedCaseInsensitiveContains("process exited") {
            return "Codex exited"
        }
        if message.localizedCaseInsensitiveContains("process is not running") {
            return "Codex stopped"
        }
        if message.count <= 32 {
            return message
        }
        return "\(message.prefix(29))..."
    }
}

private struct QuotaGraphView: View {
    let samples: [QuotaSample]
    let projection: QuotaProjection
    let snapshot: RateLimitSnapshot?
    let now: Date

    var body: some View {
        if let resetDate = projection.weeklyResetDate {
            let startDate = graphStartDate(resetDate: resetDate)
            Chart {
                ForEach(dayBands(startDate: startDate, resetDate: resetDate)) { band in
                    RectangleMark(
                        xStart: .value("Start", band.startDate),
                        xEnd: .value("End", band.endDate),
                        yStart: .value("Low", 0),
                        yEnd: .value("High", 105)
                    )
                    .foregroundStyle(band.isHighlighted ? Color.primary.opacity(0.035) : Color.clear)
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

                if projection.cycleRunForecast == nil,
                   let projected = projection.projectedWeeklyUsedPercentAtReset {
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
            return [GraphPoint(date: now, percent: graphPercent(weekly.usedPercent), series: "actual")]
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

                let forecastPath = forecastPath(in: size)
                drawThresholded(
                    path: forecastPath,
                    in: size,
                    context: &context,
                    belowColor: .blue.opacity(0.28),
                    aboveColor: .red.opacity(0.46),
                    lineWidth: 4.5,
                    lineCap: .butt,
                    lineJoin: .round
                )
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private func forecastPath(in size: CGSize) -> Path {
        var path = Path()
        var hasCurrentPoint = false
        let segments = forecast.lineSegments
            .sorted { $0.startDate < $1.startDate }
            .filter { $0.endDate > $0.startDate }

        for segment in segments {
            if hasCurrentPoint == false {
                path.move(to: plotPoint(date: segment.startDate, percent: segment.startUsedPercent, in: size))
                hasCurrentPoint = true
            }
            path.addLine(to: plotPoint(date: segment.endDate, percent: segment.endUsedPercent, in: size))
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
