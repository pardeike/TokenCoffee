import CodexAppServerKit
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
                "Could not find the bundled Codex executable. \(message)"
            case .needsSignIn:
                "Codex needs ChatGPT sign-in."
            case .timedOut:
                "Timed out while reading Codex rate limits."
            case let .invalidResponse(message):
                "Invalid Codex rate-limit response: \(message)"
            case let .serverError(message):
                "Codex app-server returned an error: \(message)"
            }
        }
    }

    public nonisolated var events: AsyncStream<CodexRateLimitEvent> {
        eventsBox.stream
    }

    private nonisolated let eventsBox = CodexEventStreamBox<CodexRateLimitEvent>()
    private let executableURL: URL?
    private let codexHomeDirectory: URL?
    private let timeout: TimeInterval
    private let startupTimeout: TimeInterval
    private var client: CodexAppServerClient?
    private var notificationTask: Task<Void, Never>?
    private var diagnosticTask: Task<Void, Never>?

    public init(
        executableURL: URL? = nil,
        codexHomeDirectory: URL? = nil,
        timeout: TimeInterval = 12,
        startupTimeout: TimeInterval = 60
    ) {
        self.executableURL = executableURL
        self.codexHomeDirectory = codexHomeDirectory
        self.timeout = timeout
        self.startupTimeout = startupTimeout
    }

    public func fetch() async throws -> CodexRateLimitFetchResult {
        do {
            let client = try await ensureClient()
            eventsBox.yield(.diagnostic("Reading Codex account."))
            let accountResult = try await withTimeout {
                try await client.readAccount(refreshToken: false)
            }
            let account = Self.mapAccount(accountResult.account)
            eventsBox.yield(.accountChanged(account))

            if accountResult.account == nil, accountResult.requiresOpenaiAuth != false {
                eventsBox.yield(.needsSignIn)
                throw ClientError.needsSignIn
            }

            eventsBox.yield(.diagnostic("Reading Codex rate limits."))
            let rateLimits = try await withTimeout {
                try await client.readRateLimits()
            }
            let response = try Self.mapRateLimits(rateLimits)
            eventsBox.yield(.rateLimitsChanged(response))
            return CodexRateLimitFetchResult(response: response, account: account)
        } catch {
            let mappedError = mapError(error)
            if shouldResetClient(after: mappedError) {
                await resetClient()
            }
            if mappedError as? ClientError != .needsSignIn {
                eventsBox.yield(.diagnostic(mappedError.localizedDescription))
            }
            throw mappedError
        }
    }

    public func beginDeviceCodeLogin() async throws -> CodexDeviceCodeLogin {
        let client = try await ensureClient()
        let login = try await withTimeout {
            try await client.startChatGPTDeviceCodeLogin()
        }
        let result = CodexDeviceCodeLogin(
            loginId: login.loginId,
            verificationURL: login.verificationURL,
            userCode: login.userCode
        )
        eventsBox.yield(.loginStarted(result))
        return result
    }

    public func cancelLogin(loginId: String?) async {
        guard let loginId else {
            return
        }
        do {
            let client = try await ensureClient()
            try await withTimeout {
                try await client.cancelLogin(loginId: loginId)
            }
        } catch {
            eventsBox.yield(.diagnostic(error.localizedDescription))
        }
    }

    public func logout() async throws {
        let client = try await ensureClient()
        try await withTimeout {
            try await client.logout()
        }
        eventsBox.yield(.accountChanged(nil))
        eventsBox.yield(.needsSignIn)
    }

    public func stop() async {
        notificationTask?.cancel()
        diagnosticTask?.cancel()
        notificationTask = nil
        diagnosticTask = nil
        if let client {
            await client.stop()
        }
        client = nil
    }

    private func ensureClient() async throws -> CodexAppServerClient {
        if let client {
            return client
        }

        let executableURL: URL
        do {
            executableURL = try self.executableURL ?? CodexAppServerConfiguration.bundledExecutable(named: "codex")
        } catch {
            throw ClientError.codexNotFound(error.localizedDescription)
        }

        let configuration = CodexAppServerConfiguration(
            executableURL: executableURL,
            codexHomeDirectory: codexHomeDirectory ?? CodexAppServerConfiguration.defaultCodexHomeDirectory(),
            clientInfo: CodexClientInfo(
                name: "token_coffee",
                title: "Token Coffee",
                version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
            )
        )
        let client = CodexAppServerClient(configuration: configuration)
        startObserving(client: client)

        do {
            eventsBox.yield(.diagnostic("Starting Codex app-server."))
            try await withTimeout(seconds: startupTimeout) {
                try await client.start()
            }
            eventsBox.yield(.diagnostic("Codex app-server started."))
        } catch {
            await client.stop()
            self.client = nil
            throw mapError(error)
        }

        self.client = client
        return client
    }

    private func startObserving(client: CodexAppServerClient) {
        notificationTask?.cancel()
        diagnosticTask?.cancel()

        notificationTask = Task { [weak self, client] in
            for await notification in client.notifications {
                await self?.handle(notification)
            }
        }

        diagnosticTask = Task { [eventsBox, client] in
            for await line in client.diagnostics {
                eventsBox.yield(.diagnostic(line))
            }
        }
    }

    private func handle(_ notification: CodexNotification) async {
        switch notification.method {
        case "account/login/completed":
            do {
                let completed = try notification.decodedParams(as: CodexLoginCompletedNotification.self)
                eventsBox.yield(.loginCompleted(success: completed.success, errorMessage: completed.error))
            } catch {
                eventsBox.yield(.diagnostic(error.localizedDescription))
            }

        case "account/updated":
            do {
                let updated = try notification.decodedParams(as: CodexAccountUpdatedNotification.self)
                let account = updated.authMode.map {
                    CodexAccountSnapshot(type: $0, email: nil, planType: updated.planType)
                }
                eventsBox.yield(.accountChanged(account))
            } catch {
                eventsBox.yield(.diagnostic(error.localizedDescription))
            }

        case "account/rateLimits/updated":
            do {
                let rateLimits = try notification.decodedParams(as: CodexRateLimitsReadResult.self)
                eventsBox.yield(.rateLimitsChanged(try Self.mapRateLimits(rateLimits)))
            } catch {
                eventsBox.yield(.diagnostic(error.localizedDescription))
            }

        default:
            break
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
                throw ClientError.invalidResponse("Codex app-server did not return a result.")
            }
            group.cancelAll()
            return result
        }
    }

    private func mapError(_ error: Error) -> Error {
        if let clientError = error as? ClientError {
            return clientError
        }
        if let codexError = error as? CodexError {
            switch codexError {
            case let .rpcError(_, message, _):
                return ClientError.serverError(message)
            case let .executableNotFound(searchedNames):
                return ClientError.codexNotFound(searchedNames.joined(separator: ", "))
            default:
                return ClientError.serverError(codexError.localizedDescription)
            }
        }
        return error
    }

    private func shouldResetClient(after error: Error) -> Bool {
        if let clientError = error as? ClientError {
            switch clientError {
            case .timedOut, .invalidResponse, .serverError, .codexNotFound:
                return true
            case .needsSignIn:
                return false
            }
        }

        if let codexError = error as? CodexError {
            switch codexError {
            case .processExited, .processNotRunning, .processLaunchFailed, .malformedMessage, .cancelled:
                return true
            case .executableNotFound, .processAlreadyRunning, .missingField, .invalidURL, .rpcError:
                return false
            }
        }

        return false
    }

    private func resetClient() async {
        if let client {
            await client.stop()
        }
        client = nil
    }

    private static func mapAccount(_ account: CodexAccount?) -> CodexAccountSnapshot? {
        account.map {
            CodexAccountSnapshot(type: $0.type, email: $0.email, planType: $0.planType)
        }
    }

    private static func mapRateLimits(_ result: CodexRateLimitsReadResult) throws -> CodexRateLimitsResponse {
        guard let preferredBucket = result.preferredBucket else {
            throw ClientError.invalidResponse("Codex app-server returned no rate-limit buckets.")
        }

        var mappedBuckets: [String: RateLimitSnapshot]?
        if let buckets = result.rateLimitsByLimitId {
            mappedBuckets = [:]
            for (key, bucket) in buckets {
                mappedBuckets?[key] = mapBucket(bucket)
            }
        }

        return CodexRateLimitsResponse(
            rateLimits: mapBucket(preferredBucket),
            rateLimitsByLimitId: mappedBuckets
        )
    }

    private static func mapBucket(_ bucket: CodexRateLimitBucket) -> RateLimitSnapshot {
        RateLimitSnapshot(
            limitId: bucket.limitId,
            limitName: bucket.limitName,
            primary: mapWindow(bucket.primary),
            secondary: mapWindow(bucket.secondary),
            credits: mapCredits(bucket.credits),
            planType: bucket.planType,
            rateLimitReachedType: bucket.rateLimitReachedType
        )
    }

    private static func mapWindow(_ window: CodexAppServerKit.CodexRateLimitWindow?) -> RateLimitWindow? {
        guard let window, let usedPercent = window.usedPercent else {
            return nil
        }

        return RateLimitWindow(
            usedPercent: usedPercent,
            windowDurationMins: window.windowDurationMins.map { Int($0.rounded()) },
            resetsAt: window.resetsAt.map { Int($0) }
        )
    }

    private static func mapCredits(_ value: CodexJSONValue?) -> CreditsSnapshot? {
        guard let value else {
            return nil
        }
        return try? value.decoded(as: CreditsSnapshot.self)
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
