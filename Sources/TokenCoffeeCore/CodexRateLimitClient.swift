import Foundation

public struct CodexAccountSnapshot: Equatable, Sendable {
    public let type: String
    public let email: String?
    public let planType: String?

    public init(type: String, email: String?, planType: String?) {
        self.type = type
        self.email = email
        self.planType = planType
    }
}

public struct CodexDeviceCodeLogin: Equatable, Sendable {
    public let loginId: String?
    public let verificationURL: URL?
    public let userCode: String?

    public init(loginId: String?, verificationURL: URL?, userCode: String?) {
        self.loginId = loginId
        self.verificationURL = verificationURL
        self.userCode = userCode
    }
}

public struct CodexRateLimitFetchResult: Sendable {
    public let response: CodexRateLimitsResponse
    public let account: CodexAccountSnapshot?

    public init(response: CodexRateLimitsResponse, account: CodexAccountSnapshot?) {
        self.response = response
        self.account = account
    }
}

public enum CodexRateLimitEvent: Equatable, Sendable {
    case accountChanged(CodexAccountSnapshot?)
    case needsSignIn
    case loginStarted(CodexDeviceCodeLogin)
    case loginCompleted(success: Bool, errorMessage: String?)
    case rateLimitsChanged(CodexRateLimitsResponse)
    case diagnostic(String)
}

