import Foundation

public struct ClamshellFailSafeInstaller: Sendable {
    public let label = "com.pardeike.TokenHelper.clamshell-failsafe"

    public init() {}

    public func install(bundleExecutableURL: URL, fileManager: FileManager = .default) throws {
        let supportURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("TokenHelper", isDirectory: true)
        try fileManager.createDirectory(at: supportURL, withIntermediateDirectories: true)

        let scriptURL = supportURL.appendingPathComponent("tokenhelper-clamshell-failsafe.sh")
        let launchAgentDirectory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
        try fileManager.createDirectory(at: launchAgentDirectory, withIntermediateDirectories: true)
        let plistURL = launchAgentDirectory.appendingPathComponent("\(label).plist")

        let script = failSafeScript(executablePath: bundleExecutableURL.path)
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let plist = launchAgentPlist(scriptPath: scriptURL.path)
        try plist.write(to: plistURL, atomically: true, encoding: .utf8)

        reloadLaunchAgent(plistURL: plistURL)
    }

    private func failSafeScript(executablePath: String) -> String {
        let quotedExecutable = shellQuote(executablePath)
        return """
        #!/bin/sh
        DOMAIN="\(TokenHelperDefaults.domain)"
        KEY="\(TokenHelperDefaults.closedDisplayModeEnabledKey)"
        APP=\(quotedExecutable)

        enabled=$(/usr/bin/defaults read "$DOMAIN" "$KEY" 2>/dev/null || echo 0)
        [ "$enabled" = "1" ] || exit 0

        if ! /usr/bin/pgrep -x TokenHelper >/dev/null 2>&1; then
            "$APP" --reset-clamshell >/dev/null 2>&1
            /usr/bin/defaults write "$DOMAIN" "$KEY" -bool false >/dev/null 2>&1
            exit 0
        fi

        if ! /usr/bin/pmset -g assertions 2>/dev/null | /usr/bin/grep -q "TokenHelper"; then
            "$APP" --reset-clamshell >/dev/null 2>&1
            /usr/bin/defaults write "$DOMAIN" "$KEY" -bool false >/dev/null 2>&1
        fi
        """
    }

    private func launchAgentPlist(scriptPath: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(scriptPath)</string>
            </array>
            <key>StartInterval</key>
            <integer>10</integer>
            <key>StandardOutPath</key>
            <string>/dev/null</string>
            <key>StandardErrorPath</key>
            <string>/dev/null</string>
        </dict>
        </plist>
        """
    }

    private func reloadLaunchAgent(plistURL: URL) {
        let domain = "gui/\(getuid())"
        _ = runLaunchctl(["bootout", domain, plistURL.path])
        _ = runLaunchctl(["bootstrap", domain, plistURL.path])
        _ = runLaunchctl(["enable", "\(domain)/\(label)"])
    }

    private func runLaunchctl(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return false
        }

        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private func shellQuote(_ path: String) -> String {
        "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

