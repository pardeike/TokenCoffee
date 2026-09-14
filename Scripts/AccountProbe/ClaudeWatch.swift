import AppKit
import CryptoKit
import Darwin

/// Local, bounded renewal experiment. Only the official client writes its credential.
@MainActor
final class ClaudeWatch {
    private let root: URL
    private let profile: URL
    private let executable: URL
    private var task: Task<Void, Never>?
    private var child: Process?
    private var report: [String: String] = [:]

    init(root: URL, profile: URL, executable: URL) {
        self.root = root
        self.profile = profile
        self.executable = executable
        report = ["runID": CommandLine.arguments[3], "status": "starting",
            "pid": String(ProcessInfo.processInfo.processIdentifier), "startedAt": iso(Date()),
            "refreshOwner": "official_claude_cli", "intervalSeconds": "300"]
    }

    func start() {
        task = Task {
            do {
                let baseline = try NativeUsage.readCredential(profilePath: profile.path, allowExpired: true)
                let fingerprint = SHA256.hash(data: Data(baseline.accessToken.utf8))
                let initialExpiry = Date(timeIntervalSince1970: baseline.expiresAt / 1000)
                let deadline = min(Date().addingTimeInterval(24 * 3600), max(Date(), initialExpiry).addingTimeInterval(1800))
                report["status"] = "watching"
                report["initialExpiry"] = iso(initialExpiry)
                report["deadline"] = iso(deadline)
                var identity: String?
                var attempts = 0
                var requestFailures = 0
                while Date() < deadline {
                    try Task.checkCancellation()
                    var credential = try NativeUsage.readCredential(profilePath: profile.path, allowExpired: true)
                    if credential.expiresAt / 1000 <= Date().timeIntervalSince1970 + 90 {
                        guard attempts < 2 else { throw NativeUsage.Failure(diagnostic: "official_refresh_did_not_renew") }
                        attempts += 1
                        report["refreshAttempts"] = String(attempts)
                        report["lastRefreshAttempt"] = iso(Date())
                        try save()
                        try await touchOfficialAuth()
                        credential = try NativeUsage.readCredential(profilePath: profile.path, allowExpired: true)
                    }
                    let expiry = Date(timeIntervalSince1970: credential.expiresAt / 1000)
                    let changed = SHA256.hash(data: Data(credential.accessToken.utf8)) != fingerprint && expiry > initialExpiry
                    report["currentExpiry"] = iso(expiry)
                    report["credentialChanged"] = String(changed)
                    do {
                        let result = try await NativeUsage.fetchDiagrams(profilePath: profile.path, expectedIdentity: identity)
                        identity = result.0.identity
                        requestFailures = 0
                        report["lastSuccess"] = iso(Date())
                        report["usageStructure"] = result.2
                        report["diagrams"] = result.1.diagrams.map { "\($0.title): \($0.usedPercent)%" }.joined(separator: "; ")
                        // Safe diagnostic output: typed usage only, no profile payload or credentials.
                        let encoder = JSONEncoder()
                        encoder.dateEncodingStrategy = .iso8601
                        try encoder.encode(result.1.diagrams).write(to: root.appendingPathComponent("claude-watch-diagrams.json"), options: .atomic)
                        if changed, Date() >= initialExpiry {
                            report["status"] = "renewal_verified"
                            try save()
                            return
                        }
                    } catch let failure as NativeUsage.Failure {
                        if failure.diagnostic.contains("keychain") || failure.diagnostic.contains("identity") { throw failure }
                        requestFailures += 1
                        report["lastRequestFailure"] = failure.diagnostic
                        if failure.diagnostic.contains("429") {
                            report["nextAttemptAt"] = iso(Date().addingTimeInterval(900))
                            try save()
                            try await Task.sleep(for: .seconds(900))
                            continue
                        }
                        if requestFailures >= 3 { throw failure }
                    }
                    let untilRefresh = expiry.timeIntervalSinceNow - 60
                    let delay = max(60, min(300, untilRefresh))
                    report["nextAttemptAt"] = iso(Date().addingTimeInterval(delay))
                    try save()
                    try await Task.sleep(for: .seconds(delay))
                }
                report["status"] = "deadline_reached_without_verified_renewal"
                try save()
            } catch {
                report["status"] = Task.isCancelled ? "stopped" : "needs_attention"
                report["failure"] = (error as? NativeUsage.Failure)?.diagnostic ?? "watch_operation_failed"
                try? save()
            }
        }
    }

    func stop() {
        task?.cancel()
        if let child, child.isRunning { child.terminate() }
        if report["status"] == "watching" || report["status"] == "starting" {
            report["status"] = "stopped"
            try? save()
        }
    }

    private func save() throws {
        report["checkedAt"] = iso(Date())
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: root.appendingPathComponent("claude-watch.json"), options: .atomic)
    }

    private func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    private func touchOfficialAuth() async throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        var dimensions = winsize(ws_row: 50, ws_col: 160, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &dimensions) == 0 else {
            throw NativeUsage.Failure(diagnostic: "refresh_terminal_unavailable")
        }
        defer { close(master) }
        let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        defer { try? terminal.close() }
        var attributes = termios()
        guard tcgetattr(slave, &attributes) == 0 else { throw NativeUsage.Failure(diagnostic: "refresh_terminal_attributes_denied") }
        cfmakeraw(&attributes)
        guard tcsetattr(slave, TCSANOW, &attributes) == 0 else { throw NativeUsage.Failure(diagnostic: "refresh_terminal_ioctl_denied") }
        _ = fcntl(master, F_SETFL, O_NONBLOCK)
        let working = profile.deletingLastPathComponent()
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = working
        process.environment = ["HOME": working.path, "CLAUDE_CONFIG_DIR": profile.path,
            "PATH": "/usr/bin:/bin", "TMPDIR": NSTemporaryDirectory(), "LANG": "en_US.UTF-8",
            "TERM": "xterm-256color", "DISABLE_AUTOUPDATER": "1"]
        process.arguments = ["--tools", "", "--strict-mcp-config", "--setting-sources", "",
            "--permission-mode", "default", "--settings", "{\"disableAllHooks\":true,\"remoteControlAtStartup\":false}"]
        process.standardInput = terminal
        process.standardOutput = terminal
        process.standardError = terminal
        child = process
        try process.run()
        try terminal.close()
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            child = nil
        }
        let until = Date().addingTimeInterval(20)
        var output = Data()
        var sent = false
        while Date() < until, process.isRunning {
            try Task.checkCancellation()
            var bytes = [UInt8](repeating: 0, count: 8192)
            let count = read(master, &bytes, bytes.count)
            if count > 0 { output.append(contentsOf: bytes.prefix(count)) }
            guard output.count < 262_144 else { throw NativeUsage.Failure(diagnostic: "refresh_output_limit") }
            let text = String(decoding: output, as: UTF8.self)
            if ["Do you trust", "Choose the text style", "sign in", "Sign in", "remote control session"].contains(where: text.contains) {
                throw NativeUsage.Failure(diagnostic: "official_client_requires_user_attention")
            }
            if !sent, text.contains("❯") || text.contains("for shortcuts") {
                let command = Array("/status\r".utf8)
                let written = command.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }
                guard written == command.count else { throw NativeUsage.Failure(diagnostic: "refresh_status_write_failed") }
                sent = true
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        guard sent else { throw NativeUsage.Failure(diagnostic: "refresh_status_not_reached") }
    }
}