public actor CodexRateLimitClient {
    public enum ClientError: Error, Equatable, LocalizedError, Sendable {
        case codexNotFound(String)
        case needsSignIn
        case timedOut
        case invalidResponse(String)
        case serverError(String)

        public var errorDescription: String? {
            switch self {
            case let .codexNotFound(message):
                "Codex integration is unavailable. \(message)"
            case .needsSignIn:
                "Codex needs ChatGPT sign-in."
            case .timedOut:
                "Timed out while reading Codex rate limits."
            case let .invalidResponse(message):
                "Invalid Codex rate-limit response: \(message)"
            case let .serverError(message):
                "Codex usage service returned an error: \(message)"
            }
        }
    }

    public nonisolated var events: AsyncStream<CodexRateLimitEvent> {
        eventsBox.stream
    }

    private nonisolated let eventsBox = CodexEventStreamBox<CodexRateLimitEvent>()
    private let authService: CodexNativeAuthService
    private let usageService: CodexNativeUsageService
    private let timeout: TimeInterval
    private var loginTask: Task<Void, Never>?
    private var activeLoginId: String?

    public init(
        executableURL: URL? = nil,
        codexHomeDirectory: URL? = nil,
        timeout: TimeInterval = 12,
        startupTimeout: TimeInterval = 60
    ) {
        let configuration = CodexNativeConfiguration.defaultConfiguration()
        let httpClient = URLSessionCodexHTTPClient()
        let tokenStore = KeychainCodexAuthTokenStore()
        self.authService = CodexNativeAuthService(
            configuration: configuration,
            httpClient: httpClient,
            tokenStore: tokenStore
        )
        self.usageService = CodexNativeUsageService(
            configuration: configuration,
            httpClient: httpClient
        )
        self.timeout = timeout

        _ = executableURL
        _ = codexHomeDirectory
        _ = startupTimeout
    }

    init(
        configuration: CodexNativeConfiguration,
        httpClient: CodexHTTPClient,
        tokenStore: CodexAuthTokenStore,
        timeout: TimeInterval = 12
    ) {
        self.authService = CodexNativeAuthService(
            configuration: configuration,
            httpClient: httpClient,
            tokenStore: tokenStore
        )
        self.usageService = CodexNativeUsageService(
            configuration: configuration,
            httpClient: httpClient
        )
        self.timeout = timeout
    }

    public func fetch() async throws -> CodexRateLimitFetchResult {
        do {
            eventsBox.yield(.diagnostic("Reading Codex account."))
            let tokens = try await withTimeout {
                try await self.authService.validTokens(refreshIfNeeded: true)
            }
            guard let tokens else {
                eventsBox.yield(.needsSignIn)
                throw ClientError.needsSignIn
            }

            let account = authService.accountSnapshot(for: tokens)
            eventsBox.yield(.accountChanged(account))

            eventsBox.yield(.diagnostic("Reading Codex rate limits."))
            let response = try await readRateLimitsWithOneRefresh(tokens: tokens)
            eventsBox.yield(.rateLimitsChanged(response))
            return CodexRateLimitFetchResult(response: response, account: account)
        } catch {
            let mappedError = await mapError(error)
            if mappedError as? ClientError != .needsSignIn {
                eventsBox.yield(.diagnostic(mappedError.localizedDescription))
            }
            throw mappedError
        }
    }

    public func beginDeviceCodeLogin() async throws -> CodexDeviceCodeLogin {
        loginTask?.cancel()
        loginTask = nil
        activeLoginId = nil

        let deviceCode = try await withTimeout {
            try await self.authService.requestDeviceCode()
        }
        let login = CodexDeviceCodeLogin(
            loginId: deviceCode.deviceAuthId,
            verificationURL: deviceCode.verificationURL,
            userCode: deviceCode.userCode
        )
        activeLoginId = deviceCode.deviceAuthId
        eventsBox.yield(.loginStarted(login))

        loginTask = Task { [eventsBox] in
            do {
                let tokens = try await self.authService.completeDeviceCodeLogin(deviceCode)
                let account = self.authService.accountSnapshot(for: tokens)
                eventsBox.yield(.loginCompleted(success: true, errorMessage: nil))
                eventsBox.yield(.accountChanged(account))
            } catch is CancellationError {
                eventsBox.yield(.diagnostic("Codex sign-in was cancelled."))
            } catch {
                eventsBox.yield(.loginCompleted(success: false, errorMessage: error.localizedDescription))
            }
        }

        return login
    }

    public func cancelLogin(loginId: String?) async {
        guard loginId == nil || loginId == activeLoginId else {
            return
        }
        loginTask?.cancel()
        loginTask = nil
        activeLoginId = nil
    }

    public func logout() async throws {
        loginTask?.cancel()
        loginTask = nil
        activeLoginId = nil
        try await authService.logout()
        eventsBox.yield(.accountChanged(nil))
        eventsBox.yield(.needsSignIn)
    }

    public func stop() async {
        loginTask?.cancel()
        loginTask = nil
        activeLoginId = nil
    }

    private func readRateLimitsWithOneRefresh(tokens: CodexAuthTokens) async throws -> CodexRateLimitsResponse {
        do {
            return try await withTimeout {
                try await self.usageService.fetchRateLimits(tokens: tokens)
            }
        } catch CodexNativeAuthError.unauthorized {
            let refreshed = try await withTimeout {
                try await self.authService.refreshStoredTokens()
            }
            return try await withTimeout {
                try await self.usageService.fetchRateLimits(tokens: refreshed)
            }
        } catch CodexNativeUsageError.unauthorized {
            let refreshed = try await withTimeout {
                try await self.authService.refreshStoredTokens()
            }
            return try await withTimeout {
                try await self.usageService.fetchRateLimits(tokens: refreshed)
            }
        }
    }

    private func withTimeout<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withTimeout(seconds: timeout, operation)
    }

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
                throw ClientError.timedOut
            }

            guard let result = try await group.next() else {
                throw ClientError.invalidResponse("Codex usage service did not return a result.")
            }
            group.cancelAll()
            return result
        }
    }

    private func mapError(_ error: Error) async -> Error {
        if let clientError = error as? ClientError {
            return clientError
        }

        if let authError = error as? CodexNativeAuthError {
            switch authError {
            case .needsSignIn, .unauthorized:
                eventsBox.yield(.needsSignIn)
                return ClientError.needsSignIn
            case .loginTimedOut:
                return ClientError.timedOut
            case let .invalidResponse(message):
                return ClientError.invalidResponse(message)
            case let .server(message):
                return ClientError.serverError(message)
            }
        }

        if let usageError = error as? CodexNativeUsageError {
            switch usageError {
            case .unauthorized:
                eventsBox.yield(.needsSignIn)
                return ClientError.needsSignIn
            case let .invalidResponse(message):
                return ClientError.invalidResponse(message)
            case let .server(message):
                return ClientError.serverError(message)
            }
        }

        return error
    }
}

private final class CodexEventStreamBox<Element: Sendable>: @unchecked Sendable {
    let stream: AsyncStream<Element>
    private let continuation: AsyncStream<Element>.Continuation

    init() {
        var continuation: AsyncStream<Element>.Continuation?
        stream = AsyncStream<Element>(bufferingPolicy: .bufferingNewest(200)) {
            continuation = $0
        }
        self.continuation = continuation!
    }

    func yield(_ value: Element) {
        continuation.yield(value)
    }
}
