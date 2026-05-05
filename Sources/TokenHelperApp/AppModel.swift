import Combine
import Foundation
import TokenHelperCore

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var powerMode: PowerSessionMode = .off
    @Published private(set) var powerErrorMessage: String?
    @Published private(set) var quotaSnapshot: RateLimitSnapshot?
    @Published private(set) var quotaSamples: [QuotaSample] = []
    @Published private(set) var lastQuotaRefresh: Date?
    @Published private(set) var lastQuotaErrorDate: Date?
    @Published private(set) var isRefreshingQuota = false

    private let powerController: PowerSessionController
    private let quotaClient: CodexRateLimitClient
    private let sampleStore: QuotaSampleStore
    private let failSafeInstaller: ClamshellFailSafeInstaller
    private var refreshTimer: Timer?

    init(
        powerController: PowerSessionController,
        quotaClient: CodexRateLimitClient,
        sampleStore: QuotaSampleStore,
        failSafeInstaller: ClamshellFailSafeInstaller
    ) {
        self.powerController = powerController
        self.quotaClient = quotaClient
        self.sampleStore = sampleStore
        self.failSafeInstaller = failSafeInstaller
    }

    var projection: QuotaProjection {
        QuotaProjectionEngine.make(snapshot: quotaSnapshot, samples: quotaSamples)
    }

    var graphSamples: [QuotaSample] {
        guard let snapshot = quotaSnapshot,
              let weekly = snapshot.secondary,
              let resetDate = weekly.resetDate,
              let durationMinutes = weekly.windowDurationMins else {
            return []
        }

        let startDate = resetDate.addingTimeInterval(-TimeInterval(durationMinutes * 60))
        let limitId = snapshot.limitId ?? "codex"
        return quotaSamples
            .filter { $0.limitId == limitId && $0.capturedAt >= startDate && $0.capturedAt <= Date() }
            .sorted { $0.capturedAt < $1.capturedAt }
    }

    func start() {
        TokenHelperDefaults.setClosedDisplayModeEnabled(false)
        if let executableURL = Bundle.main.executableURL {
            try? failSafeInstaller.install(bundleExecutableURL: executableURL)
        }
        quotaSamples = (try? sampleStore.load()) ?? []
        refreshQuota()
        scheduleRefreshTimer()
    }

    func shutdown() {
        refreshTimer?.invalidate()
        try? powerController.apply(mode: .off)
        TokenHelperDefaults.setClosedDisplayModeEnabled(false)
    }

    func setPanelVisible(_ visible: Bool) {
        if visible {
            refreshQuota()
        }
    }

    func setPowerMode(_ mode: PowerSessionMode) {
        powerMode = mode
        applyPowerConfiguration()
    }

    func refreshQuota() {
        guard !isRefreshingQuota else {
            return
        }

        isRefreshingQuota = true
        let client = quotaClient
        let store = sampleStore

        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Self.fetchQuotaSnapshot(client: client, store: store)
            }.value

            guard let self else {
                return
            }

            self.isRefreshingQuota = false
            switch result {
            case let .success(fetchResult):
                self.quotaSnapshot = fetchResult.snapshot
                self.quotaSamples = fetchResult.samples
                self.lastQuotaRefresh = fetchResult.capturedAt
                self.lastQuotaErrorDate = nil
            case .failure:
                self.lastQuotaErrorDate = Date()
            }
        }
    }

    private nonisolated static func fetchQuotaSnapshot(
        client: CodexRateLimitClient,
        store: QuotaSampleStore
    ) -> Result<QuotaFetchResult, Error> {
        Result {
            let response = try client.fetch()
            let snapshot = response.codexSnapshot
            let capturedAt = Date()
            if let sample = QuotaSample(snapshot: snapshot, capturedAt: capturedAt) {
                try? store.append(sample)
            }
            let samples = (try? store.load()) ?? []
            return QuotaFetchResult(snapshot: snapshot, samples: samples, capturedAt: capturedAt)
        }
    }

    private func applyPowerConfiguration() {
        do {
            try powerController.apply(mode: powerMode)
            powerErrorMessage = nil
        } catch {
            powerErrorMessage = error.localizedDescription
        }
    }

    private func scheduleRefreshTimer() {
        refreshTimer?.invalidate()
        let interval: TimeInterval = 60
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshQuota()
            }
        }
        refreshTimer?.tolerance = min(30, interval / 4)
    }
}

private struct QuotaFetchResult: Sendable {
    let snapshot: RateLimitSnapshot
    let samples: [QuotaSample]
    let capturedAt: Date
}
