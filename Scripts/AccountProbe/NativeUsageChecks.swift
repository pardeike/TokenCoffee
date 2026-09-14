import CoreGraphics
import Foundation

@main
struct NativeUsageChecks {
    static func main() throws {
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw NativeUsage.Failure(diagnostic: message) }
        }
        func rejects(_ json: String) throws {
            do {
                _ = try NativeUsage.decodeWindows(Data(json.utf8))
            } catch is NativeUsage.Failure { return }
            throw NativeUsage.Failure(diagnostic: "invalid quota accepted")
        }
        let first = NativeUsage.serviceName(profilePath: "/profiles/one")
        try check(NativeUsage.serviceName(profilePath: "") == "Claude Code-credentials-e3b0c442", "SHA-256 service derivation")
        try check(first != NativeUsage.serviceName(profilePath: "/profiles/two"), "profile collision")
        try check(first == NativeUsage.serviceName(profilePath: "/profiles/one"), "unstable profile service")
        let readings = try NativeUsage.decodeWindows(Data(#"{"five_hour":{"utilization":0,"resets_at":"2026-09-14T00:00:00.000Z"},"seven_day":{"utilization":100,"resets_at":null},"seven_day_opus":null,"future_field":{}}"#.utf8))
        try check(readings.count == 2 && readings[0].contains("0.0%") && readings[1].contains("100.0%"), "quota boundary decoding")
        try rejects(#"{"five_hour":{"utilization":101}}"#)
        try rejects(#"{"five_hour":{"utilization":-1}}"#)
        try rejects(#"{"five_hour":{"utilization":true}}"#)
        try rejects(#"{"five_hour":{"utilization":12,"resets_at":"not a date"}}"#)
        try rejects(#"{"five_hour":null}"#)
        try rejects("not json")
        let credential = Data(#"{"claudeAiOauth":{"accessToken":"fixture-only","expiresAt":200000,"scopes":["user:profile"]}}"#.utf8)
        _ = try NativeUsage.decodeCredential(credential, now: Date(timeIntervalSince1970: 100))
        do {
            _ = try NativeUsage.decodeCredential(credential, now: Date(timeIntervalSince1970: 200))
            throw NSError(domain: "expired credential accepted", code: 1)
        } catch is NativeUsage.Failure { }
        do {
            _ = try NativeUsage.decodeCredential(Data(#"{"mcpOAuth":{}}"#.utf8))
            throw NSError(domain: "MCP credential accepted", code: 1)
        } catch is NativeUsage.Failure { }
        do {
            _ = try NativeUsage.decodeCredential(Data(#"{"claudeAiOauth":{"accessToken":"fixture-only","expiresAt":200000,"scopes":["user:inference"]}}"#.utf8), now: Date(timeIntervalSince1970: 100))
            throw NSError(domain: "missing profile scope accepted", code: 1)
        } catch is NativeUsage.Failure { }
        let profileData = Data(#"{"account":{"uuid":"22222222-2222-2222-2222-222222222222","email":"fixture@example.invalid"},"organization":{"uuid":"11111111-1111-1111-1111-111111111111"}}"#.utf8)
        let profile = try NativeUsage.decodeProfile(profileData)
        try check(profile.identity == "11111111-1111-1111-1111-111111111111:22222222-2222-2222-2222-222222222222", "Claude identity decoding")
        do {
            _ = try NativeUsage.decodeProfile(Data(#"{"account":{"email":"fixture@example.invalid"}}"#.utf8))
            throw NSError(domain: "missing Claude identity accepted", code: 1)
        } catch is NativeUsage.Failure { }
        do {
            _ = try NativeUsage.decodeProfile(Data(#"{"account":{"email":"fixture@example.invalid"},"organization":{"uuid":"11111111-1111-1111-1111-111111111111"}}"#.utf8))
            throw NSError(domain: "email substituted for member identity", code: 1)
        } catch is NativeUsage.Failure { }

        let directory = UUID()
        let claude = ProbeAccount(id: UUID(), provider: .claude, name: "Private Claude", claudeDirectory: directory)
        let codex = ProbeAccount(id: UUID(), provider: .codex, name: "Private Codex", identity: "account-one")
        let registry = AccountRegistry(accounts: [claude, codex])
        try registry.validate()
        let roundtrip = try JSONDecoder().decode(AccountRegistry.self, from: JSONEncoder().encode(registry))
        try check(roundtrip == registry, "registry roundtrip")
        let duplicate = ProbeAccount(id: UUID(), provider: .codex, name: "Same allowance", identity: "account-one")
        do {
            _ = try registry.replacing(duplicate)
            throw NSError(domain: "duplicate allowance accepted", code: 1)
        } catch is NativeUsage.Failure { }
        var repeatedProfile = claude
        repeatedProfile = ProbeAccount(id: UUID(), provider: .claude, name: "Repeated profile", claudeDirectory: directory)
        do {
            _ = try registry.replacing(repeatedProfile)
            throw NSError(domain: "duplicate private profile accepted", code: 1)
        } catch is NativeUsage.Failure { }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("TokenCoffeeRegistryChecks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let registryURL = temporary.appendingPathComponent("accounts.json")
        try registry.saving(to: registryURL)
        let loaded = try AccountRegistry.load(from: registryURL, initialClaudeDirectory: UUID())
        try check(loaded == registry, "restart bootstrapped over saved registry")
        var pending = registry
        pending.pendingCodexID = UUID()
        try pending.saving(to: registryURL)
        try check(try AccountRegistry.load(from: registryURL, initialClaudeDirectory: UUID()) == pending, "unfinished login was lost on restart")
        try Data("invalid registry".utf8).write(to: registryURL)
        do {
            _ = try AccountRegistry.load(from: registryURL, initialClaudeDirectory: UUID())
            throw NSError(domain: "corrupt registry silently overwritten", code: 1)
        } catch is DecodingError { }
        var renamed = codex
        renamed.name = "Work"
        try check(try registry.replacing(renamed).accounts.count == 2, "rename appended an account")
        var invalid = registry
        invalid.pendingCodexID = codex.id
        do {
            try invalid.validate()
            throw NSError(domain: "pending login overlaps linked account", code: 1)
        } catch is NativeUsage.Failure { }
        try check(ScopedCodexTokens.service != "com.pardeike.TokenCoffee.codex-auth", "probe uses production credential service")
        func jwt(_ identity: String) -> String {
            let payload = Data("{\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"\(identity)\"}}".utf8)
                .base64EncodedString().replacingOccurrences(of: "=", with: "")
            return "fixture.\(payload).fixture"
        }
        let tokens = CodexAuthTokens(idToken: jwt("one"), accessToken: jwt("one"), refreshToken: "fixture", lastRefresh: .distantPast)
        try check(try ScopedCodexTokens.identity(tokens) == "one", "Codex identity decoding")
        do {
            _ = try ScopedCodexTokens.identity(CodexAuthTokens(idToken: jwt("one"), accessToken: jwt("two"), refreshToken: "fixture", lastRefresh: .distantPast))
            throw NSError(domain: "conflicting token identities accepted", code: 1)
        } catch is NativeUsage.Failure { }
        print("Native usage checks passed")
        let mainScreen = CGRect(x: 0, y: 0, width: 2560, height: 1410)
        let leftScreen = CGRect(x: -2560, y: 0, width: 2560, height: 1410)
        let savedFrame = CGRect(x: -1566, y: 606, width: 640, height: 452)
        try check(AccountWindowFrame.restore(savedFrame, visibleScreens: [mainScreen, leftScreen]) == savedFrame,
                  "left-screen frame moved to main screen")
        try check(AccountWindowFrame.restore(savedFrame, visibleScreens: [leftScreen, mainScreen]) == savedFrame,
                  "frame depends on screen ordering")
        let disconnected = AccountWindowFrame.restore(savedFrame, visibleScreens: [mainScreen])!
        try check(mainScreen.contains(disconnected) && disconnected.size == savedFrame.size, "disconnected display recovery")
        let huge = AccountWindowFrame.restore(CGRect(x: -200, y: -200, width: 5000, height: 4000), visibleScreens: [mainScreen])!
        try check(huge == mainScreen, "oversized window was not constrained")
        try check(AccountWindowFrame.restore(.zero, visibleScreens: [mainScreen]) == nil, "zero frame accepted")
        try check(AccountWindowFrame.restore(savedFrame, visibleScreens: []) == nil, "missing screens accepted")
        print("Account window checks passed")
        let scopedJSON = Data(#"{"five_hour":{"utilization":100},"seven_day":{"utilization":26},"limits":[{"kind":"weekly_scoped","group":"weekly","percent":41,"resets_at":"2026-09-19T22:00:00Z","is_active":false,"scope":{"model":{"id":"claude-fable","display_name":"Fable"}}}]}"#.utf8)
        let scoped = try ClaudeUsageReading.decode(scopedJSON)
        try check(scoped.diagrams.map(\.title) == ["General", "Fable"], "dynamic Claude diagram titles")
        try check(scoped.diagrams.map(\.usedPercent) == [26, 41], "Claude limits combined or assigned incorrectly")
        try check(scoped.session?.usedPercent == 100, "shared session limit lost")
        try check(scoped.diagrams.map(\.id) == ["general", "model:claude-fable"], "scope identity depends on display order")
        let unnamedID = Data(String(decoding: scopedJSON, as: UTF8.self).replacingOccurrences(of: "\"id\":\"claude-fable\"", with: "\"id\":null").utf8)
        try check(try ClaudeUsageReading.decode(unnamedID).diagrams.last?.id == "model-name:fable", "live null model id loses Fable")
        let renamedScope = Data(String(decoding: scopedJSON, as: UTF8.self).replacingOccurrences(of: "\"Fable\"", with: "\"Next Model\"").utf8)
        try check(try ClaudeUsageReading.decode(renamedScope).diagrams.last?.id == scoped.diagrams.last?.id,
                  "model rename changed diagram identity")
        let absent = try ClaudeUsageReading.decode(Data(#"{"seven_day":{"utilization":0},"limits":null}"#.utf8))
        try check(absent.diagrams.count == 1, "missing model limit invented")
        do {
            _ = try ClaudeUsageReading.decode(Data(#"{"seven_day":{"utilization":101}}"#.utf8))
            throw NSError(domain: "invalid Claude percent accepted", code: 1)
        } catch is ClaudeUsageReading.Failure { }
        print("Claude diagram checks passed")
    }
}
