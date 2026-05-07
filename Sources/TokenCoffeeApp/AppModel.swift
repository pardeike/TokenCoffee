import Combine
import Foundation
import TokenCoffeeCore

enum CodexSignInState: Equatable {
    case unknown
    case needsSignIn
    case startingSignIn
    case signingIn(CodexDeviceCodeLogin)
    case signedIn(CodexAccountSnapshot?)
    case failed(String)
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var powerMode: PowerSessionMode = .off
    @Published private(set) var powerErrorMessage: String?
    @Published private(set) var quotaSnapshot: RateLimitSnapshot?
    @Published private(set) var quotaSamples: [QuotaSample] = []
    @Published private(set) var lastQuotaRefresh: Date?
    @Published private(set) var lastQuotaErrorDate: Date?
    @Published private(set) var lastQuotaErrorMessage: String?
    @Published private(set) var isRefreshingQuota = false
    @Published private(set) var quotaSyncStatus: QuotaSyncStatus = .localOnly
    @Published private(set) var codexSignInState: CodexSignInState = .unknown

    private let powerController: PowerSessionController
    private let quotaClient: CodexRateLimitClient
    private let sampleStore: QuotaSampleStore
    private let sampleSyncService: CloudQuotaSampleSyncService
    private let failSafeInstaller: ClamshellFailSafeInstaller
    private let demoScenario: DemoQuotaScenario?
    private var refreshTimer: Timer?
    private var quotaClientEventTask: Task<Void, Never>?
    private var activeCodexLogin: CodexDeviceCodeLogin?

    init(
        powerController: PowerSessionController,
        quotaClient: CodexRateLimitClient,
        sampleStore: QuotaSampleStore,
        sampleSyncService: CloudQuotaSampleSyncService,
        failSafeInstaller: ClamshellFailSafeInstaller,
        demoScenario: DemoQuotaScenario? = nil
    ) {
        self.powerController = powerController
        self.quotaClient = quotaClient
        self.sampleStore = sampleStore
        self.sampleSyncService = sampleSyncService
        self.failSafeInstaller = failSafeInstaller
        self.demoScenario = demoScenario
        self.powerMode = demoScenario == nil ? TokenCoffeeDefaults.preferredPowerMode() : .keepAwakeDisplay
    }

    var projection: QuotaProjection {
        QuotaProjectionEngine.make(snapshot: quotaSnapshot, samples: quotaSamples, now: referenceDate)
    }

    var referenceDate: Date {
        demoScenario?.now ?? Date()
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
        let now = referenceDate
        return quotaSamples
            .filter { $0.limitId == limitId && $0.capturedAt >= startDate && $0.capturedAt <= now }
            .sorted { $0.capturedAt < $1.capturedAt }
    }

    func start() {
        TokenCoffeeDefaults.setClosedDisplayModeEnabled(false)
        if let demoScenario {
            startDemoMode(demoScenario)
            return
        }

        if let executableURL = Bundle.main.executableURL {
            try? failSafeInstaller.install(bundleExecutableURL: executableURL)
        }
        if powerMode != .off {
            applyPowerConfiguration()
        }
        startQuotaClientEvents()
        quotaSamples = (try? sampleStore.load()) ?? []
        refreshQuota()
        scheduleRefreshTimer()
    }

    func shutdown() {
        refreshTimer?.invalidate()
        quotaClientEventTask?.cancel()
        try? powerController.apply(mode: .off)
        TokenCoffeeDefaults.setClosedDisplayModeEnabled(false)
        let quotaClient = quotaClient
        Task {
            await quotaClient.stop()
        }
    }

    func setPanelVisible(_ visible: Bool) {
        if visible, demoScenario == nil {
            refreshQuota()
        }
    }

    func setPowerMode(_ mode: PowerSessionMode) {
        if demoScenario != nil {
            powerMode = .keepAwakeDisplay
            return
        }

        guard powerMode != mode else {
            return
        }
        powerMode = mode
        TokenCoffeeDefaults.setPreferredPowerMode(mode)
        applyPowerConfiguration()
    }

