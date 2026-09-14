import CryptoKit
import Darwin
import Foundation
import LocalAuthentication
import Security

// Protocol evidence: CodexBar ClaudeOAuthUsageFetcher and claude-profile.
// No credential copies, refreshes, or default-profile fallback.
enum NativeUsage {
    struct Failure: Error { let diagnostic: String }
    struct CredentialEnvelope: Decodable {
        struct OAuth: Decodable {
            let accessToken: String
            let expiresAt: Double
            let scopes: [String]
        }
        let claudeAiOauth: OAuth
    }
    struct Window: Decodable {
        let utilization: Double
        let resets_at: String?
    }
    static let windowNames = ["five_hour", "seven_day", "seven_day_sonnet", "seven_day_opus", "seven_day_oauth_apps"]

    static func serviceName(profilePath: String) -> String {
        let digest = SHA256.hash(data: Data(profilePath.utf8)).prefix(4)
        return "Claude Code-credentials-" + digest.map { String(format: "%02x", $0) }.joined()
    }

    static func readCredential(profilePath: String, allowExpired: Bool = false) throws -> CredentialEnvelope.OAuth {
        let context = LAContext()
        context.interactionNotAllowed = true
        // Resolve the deprecated Security constant without assuming its string value.
        guard let framework = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW) else {
            throw Failure(diagnostic: "no_ui_policy_unavailable")
        }
        defer { dlclose(framework) }
        guard let symbol = dlsym(framework, "kSecUseAuthenticationUIFail") else {
            throw Failure(diagnostic: "no_ui_policy_unavailable")
        }
        let noUI = symbol.assumingMemoryBound(to: CFString.self).pointee
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName(profilePath: profilePath),
            kSecReturnAttributes as String: true,
            kSecReturnPersistentRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecUseAuthenticationContext as String: context,
            kSecUseAuthenticationUI as String: noUI,
        ]
        var value: CFTypeRef?
        var status = SecItemCopyMatching(query as CFDictionary, &value)
        guard status == errSecSuccess else {
            throw Failure(diagnostic: "keychain_metadata_status=\(status)")
        }
        // The official client did not use the macOS username for this item.
        // Select only this exact profile service and reject ambiguous duplicates.
        guard let matches = value as? [[String: Any]], matches.count == 1,
              let reference = matches[0][kSecValuePersistentRef as String] as? Data else {
            throw Failure(diagnostic: "ambiguous_or_invalid_profile_credential")
        }
        query = [kSecClass as String: kSecClassGenericPassword,
                 kSecValuePersistentRef as String: reference,
                 kSecReturnData as String: true,
                 kSecMatchLimit as String: kSecMatchLimitOne,
                 kSecUseAuthenticationContext as String: context,
                 kSecUseAuthenticationUI as String: noUI]
        value = nil
        status = SecItemCopyMatching(query as CFDictionary, &value)
        guard status == errSecSuccess, let data = value as? Data else {
            throw Failure(diagnostic: "keychain_read_status=\(status)")
        }
        return try decodeCredential(data, allowExpired: allowExpired)
    }

    static func decodeCredential(_ data: Data, now: Date = Date(), allowExpired: Bool = false) throws -> CredentialEnvelope.OAuth {
        guard let credential = try? JSONDecoder().decode(CredentialEnvelope.self, from: data).claudeAiOauth,
              !credential.accessToken.isEmpty,
              !credential.accessToken.contains(where: { $0.isWhitespace }),
              credential.scopes.contains("user:profile") else {
            throw Failure(diagnostic: "missing_profile_credential")
        }
        guard credential.expiresAt.isFinite, allowExpired || credential.expiresAt / 1000 > now.timeIntervalSince1970 else {
            throw Failure(diagnostic: "credential_expired; no_refresh_attempted")
        }
        return credential
    }

    static func decodeWindows(_ data: Data) throws -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(diagnostic: "invalid_usage_json")
        }
        var readings: [String] = []
        for name in windowNames {
            guard let value = object[name], !(value is NSNull) else { continue }
            guard JSONSerialization.isValidJSONObject(value),
                  let encoded = try? JSONSerialization.data(withJSONObject: value),
                  let window = try? JSONDecoder().decode(Window.self, from: encoded),
                  window.utilization.isFinite, (0...100).contains(window.utilization) else {
                throw Failure(diagnostic: "invalid_usage_window")
            }
            var reset = "unknown"
            if let raw = window.resets_at {
                let parser = ISO8601DateFormatter()
                parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                var date = parser.date(from: raw)
                if date == nil {
                    parser.formatOptions = [.withInternetDateTime]
                    date = parser.date(from: raw)
                }
                guard let date else { throw Failure(diagnostic: "invalid_reset_date") }
                reset = ISO8601DateFormatter().string(from: date)
            }
            readings.append("\(name): \(window.utilization)% used; resets \(reset)")
        }
        guard !readings.isEmpty else { throw Failure(diagnostic: "missing_usage_windows") }
        return readings
    }

    static func fetch(profilePath: String) async throws -> [String] {
        let credential = try readCredential(profilePath: profilePath)
        return try decodeWindows(await request("usage", credential: credential))
    }

    struct Profile: Equatable, Sendable {
        let identity: String
        let email: String
    }

    static func decodeProfile(_ data: Data) throws -> Profile {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = object["account"] as? [String: Any],
              let organization = object["organization"] as? [String: Any],
              let organizationID = organization["uuid"] as? String,
              UUID(uuidString: organizationID) != nil,
              let member = account["uuid"] as? String, UUID(uuidString: member) != nil,
              let email = (account["email"] ?? account["email_address"] ?? account["emailAddress"]) as? String,
              !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure(diagnostic: "profile_identity_unavailable")
        }
        // Organization plus member: do not merge different members of a shared organization.
        return Profile(identity: organizationID.lowercased() + ":" + member.lowercased(), email: email)
    }

    static func fetchAccount(profilePath: String, expectedIdentity: String?) async throws -> (Profile, [String]) {
        let credential = try readCredential(profilePath: profilePath)
        let profile = try decodeProfile(await request("profile", credential: credential))
        guard expectedIdentity == nil || expectedIdentity == profile.identity else {
            throw Failure(diagnostic: "account_identity_changed")
        }
        let windows = try decodeWindows(await request("usage", credential: credential))
        return (profile, windows)
    }

    static func fetchDiagrams(profilePath: String, expectedIdentity: String?) async throws -> (Profile, ClaudeUsageReading, String) {
        let credential = try readCredential(profilePath: profilePath)
        let profile = try decodeProfile(await request("profile", credential: credential))
        guard expectedIdentity == nil || profile.identity == expectedIdentity else {
            throw Failure(diagnostic: "account_identity_changed")
        }
        let data = try await request("usage", credential: credential)
        // Structural diagnostics only: never persist an arbitrary response payload.
        func shape(_ value: Any, depth: Int = 0) -> String {
            guard depth < 5 else { return "…" }
            if value is NSNull { return "null" }
            if let object = value as? [String: Any] {
                return "{" + object.keys.sorted().prefix(40).map {
                    $0 + ":" + shape(object[$0]!, depth: depth + 1)
                }.joined(separator: ",") + "}"
            }
            if let array = value as? [Any] { return "[" + array.prefix(8).map { shape($0, depth: depth + 1) }.joined(separator: ",") + "]" }
            return value is String ? "string" : "number"
        }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let limits = (object["limits"] as? [[String: Any]] ?? []).map { limit in
            limit.filter { ["kind", "group", "is_active", "scope", "percent", "resets_at"].contains($0.key) }
        }
        let detail = try JSONSerialization.data(withJSONObject: limits, options: [.sortedKeys])
        let structure = shape(object) + "; limits=" + String(decoding: detail, as: UTF8.self)
        return (profile, try ClaudeUsageReading.decode(data), structure)
    }

    private static func request(_ resource: String, credential: CredentialEnvelope.OAuth) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 25
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/\(resource)")!)
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("TokenCoffee-AccountProbe", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw Failure(diagnostic: "invalid_http_response") }
        guard response.statusCode == 200 else {
            // No retry or token refresh, including on 401 and 429. Never expose response bodies.
            throw Failure(diagnostic: "http_status=\(response.statusCode); no_retry")
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 131_072 else { throw Failure(diagnostic: "response_too_large") }
            data.append(byte)
        }
        return data
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
