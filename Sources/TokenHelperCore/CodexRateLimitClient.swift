import Foundation

public struct CodexRateLimitClient: Sendable {
    public enum ClientError: Error, Equatable, LocalizedError, Sendable {
        case codexNotFound
        case launchFailed(String)
        case timedOut
        case invalidResponse(String)
        case serverError(String)

        public var errorDescription: String? {
            switch self {
            case .codexNotFound:
                "Could not find the codex executable."
            case let .launchFailed(message):
                "Could not launch codex: \(message)"
            case .timedOut:
                "Timed out while reading Codex rate limits."
            case let .invalidResponse(message):
                "Invalid Codex rate-limit response: \(message)"
            case let .serverError(message):
                "Codex app-server returned an error: \(message)"
            }
        }
    }

    public var codexExecutableURL: URL?
    public var timeout: TimeInterval

    public init(codexExecutableURL: URL? = nil, timeout: TimeInterval = 12) {
        self.codexExecutableURL = codexExecutableURL
        self.timeout = timeout
    }

    public func fetch() throws -> CodexRateLimitsResponse {
        guard let executableURL = codexExecutableURL ?? Self.locateCodexExecutable() else {
            throw ClientError.codexNotFound
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["app-server", "--listen", "stdio://"]

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let outputBuffer = LockedDataBuffer()
        let errorBuffer = LockedDataBuffer()
        let outputUpdated = DispatchSemaphore(value: 0)
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                return
            }
            outputBuffer.append(data)
            outputUpdated.signal()
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                return
            }
            errorBuffer.append(data)
        }

        do {
            try process.run()
        } catch {
            throw ClientError.launchFailed(error.localizedDescription)
        }

        defer {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            try? inputPipe.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        let input = inputPipe.fileHandleForWriting
        try writeLine(
            #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"TokenHelper","version":"0.1"}}}"#,
            to: input
        )
        Thread.sleep(forTimeInterval: 0.35)
        try writeLine(#"{"id":2,"method":"account/rateLimits/read"}"#, to: input)

        // The app-server can drop the second request if stdin is closed before it answers.
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            do {
                if let response = try parseRateLimitResponse(from: outputBuffer.stringValue) {
                    return response
                }
            } catch {
                throw error
            }

            if !process.isRunning {
                break
            }

            _ = outputUpdated.wait(timeout: .now() + 0.1)
        }

        if process.isRunning {
            throw ClientError.timedOut
        }

        let output = outputBuffer.stringValue
        let errorOutput = errorBuffer.stringValue
        if let response = try parseRateLimitResponse(from: output) {
            return response
        }

        let combined = [output, errorOutput]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        throw ClientError.invalidResponse(combined.isEmpty ? "No output from codex app-server." : combined)
    }

    public static func locateCodexExecutable(
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        environmentPath: String? = ProcessInfo.processInfo.environment["PATH"]
    ) -> URL? {
        if let override = userDefaults.string(forKey: "codexExecutablePath"),
           fileManager.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }

        for path in ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/usr/bin/codex"] where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        for directory in environmentPath?.split(separator: ":") ?? [] {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("codex").path
            if fileManager.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }

        return nil
    }

    private func writeLine(_ line: String, to handle: FileHandle) throws {
        guard let data = "\(line)\n".data(using: .utf8) else {
            throw ClientError.invalidResponse("Could not encode request.")
        }
        try handle.write(contentsOf: data)
    }

    func parseRateLimitResponse(from output: String) throws -> CodexRateLimitsResponse? {
        let decoder = JSONDecoder()

        for line in output.split(whereSeparator: \.isNewline) {
            let data = Data(line.utf8)
            if let envelope = try? decoder.decode(RateLimitEnvelope.self, from: data),
               envelope.id == 2 {
                if let error = envelope.error {
                    throw ClientError.serverError(error.message)
                }
                guard let result = envelope.result else {
                    throw ClientError.invalidResponse(String(line))
                }
                return result
            }
        }

        return nil
    }
}

private final class LockedDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    var stringValue: String {
        lock.withLock {
            String(decoding: data, as: UTF8.self)
        }
    }

    func append(_ newData: Data) {
        lock.withLock {
            data.append(newData)
        }
    }
}

private struct RateLimitEnvelope: Decodable {
    let id: Int?
    let result: CodexRateLimitsResponse?
    let error: JSONRPCError?
}

private struct JSONRPCError: Decodable {
    let message: String
}