    func refreshQuota() {
        guard demoScenario == nil else {
            return
        }
        guard !isRefreshingQuota else {
            return
        }

        isRefreshingQuota = true
        let client = quotaClient
        let store = sampleStore
        let syncService = sampleSyncService

        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                await Self.fetchQuotaSnapshot(client: client, store: store, syncService: syncService)
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
                self.lastQuotaErrorMessage = nil
                self.codexSignInState = .signedIn(fetchResult.account)
                self.quotaSyncStatus = fetchResult.syncStatus
            case let .failure(error):
                if error as? CodexRateLimitClient.ClientError == .needsSignIn {
                    guard !self.codexSignInState.isLoginFlowActive else {
                        return
                    }
                    self.activeCodexLogin = nil
                    self.codexSignInState = .needsSignIn
                    self.lastQuotaErrorDate = nil
                    self.lastQuotaErrorMessage = nil
                } else {
                    self.lastQuotaErrorDate = Date()
                    self.lastQuotaErrorMessage = error.localizedDescription
                }
            }
        }
    }

    func beginCodexSignIn() {
        guard demoScenario == nil else {
            return
        }
        guard !codexSignInState.isLoginFlowActive else {
            return
        }

        let shouldResetBeforeStart = codexSignInState.shouldResetClientBeforeLoginStart
        let previousLogin = activeCodexLogin
        activeCodexLogin = nil
        codexSignInState = .startingSignIn
        lastQuotaErrorDate = nil
        lastQuotaErrorMessage = nil

        let client = quotaClient
        Task { [weak self] in
            if let loginId = previousLogin?.loginId {
                await client.cancelLogin(loginId: loginId)
            }
            if shouldResetBeforeStart {
                await client.stop()
            }

            do {
                let login = try await Self.beginDeviceCodeLoginWithOneRestart(client: client)
                guard let self else {
                    return
                }
                self.activeCodexLogin = login
                self.codexSignInState = .signingIn(login)
                self.lastQuotaErrorDate = nil
                self.lastQuotaErrorMessage = nil
            } catch {
                guard let self else {
                    return
                }
                let message = Self.loginErrorMessage(for: error)
                if Self.isRestartableLoginStartFailure(error) {
                    await client.stop()
                }
                self.activeCodexLogin = nil
                self.codexSignInState = .failed(message)
                self.lastQuotaErrorDate = Date()
                self.lastQuotaErrorMessage = message
            }
        }
    }

    func cancelCodexSignIn() {
        let stateLoginId: String? = if case let .signingIn(login) = codexSignInState {
            login.loginId
        } else {
            nil
        }
        let loginId = activeCodexLogin?.loginId ?? stateLoginId

        activeCodexLogin = nil
        codexSignInState = .needsSignIn
        let client = quotaClient
        Task {
            await client.cancelLogin(loginId: loginId)
            if loginId == nil {
                await client.stop()
            }
        }
    }

    func logoutCodex() {
        guard demoScenario == nil else {
            return
        }

        activeCodexLogin = nil
        quotaSnapshot = nil
        lastQuotaErrorDate = nil
        lastQuotaErrorMessage = nil
        codexSignInState = .needsSignIn

        let client = quotaClient
        Task { [weak self] in
            do {
                try await client.logout()
                await client.stop()
            } catch {
                await client.stop()
                guard let self else {
                    return
                }
                self.lastQuotaErrorDate = Date()
                self.lastQuotaErrorMessage = error.localizedDescription
                self.codexSignInState = .failed(error.localizedDescription)
            }
        }
    }

    private nonisolated static func beginDeviceCodeLoginWithOneRestart(
        client: CodexRateLimitClient
    ) async throws -> CodexDeviceCodeLogin {
        do {
            return try await client.beginDeviceCodeLogin()
        } catch {
            guard isRestartableLoginStartFailure(error) else {
                throw error
            }
            await client.stop()
            return try await client.beginDeviceCodeLogin()
        }
    }

    private nonisolated static func isRestartableLoginStartFailure(_ error: Error) -> Bool {
        error.localizedDescription.localizedCaseInsensitiveContains("Login was not completed")
    }

    private nonisolated static func loginErrorMessage(for error: Error) -> String {
        if isRestartableLoginStartFailure(error) {
            return "Previous Codex sign-in was not completed. Try signing in again."
        }
        return error.localizedDescription
    }

    private nonisolated static func fetchQuotaSnapshot(
        client: CodexRateLimitClient,
        store: QuotaSampleStore,
        syncService: CloudQuotaSampleSyncService
    ) async -> Result<QuotaFetchResult, Error> {
        do {
            let fetchResult = try await client.fetch()
            let response = fetchResult.response
            let snapshot = response.codexSnapshot
            let capturedAt = Date()
            var samples = (try? store.load()) ?? []
            if let sample = QuotaSample(snapshot: snapshot, capturedAt: capturedAt) {
                samples = (try? store.merge([sample])) ?? QuotaSampleStore.mergedSamples(samples + [sample])
            }

            let syncOutcome = await syncService.sync(localSamples: samples)
            let persistedSamples = (try? store.merge(syncOutcome.samples)) ?? syncOutcome.samples
            return .success(QuotaFetchResult(
                snapshot: snapshot,
                samples: persistedSamples,
                capturedAt: capturedAt,
                account: fetchResult.account,
                syncStatus: syncOutcome.status
            ))
        } catch {
            return .failure(error)
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

    private func startQuotaClientEvents() {
        guard quotaClientEventTask == nil else {
            return
        }

        let events = quotaClient.events
        quotaClientEventTask = Task { [weak self] in
            for await event in events {
                self?.handleQuotaClientEvent(event)
            }
        }
    }

    private func handleQuotaClientEvent(_ event: CodexRateLimitEvent) {
        switch event {
        case let .accountChanged(account):
            if let account {
                activeCodexLogin = nil
                codexSignInState = .signedIn(account)
            } else if codexSignInState.isLoginFlowActive {
                break
            } else {
                activeCodexLogin = nil
                codexSignInState = .needsSignIn
            }

        case .needsSignIn:
            if codexSignInState.isLoginFlowActive {
                break
            }
            activeCodexLogin = nil
            codexSignInState = .needsSignIn

        case let .loginStarted(login):
            activeCodexLogin = login
            codexSignInState = .signingIn(login)

        case let .loginCompleted(success, errorMessage):
            activeCodexLogin = nil
            if success {
                codexSignInState = .unknown
                refreshQuota()
            } else {
                let message = errorMessage ?? "Codex sign-in failed."
                codexSignInState = .failed(message)
                lastQuotaErrorDate = Date()
                lastQuotaErrorMessage = message
                let client = quotaClient
                Task {
                    await client.stop()
                }
            }

        case let .rateLimitsChanged(response):
            quotaSnapshot = response.codexSnapshot

        case let .diagnostic(message):
            if lastQuotaErrorDate != nil || quotaSnapshot == nil {
                lastQuotaErrorMessage = message
            }
        }
    }

    private func startDemoMode(_ scenario: DemoQuotaScenario) {
        powerMode = .keepAwakeDisplay
        powerErrorMessage = nil
        quotaSnapshot = scenario.snapshot
        quotaSamples = scenario.samples
        lastQuotaRefresh = scenario.now
        lastQuotaErrorDate = nil
        lastQuotaErrorMessage = nil
        isRefreshingQuota = false
        quotaSyncStatus = .localOnly
        activeCodexLogin = nil
        codexSignInState = .signedIn(scenario.account)
    }
}

private struct QuotaFetchResult: Sendable {
    let snapshot: RateLimitSnapshot
    let samples: [QuotaSample]
    let capturedAt: Date
    let account: CodexAccountSnapshot?
    let syncStatus: QuotaSyncStatus
}

private extension CodexSignInState {
    var isLoginFlowActive: Bool {
        switch self {
        case .startingSignIn, .signingIn:
            return true
        case .unknown, .needsSignIn, .signedIn, .failed:
            return false
        }
    }

    var shouldResetClientBeforeLoginStart: Bool {
        if case .failed = self {
            return true
        }
        return false
    }
}
