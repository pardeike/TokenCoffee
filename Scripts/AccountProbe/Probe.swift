import AppKit
import Darwin
import SwiftUI

// Deliberately separate from TokenCoffee startup, credentials, history and CloudKit.
@MainActor
final class ProbeDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private let status = NSTextField(wrappingLabelWithString: "Checking sandbox…")
    private var process: Process?
    private var timer: Timer?
    private var output: FileHandle?
    private var report: [String: String] = [:]
    private var root: URL!
    private var deadline = Date.distantFuture
    private var terminalDescriptor: Int32 = -1
    private var terminalOutput = Data()
    private var phase = "version"
    private var openedBrowser = false
    private var resuming = false
    private var usageSent = false
    private var setupPrompt = ""
    private var confirmedUsage = false
    private var lastEscape = Date.distantPast
    private var escapeCount = 0
    private var nativeTask: Task<Void, Never>?
    private var accountsModel: AccountsModel?
    private var claudeWatch: ClaudeWatch?
    private let escapeButton = NSButton(title: "Send Escape", target: nil, action: nil)
    private let loginButton = NSButton(title: "Link Claude account", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let codeField = NSSecureTextField()
    private let submitButton = NSButton(title: "Submit code", target: nil, action: nil)

    func applicationDidFinishLaunching(_ notification: Notification) {
        let watching = CommandLine.arguments.last == "--watch"
        NSApp.setActivationPolicy(watching ? .prohibited : .regular)
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 320),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Token Coffee Account Probe"
        status.frame = NSRect(x: 24, y: 130, width: 492, height: 166)
        status.font = .systemFont(ofSize: 14)
        panel.contentView?.addSubview(status)
        loginButton.frame = NSRect(x: 24, y: 84, width: 180, height: 32)
        loginButton.target = self
        loginButton.action = #selector(login)
        loginButton.isEnabled = false
        cancelButton.frame = NSRect(x: 410, y: 84, width: 106, height: 32)
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.isEnabled = false
        escapeButton.frame = NSRect(x: 218, y: 84, width: 165, height: 32)
        escapeButton.target = self
        escapeButton.action = #selector(sendEscape)
        escapeButton.isEnabled = false
        let codeLabel = NSTextField(labelWithString: "Browser code, only if requested")
        codeLabel.frame = NSRect(x: 24, y: 58, width: 300, height: 20)
        codeField.frame = NSRect(x: 24, y: 24, width: 366, height: 26)
        codeField.isEnabled = false
        codeField.setAccessibilityLabel("Browser authorization code")
        submitButton.frame = NSRect(x: 400, y: 20, width: 116, height: 32)
        submitButton.target = self
        submitButton.action = #selector(submitCode)
        submitButton.isEnabled = false
        for view in [loginButton, escapeButton, cancelButton, codeLabel, codeField, submitButton] {
            panel.contentView?.addSubview(view)
        }
        panel.center()
        window = panel
        runPreflight()
        panel.delegate = self
        if !watching {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func runPreflight() {
        let arguments = CommandLine.arguments
        guard (4...6).contains(arguments.count), arguments.count < 5 || arguments[4] == "--resume",
              arguments.count < 6 || ["--theme-defaults", "--onboarding-defaults", "--trusted-probe-defaults", "--native-http", "--accounts", "--watch"].contains(arguments[5]) else {
            status.stringValue = "Missing executable and outside-container control file."
            return
        }
        do {
            root = try FileManager.default.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("TokenCoffeeAccountProbe", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            resuming = arguments.count >= 5
            var accountDirectory = UUID().uuidString
            if resuming {
                let savedURL = root.appendingPathComponent("linked-profile.json")
                let previousData = try Data(contentsOf: FileManager.default.fileExists(atPath: savedURL.path) ? savedURL : root.appendingPathComponent("report.json"))
                let previous = try JSONSerialization.jsonObject(with: previousData) as? [String: String]
                let previousRun = previous?["runDirectory"].map { URL(fileURLWithPath: $0) }
                let verifiedRun = previous?["login"] == "verified_logged_in" && previousRun?.deletingLastPathComponent().path == root.path
                guard let directory = previous?["directory"] ?? (verifiedRun ? previousRun?.lastPathComponent : nil), UUID(uuidString: directory) != nil else {
                    finish("resume_failed", "No verified private profile is available to resume.")
                    return
                }
                accountDirectory = directory
            }
            let runRoot = root.appendingPathComponent(accountDirectory, isDirectory: true)
            try FileManager.default.createDirectory(at: runRoot, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            report["runDirectory"] = runRoot.path
            report["runID"] = arguments[3]
            report["executable"] = arguments[1]
            report["login"] = "not_attempted"
            report["usage"] = "not_attempted"
            // This file contains only a public test marker. Never inspect user credentials.
            let descriptor = open(arguments[2], O_RDONLY)
            let deniedError = errno
            if descriptor >= 0 { close(descriptor) }
            guard descriptor < 0, deniedError == EPERM || deniedError == EACCES else {
                finish("invalid_control", "Sandbox control failed. External file was not denied.")
                return
            }
            report["outsideRead"] = "denied errno=\(deniedError)"
            let profile = runRoot.appendingPathComponent("claude-account-a", isDirectory: true)
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            if arguments.count == 6, !["--native-http", "--accounts", "--watch"].contains(arguments[5]) {
                let configurationURL = profile.appendingPathComponent(".claude.json")
                let existing = try Data(contentsOf: configurationURL)
                guard var configuration = try JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
                    finish("configuration_failed", "Private Claude configuration is not a JSON object.")
                    return
                }
                let backupURL = runRoot.appendingPathComponent("preconfiguration-backup.json")
                if !FileManager.default.fileExists(atPath: backupURL.path) {
                    try existing.write(to: backupURL, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
                }
                configuration["theme"] = configuration["theme"] ?? "dark"
                configuration["remoteControlAtStartup"] = false
                if arguments[5] != "--theme-defaults" {
                    configuration["hasCompletedOnboarding"] = true
                }
                if arguments[5] == "--trusted-probe-defaults" {
                    // Andreas explicitly approved trust for this exact private folder.
                    // Never apply to a parent directory or a user's coding project.
                    var projects = configuration["projects"] as? [String: Any] ?? [:]
                    var project = projects[runRoot.path] as? [String: Any] ?? [:]
                    project["hasTrustDialogAccepted"] = true
                    projects[runRoot.path] = project
                    configuration["projects"] = projects
                }
                let updated = try JSONSerialization.data(withJSONObject: configuration, options: [.prettyPrinted, .sortedKeys])
                try updated.write(to: configurationURL, options: .atomic)
                report["preconfiguration"] = arguments[5]
            }
            let marker = profile.appendingPathComponent("storage-control.txt")
            try Data("private storage control".utf8).write(to: marker)
            guard try Data(contentsOf: marker) == Data("private storage control".utf8) else {
                finish("invalid_control", "Private storage read-back failed.")
                return
            }
            report["privateStorage"] = "write_read_passed"
            if ["--native-http", "--accounts", "--watch"].contains(arguments.last ?? "") {
                report["transport"] = CommandLine.arguments.contains("--watch")
                    ? "native_https; official_cli_renewal" : "native_https; no_child_process"
                finish("native_ready", "Sandbox and private storage passed.\n\nReady to read this private profile's Keychain item and query usage over HTTPS. No Claude process will run.")
                loginButton.title = "Read via HTTP"
                loginButton.isEnabled = true
                if watchingMode {
                    let watch = ClaudeWatch(root: root, profile: profile, executable: URL(fileURLWithPath: arguments[1]))
                    claudeWatch = watch
                    watch.start()
                }
                if arguments.last == "--accounts", let window, let directory = UUID(uuidString: accountDirectory) {
                    let model = try AccountsModel(root: root, initialClaudeDirectory: directory)
                    accountsModel = model
                    window.styleMask.insert(.resizable)
                    window.contentMinSize = NSSize(width: 510, height: 310)
                    window.setContentSize(NSSize(width: 590, height: 400))
                    window.contentView = NSHostingView(rootView: AccountsView(model: model))
                    if let saved = UserDefaults.standard.string(forKey: "accounts.windowFrame"),
                       let restored = AccountWindowFrame.restore(NSRectFromString(saved),
                            visibleScreens: NSScreen.screens.map(\.visibleFrame)) {
                        window.setFrame(restored, display: false)
                    }
                }
                return
            }
            let executableAccess = access(arguments[1], X_OK)
            report["executableAccess"] = executableAccess == 0 ? "allowed" : "denied errno=\(errno)"
            let capture = runRoot.appendingPathComponent("version-output.txt")
            guard FileManager.default.createFile(atPath: capture.path, contents: nil,
                                                attributes: [.posixPermissions: 0o600]) else {
                finish("setup_failed", "Cannot create private version-output file.")
                return
            }
            let handle = try FileHandle(forWritingTo: capture)
            output = handle
            let child = Process()
            child.executableURL = URL(fileURLWithPath: arguments[1])
            child.arguments = ["--version"]
            // An allowlist avoids inherited API keys, hooks, routing and account overrides.
            let clientTemporary = runRoot.appendingPathComponent("tmp", isDirectory: true)
            try FileManager.default.createDirectory(at: clientTemporary, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            child.environment = ["HOME": runRoot.path, "CLAUDE_CONFIG_DIR": profile.path,
                                 "CLAUDE_CODE_TMPDIR": clientTemporary.path,
                                 "PATH": "/usr/bin:/bin", "TMPDIR": NSTemporaryDirectory(),
                                 "LANG": "en_US.UTF-8", "DISABLE_AUTOUPDATER": "1"]
            child.currentDirectoryURL = runRoot
            child.standardInput = FileHandle.nullDevice
            child.standardOutput = handle
            child.standardError = handle
            process = child
            do {
                try child.run()
            } catch {
                let failure = error as NSError
                report["launchError"] = "\(failure.domain) code=\(failure.code)"
                if let underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError {
                    report["underlyingError"] = "\(underlying.domain) code=\(underlying.code)"
                }
                finish("launch_blocked", "Sandbox enforced. Private storage works.\n\nClaude could not start.\n\(report["launchError"] ?? "")\n\(report["underlyingError"] ?? "")\n\nLogin and usage were not attempted.")
                return
            }
            status.stringValue = "Sandbox enforced. Private storage works.\n\nWaiting for Claude --version…"
            deadline = Date().addingTimeInterval(10)
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
        } catch {
            let failure = error as NSError
            finish("setup_failed", "Probe setup failed: \(failure.domain) code=\(failure.code)")
        }
    }

    private func poll() {
        guard let process else { return }
        if phase != "version" {
            pollAuthentication(process)
            return
        }
        if !process.isRunning {
            report["exitStatus"] = String(process.terminationStatus)
            report["exitReason"] = process.terminationReason == .exit ? "exit" : "signal"
            let passed = process.terminationReason == .exit && process.terminationStatus == 0
            if passed {
                report["version"] = "passed"
                var master: Int32 = -1
                var slave: Int32 = -1
                var dimensions = winsize(ws_row: 50, ws_col: 160, ws_xpixel: 0, ws_ypixel: 0)
                guard openpty(&master, &slave, nil, nil, &dimensions) == 0 else {
                    report["terminal"] = "denied errno=\(errno)"
                    finish("terminal_blocked", "Sandbox enforced. Private storage and Claude startup work.\n\nA terminal connection could not be opened: \(report["terminal"] ?? "").\n\nLogin and usage were not attempted.")
                    return
                }
                terminalDescriptor = master
                close(slave)
                close(master)
                terminalDescriptor = -1
                report["terminal"] = "passed"
            }
            finish(passed ? "version_passed" : "client_failed",
                   "Sandbox enforced. Private storage works.\n\nClaude --version \(passed ? "completed" : "failed") with status \(process.terminationStatus).\n\nLogin and usage were not attempted.")
            if passed { startAuthentication(resuming ? "resume_status" : "initial_status") }
        } else if Date() >= deadline {
            kill(process.processIdentifier, SIGKILL)
            finish("timeout", "Claude startup exceeded 10 seconds and was stopped.\n\nLogin and usage were not attempted.")
        }
    }

    @objc private func login() {
        if CommandLine.arguments.last == "--native-http" {
            readNativeUsage()
            return
        }
        if phase == "usage" && !setupPrompt.isEmpty {
            sendTerminal("\r")
            setupPrompt = ""
            terminalOutput.removeAll(keepingCapacity: false)
            loginButton.isEnabled = false
            deadline = Date().addingTimeInterval(30)
            status.stringValue = "Waiting for Claude to finish the selected setup step…"
            saveReport("usage_setup_accepted")
        } else {
            startAuthentication(report["restart"] == "verified" ? "usage" : "login")
        }
    }

    private func sendTerminal(_ value: String) {
        guard terminalDescriptor >= 0 else { return }
        var terminalState = termios()
        if tcgetattr(terminalDescriptor, &terminalState) == 0 {
            report["inputCanonical"] = String(terminalState.c_lflag & tcflag_t(ICANON) != 0)
            report["inputEcho"] = String(terminalState.c_lflag & tcflag_t(ECHO) != 0)
        }
        let bytes = Array(value.utf8)
        let written = bytes.withUnsafeBytes { Darwin.write(terminalDescriptor, $0.baseAddress, $0.count) }
        report["terminalInputBytes"] = String(written)
        if written < 0 { report["terminalInputError"] = String(errno) }
    }

    @objc private func sendEscape() {
        guard phase == "usage", process?.isRunning == true,
              Date().timeIntervalSince(lastEscape) >= 3 else { return }
        report["beforeEscapePrompt"] = setupPrompt
        sendTerminal("\u{1b}")
        lastEscape = Date()
        escapeCount += 1
        report["escapeCount"] = String(escapeCount)
        report["lastEscapeAt"] = ISO8601DateFormatter().string(from: lastEscape)
        setupPrompt = ""
        terminalOutput.removeAll(keepingCapacity: false)
        loginButton.isEnabled = false
        deadline = Date().addingTimeInterval(15)
        status.stringValue = "Sent one Escape. Waiting for a recognizable screen before /usage."
        saveReport("escape_sent")
    }

    @objc private func cancel() {
        if let nativeTask {
            nativeTask.cancel()
            self.nativeTask = nil
            report["usage"] = "cancelled"
            finish("native_cancelled", "Native usage request cancelled. The private login is unchanged.")
            loginButton.isEnabled = true
            return
        }
        if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        report["login"] = "cancelled"
        finish("cancelled", "Probe cancelled. No default coding account was changed.")
    }

    private func readNativeUsage() {
        guard nativeTask == nil, let directory = report["runDirectory"] else { return }
        loginButton.isEnabled = false
        cancelButton.isEnabled = true
        report.removeValue(forKey: "usageReadings")
        report.removeValue(forKey: "nativeFailure")
        report["usage"] = "native_request_started"
        status.stringValue = "Reading the private credential and requesting usage over HTTPS…"
        saveReport("native_fetching")
        nativeTask = Task {
            do {
                let profile = URL(fileURLWithPath: directory).appendingPathComponent("claude-account-a").path
                let readings = try await NativeUsage.fetch(profilePath: profile)
                try Task.checkCancellation()
                report["usage"] = "native_http_verified"
                report["usageReadings"] = readings.joined(separator: "\n")
                finish("native_usage_verified", "Native HTTPS usage passed. No Claude process or terminal exception.\n\n\(readings.joined(separator: "\n"))")
            } catch {
                if Task.isCancelled { return }
                let diagnostic = (error as? NativeUsage.Failure)?.diagnostic ?? "network_or_transport_error"
                report["nativeFailure"] = diagnostic
                report["usage"] = "not_verified"
                finish("native_usage_failed", "Native usage did not complete.\n\n\(diagnostic)\n\nNo credential was copied, changed, or printed. No automatic retry.")
            }
            nativeTask = nil
            loginButton.isEnabled = true
        }
    }

    @objc private func submitCode() {
        let code = codeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phase == "login", terminalDescriptor >= 0, !code.isEmpty,
              code.utf8.count < 4096, !code.contains("\n"), !code.contains("\r") else { return }
        let bytes = Array((code + "\r").utf8)
        let sent = bytes.withUnsafeBytes { Darwin.write(terminalDescriptor, $0.baseAddress, $0.count) }
        if sent == bytes.count { codeField.stringValue = "" }
    }

    private func startAuthentication(_ nextPhase: String) {
        guard let previous = process else { return }
        timer?.invalidate()
        if terminalDescriptor >= 0 { close(terminalDescriptor); terminalDescriptor = -1 }
        terminalOutput.removeAll(keepingCapacity: false)
        phase = nextPhase
        openedBrowser = false
        usageSent = false
        confirmedUsage = false
        setupPrompt = ""
        escapeCount = 0
        loginButton.isEnabled = false
        var master: Int32 = -1
        var slave: Int32 = -1
        if nextPhase == "login" || nextPhase == "usage" {
            var dimensions = winsize(ws_row: 50, ws_col: 160, ws_xpixel: 0, ws_ypixel: 0)
            guard openpty(&master, &slave, nil, nil, &dimensions) == 0 else {
                finish("terminal_blocked", "Cannot open the client's terminal connection.")
                return
            }
            var attributes = termios()
            let readAttributes = tcgetattr(slave, &attributes)
            report["terminalAttributesRead"] = readAttributes == 0 ? "passed" : "errno=\(errno)"
            cfmakeraw(&attributes)
            let setAttributes = tcsetattr(slave, TCSANOW, &attributes)
            report["terminalRawMode"] = setAttributes == 0 ? "passed" : "errno=\(errno)"
        } else {
            var descriptors: [Int32] = [-1, -1]
            guard pipe(&descriptors) == 0 else {
                finish("pipe_failed", "Cannot create the auth-status output pipe.")
                return
            }
            master = descriptors[0]
            slave = descriptors[1]
        }
        _ = fcntl(master, F_SETFL, O_NONBLOCK)
        terminalDescriptor = master
        let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        let child = Process()
        child.executableURL = previous.executableURL
        child.environment = previous.environment
        child.environment?["TERM"] = "xterm-256color"
        child.currentDirectoryURL = previous.currentDirectoryURL
        switch nextPhase {
        case "login": child.arguments = ["auth", "login", "--claudeai"]
        case "capabilities": child.arguments = ["--help"]
        case "usage":
            for key in ["usageReadings", "usageCompletion", "usageFailureTerms", "usageExitStatus", "usageExitReason"] {
                report.removeValue(forKey: key)
            }
            report["usage"] = "starting"
            child.arguments = ["--tools", "", "--strict-mcp-config", "--setting-sources", "",
                               "--permission-mode", "default", "--settings",
                               "{\"disableAllHooks\":true,\"remoteControlAtStartup\":false}"]
            if let directory = child.currentDirectoryURL {
                // Official-client diagnostics remain private. Never include them in reports.
                child.arguments? += ["--debug-file", directory.appendingPathComponent("usage-debug-\(report["runID"] ?? "probe").log").path]
            }
            report["usagePolicy"] = "no_tools_hooks_mcp_remote_control; default_permissions"
        default: child.arguments = ["auth", "status", "--json"]
        }
        child.standardInput = (nextPhase == "login" || nextPhase == "usage") ? terminal : FileHandle.nullDevice
        child.standardOutput = terminal
        child.standardError = terminal
        process = child
        do {
            try child.run()
            try terminal.close()
        } catch {
            try? terminal.close()
            finish("auth_launch_failed", "The private Claude authentication command could not start.")
            return
        }
        if nextPhase == "login" { report["login"] = "started" }
        saveReport(nextPhase)
        deadline = Date().addingTimeInterval(nextPhase == "login" ? 300 : nextPhase == "usage" ? 30 : 15)
        cancelButton.isEnabled = true
        escapeButton.isEnabled = nextPhase == "usage"
        status.stringValue = nextPhase == "login" ? "Starting official Claude login in a fresh private profile…\n\nComplete sign-in in your browser when it opens." : "Checking authentication in the private profile…"
        if nextPhase == "usage" { status.stringValue = "Opening Claude's usage screen with tools, hooks and external MCP configuration disabled…" }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func pollAuthentication(_ child: Process) {
        var bytes = [UInt8](repeating: 0, count: 4096)
        while terminalDescriptor >= 0 {
            let count = Darwin.read(terminalDescriptor, &bytes, bytes.count)
            if count <= 0 { break }
            terminalOutput.append(contentsOf: bytes.prefix(count))
            if terminalOutput.count > 65_536 {
                kill(child.processIdentifier, SIGKILL)
                finish("output_limit", "Client output exceeded the probe's limit. Stopped.")
                return
            }
        }
        let text = String(decoding: terminalOutput, as: UTF8.self)
        if phase == "usage" {
            pollUsage(child, text: text)
            return
        }
        if phase == "login", !openedBrowser,
           let regex = try? NSRegularExpression(pattern: #"https://[^\s\u001B]+"#),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range, in: text), let url = URL(string: String(text[range])),
           ["claude.ai", "platform.claude.com", "console.anthropic.com"].contains(url.host ?? ""),
           url.path.contains("oauth") {
            openedBrowser = true
            let opened = NSWorkspace.shared.open(url)
            report["browserHandoff"] = opened ? "opened" : "failed"
            report["login"] = "waiting_browser"
            status.stringValue = "Claude login is waiting for you in the browser.\n\nIf the browser gives you a code, paste it into the secure field below. Do not paste it into chat.\n\nThis profile is separate from your coding account."
            codeField.isEnabled = true
            submitButton.isEnabled = true
            saveReport("waiting_browser")
        }
        if !child.isRunning {
            report["authExitStatus"] = String(child.terminationStatus)
            if phase == "capabilities" {
                report["usageCapabilities"] = ["--tools", "--strict-mcp-config", "--setting-sources", "--settings"].filter { text.contains($0) }.joined(separator: ", ")
                finish("restart_verified", "The private Claude login survived an app restart.\n\nCredential storage: \(report["credentialStorage"] ?? "unchecked").\n\nUsage probing is the next check.")
                loginButton.title = "Read usage"
                loginButton.isEnabled = true
                return
            }
            if phase == "login" {
                guard child.terminationReason == .exit, child.terminationStatus == 0 else {
                    report["login"] = "failed"
                    // Only fixed diagnostic categories leave the in-memory transcript.
                    report["authFailure"] = text.contains("EPERM") ? "EPERM" : text.contains("EACCES") ? "EACCES" : "client_error"
                    report["failureTerms"] = ["listen", "callback", "port", "server", "permission", "bind", "unknown", "option", "keychain", "network", "EADDRINUSE", "EACCES", "EPERM", "spawn", "socket", "denied", "ENOENT", "OAuth", "browser"].filter { text.localizedCaseInsensitiveContains($0) }.joined(separator: ", ")
                    finish("login_failed", "Official Claude login failed with status \(child.terminationStatus).\n\nDiagnostic: \(report["authFailure"] ?? "unknown"). No transcript or credentials were written to the probe report.")
                    return
                }
                report["login"] = "command_completed"
                startAuthentication("verify_status")
                return
            }
            guard let first = text.firstIndex(of: "{"), let last = text.lastIndex(of: "}"), first <= last,
                  let object = try? JSONSerialization.jsonObject(with: Data(text[first...last].utf8)) as? [String: Any],
                  let loggedIn = object["loggedIn"] as? Bool else {
                if phase == "initial_status" {
                    // This command precedes login in a fresh empty profile. Retain only
                    // a redacted diagnostic, never an authentication transcript.
                    var diagnostic = String(text.prefix(2000))
                    for pattern in [#"\u001B\[[0-?]*[ -/]*[@-~]"#, #"https?://\S+"#,
                                    #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+"#,
                                    #"/[A-Za-z0-9_./@ +~-]+"#, #"[A-Za-z0-9_+./=-]{24,}"#] {
                        diagnostic = diagnostic.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
                    }
                    report["initialStatusDiagnostic"] = diagnostic
                }
                report["authFailure"] = text.contains("EPERM") ? "EPERM" : text.contains("EACCES") ? "EACCES" : "unrecognized_status"
                finish("auth_status_failed", "Private auth-status check failed.\n\nDiagnostic: \(report["authFailure"] ?? "unknown"). Login and usage are not established.")
                return
            }
            if phase == "initial_status", !loggedIn {
                report["initialAuthStatus"] = "logged_out"
                finish("ready_for_login", "Sandbox and terminal checks passed.\n\nClaude confirms this fresh private profile is signed out. Ready for a real login.\n\nYour normal Claude configuration is not used.")
                loginButton.isEnabled = true
            } else if ["verify_status", "resume_status"].contains(phase), loggedIn, child.terminationStatus == 0 {
                report["login"] = "verified_logged_in"
                if let runPath = report["runDirectory"] {
                    let runURL = URL(fileURLWithPath: runPath)
                    report["credentialStorage"] = FileManager.default.fileExists(atPath: runURL.appendingPathComponent("claude-account-a/.credentials.json").path) ? "plaintext_file_fallback" : "no_plaintext_credentials_file"
                    do {
                        let saved = try JSONSerialization.data(withJSONObject: ["directory": runURL.lastPathComponent])
                        try saved.write(to: root.appendingPathComponent("linked-profile.json"), options: .atomic)
                    } catch {
                        finish("profile_save_failed", "Login worked, but the private-profile reference could not be saved.")
                        return
                    }
                }
                finish("login_verified", "The official client confirms the private profile is logged in.\n\nUsage, restart, credential renewal and a second account still need verification.")
                if phase == "resume_status" {
                    report["restart"] = "verified"
                    startAuthentication("capabilities")
                }
            } else {
                finish("unexpected_auth_status", "Authentication state did not match the expected private-profile state. Stopped.")
            }
        } else if Date() >= deadline {
            kill(child.processIdentifier, SIGKILL)
            finish("auth_timeout", "Authentication timed out and the client was stopped.")
        }
    }

    private func pollUsage(_ child: Process, text: String) {
        let clean = text.replacingOccurrences(of: #"\u001B\[[0-?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
        let normalized = String(clean.lowercased().filter { !$0.isWhitespace })
        if normalized.contains("failedtoloadusagedata") {
            if report["usage"] != "fetch_error" {
                report["usage"] = "fetch_error"
                deadline = Date().addingTimeInterval(2)
                saveReport("usage_fetch_error")
                // Let the client's asynchronous diagnostic writer flush. No retry.
                return
            }
            if child.isRunning, Date() < deadline { return }
            report["usage"] = "not_verified"
            report["usageCompletion"] = "client_fetch_error"
            kill(child.processIdentifier, SIGKILL)
            finish("usage_not_verified", "Terminal input worked and /usage opened.\n\nThe official client could not load usage data. Private diagnostic log retained; no automatic retry.")
            return
        }
        if text.contains("\u{1b}[6n") {
            sendTerminal("\u{1b}[1;1R")
            terminalOutput = Data(text.replacingOccurrences(of: "\u{1b}[6n", with: "").utf8)
        }
        if setupPrompt.isEmpty {
            let prompts = ["Choose the text style", "Select the text style", "Syntax theme", "Do you trust the files in this folder?", "Yes, I trust this folder", "Quick safety check:", "Press Enter to continue", "Ready to code here?"]
            if let prompt = prompts.first(where: { normalized.contains(String($0.lowercased().filter { !$0.isWhitespace })) }) {
                setupPrompt = prompt
                report["usagePrompt"] = prompt
                status.stringValue = "Claude setup needs your input before /usage.\n\n\(String(clean.suffix(1200)))"
                loginButton.title = prompt.contains("style") || prompt.contains("theme") ? "Use default theme" : "Continue setup"
                loginButton.isEnabled = true
                deadline = Date().addingTimeInterval(300)
                saveReport("waiting_setup")
                return
            }
        }
        if !usageSent, setupPrompt.isEmpty,
           normalized.contains("forshortcuts") || normalized.contains("try\"") {
            sendTerminal("/usage\r")
            usageSent = true
            report["usage"] = "command_sent"
            saveReport("usage")
            terminalOutput.removeAll(keepingCapacity: false)
            return
        }
        if usageSent, !confirmedUsage, clean.localizedCaseInsensitiveContains("Show plan usage") {
            sendTerminal("\r")
            confirmedUsage = true
        }
        if usageSent, clean.localizedCaseInsensitiveContains("Current session"),
           clean.contains("%"), !clean.localizedCaseInsensitiveContains("Loading usage") {
            let labels = ["Current session", "Current week (all models)", "Current week (Sonnet only)"]
            var readings: [String] = []
            for label in labels {
                let pattern = NSRegularExpression.escapedPattern(for: label) + #"[\s\S]{0,300}?(\d{1,3})%\s*used"#
                if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                   let match = regex.matches(in: clean, range: NSRange(clean.startIndex..., in: clean)).last,
                   let range = Range(match.range(at: 1), in: clean), let percent = Int(clean[range]), (0...100).contains(percent) {
                    readings.append("\(label): \(percent)% used")
                }
            }
            if !readings.isEmpty {
                report["usage"] = "read_from_official_client"
                report["usageReadings"] = readings.joined(separator: "\n")
                kill(child.processIdentifier, SIGKILL)
                finish("usage_verified", "Private login, app restart and live /usage passed.\n\n\(readings.joined(separator: "\n"))\n\nSecond-account isolation and credential renewal remain untested.")
                return
            }
        }
        if !child.isRunning || Date() >= deadline {
            report["usageCompletion"] = child.isRunning ? "timeout" : "exit"
            if !child.isRunning {
                report["usageExitStatus"] = String(child.terminationStatus)
                report["usageExitReason"] = child.terminationReason == .exit ? "exit" : "signal"
            }
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            report["usage"] = "not_verified"
            report["usageFailureTerms"] = ["error", "failed", "permission", "trust", "theme", "style", "login", "usage", "Loading", "EPERM", "EACCES"].filter { clean.localizedCaseInsensitiveContains($0) }.joined(separator: ", ")
            finish("usage_not_verified", "The usage probe did not obtain a reading.\n\n\(String(clean.suffix(1200)))")
        }
    }

    private func finish(_ result: String, _ message: String) {
        timer?.invalidate()
        timer = nil
        try? output?.close()
        output = nil
        if terminalDescriptor >= 0 { close(terminalDescriptor); terminalDescriptor = -1 }
        terminalOutput.removeAll(keepingCapacity: false)
        cancelButton.isEnabled = false
        escapeButton.isEnabled = false
        codeField.isEnabled = false
        submitButton.isEnabled = false
        codeField.stringValue = ""
        status.stringValue = message
        if phase == "usage" {
            loginButton.title = "Read usage"
            loginButton.isEnabled = true
        }
        saveReport(result)
    }

    private func saveReport(_ result: String) {
        report["result"] = result
        report["checkedAt"] = ISO8601DateFormatter().string(from: Date())
        guard let root else { return }
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: root.appendingPathComponent("report.json"), options: .atomic)
        } catch {
            status.stringValue += "\nCould not save probe report."
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveAccountWindowFrame()
        nativeTask?.cancel()
        accountsModel?.stop()
        claudeWatch?.stop()
        timer?.invalidate()
        if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        try? output?.close()
        if terminalDescriptor >= 0 { close(terminalDescriptor) }
    }

    private var watchingMode: Bool { CommandLine.arguments.last == "--watch" }

    func windowDidMove(_ notification: Notification) { saveAccountWindowFrame() }
    func windowDidResize(_ notification: Notification) { saveAccountWindowFrame() }

    private func saveAccountWindowFrame() {
        guard accountsModel != nil, let window, window.isVisible else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: "accounts.windowFrame")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct AccountProbe {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = ProbeDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
