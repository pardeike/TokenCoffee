import CryptoKit
import Foundation
import LocalAuthentication
import Security

public struct LinkedUsageValue: Codable, Equatable, Sendable {
    public let scopeID: String
    public let title: String
}

struct LinkedCredentialReference: Codable, Hashable, Sendable {
    let provider: ProbeAccount.Provider
    let id: UUID
    var service: String {
        if Bundle.main.bundleIdentifier == "com.pardeike.TokenCoffee.AccountProbe" {
            return provider == .codex ? ScopedCodexTokens.service : "com.pardeike.TokenCoffee.AccountProbe.claude-auth"
        }
        return "com.pardeike.TokenCoffee.accounts." + provider.rawValue.lowercased()
    }
}

protocol LinkedAccountSecrets: Sendable {
    func read(_ reference: LinkedCredentialReference) throws -> Data?
    func write(_ data: Data, for reference: LinkedCredentialReference) throws
    func delete(_ reference: LinkedCredentialReference) throws
}

struct LinkedAccountKeychain: LinkedAccountSecrets {
    private func query(_ reference: LinkedCredentialReference) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: reference.service,
                kSecAttrAccount as String: reference.id.uuidString,
                kSecUseDataProtectionKeychain as String: true,
                kSecUseAuthenticationContext as String: context]
    }
    func read(_ reference: LinkedCredentialReference) throws -> Data? {
        var query = query(reference)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw LinkedAccountError.keychainStatus("read", status) }
        return data
    }
    func write(_ data: Data, for reference: LinkedCredentialReference) throws {
        var query = query(reference)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw LinkedAccountError.keychainStatus("update", status) }
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(query as CFDictionary, nil)
        guard added == errSecSuccess else { throw LinkedAccountError.keychainStatus("create", added) }
    }
    func delete(_ reference: LinkedCredentialReference) throws {
        let status = SecItemDelete(query(reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw LinkedAccountError.keychainStatus("delete", status) }
    }
}

/// Runs in the actual signed application, against disposable app-owned entries.
public enum AccountKeychainVerification {
    public static func run() throws {
        let store = LinkedAccountKeychain()
        for provider in [ProbeAccount.Provider.claude, .codex] {
            let reference = LinkedCredentialReference(provider: provider, id: UUID())
            defer { try? store.delete(reference) }
            let first = Data(UUID().uuidString.utf8)
            let second = Data(UUID().uuidString.utf8)
            try store.write(first, for: reference)
            guard try store.read(reference) == first else { throw LinkedAccountError.invalidResponse }
            try store.write(second, for: reference)
            guard try store.read(reference) == second else { throw LinkedAccountError.invalidResponse }
            try store.delete(reference)
            guard try store.read(reference) == nil else { throw LinkedAccountError.invalidResponse }
        }
    }
}

public enum LinkedAccountError: Error, Sendable {
    case busy, signInRequired, wrongAccount, duplicateAccount, invalidCode, expiredLogin, cancelled
    case keychain, storage, invalidResponse, http(Int)
    case keychainStatus(String, Int32)

    public static func message(for error: Error) -> String {
        if error is CancellationError { return "Sign-in cancelled. Existing accounts are unchanged." }
        if let failure = error as? NativeUsage.Failure {
            if failure.diagnostic.contains("credential_expired") || failure.diagnostic.contains("http_status=401") {
                return "Sign-in required. Select Sign In Again to reconnect this account."
            }
            if failure.diagnostic.contains("identity") { return "Account identity could not be verified. No other account was substituted." }
            if failure.diagnostic.contains("429") { return "The provider is rate-limiting requests. Wait before refreshing again." }
        }
        if let failure = error as? CodexNativeAuthError {
            switch failure {
            case .needsSignIn, .unauthorized: return "Sign-in required. Select Sign In Again to reconnect this account."
            case .loginTimedOut: return "Sign-in timed out. Start again."
            default: return "Codex sign-in failed. Try again later."
            }
        }
        if let failure = error as? CodexRateLimitClient.ClientError, case .needsSignIn = failure {
            return "Sign-in required. Select Sign In Again to reconnect this account."
        }
        guard let error = error as? Self else { return "The operation failed. Check your connection and try again. Existing data was kept." }
        switch error {
        case .busy: return "Another account operation is finishing. Try again shortly."
        case .signInRequired: return "Sign-in required. Select Sign In Again to reconnect this account."
        case .wrongAccount: return "That is a different account. Sign in with the original account, or use Add Account. Nothing was replaced."
        case .duplicateAccount: return "This account is already linked and shares the same allowance. Select it in the account list."
        case .invalidCode: return "Paste the complete code#state from the browser for this sign-in."
        case .expiredLogin: return "This sign-in has expired. Cancel and start again."
        case .cancelled: return "Sign-in cancelled. Existing accounts are unchanged."
        case .keychain: return "TokenCoffee could not access its account credential in Keychain. No other login was used."
        case let .keychainStatus(operation, status): return "TokenCoffee Keychain \(operation) failed (\(status)). No other account's login was used."
        case .storage: return "Account changes could not be saved. Existing data was kept."
        case .invalidResponse: return "The provider returned an incomplete response. Try signing in again."
        case .http(401), .http(400): return "Authorization expired or was rejected. Sign in again."
        case .http(429): return "The provider is rate-limiting requests. Wait before trying again."
        case .http: return "The provider could not complete the request. Try again later."
        }
    }
}

public struct LinkedAccountLogin: Identifiable, Sendable {
    public let id: UUID
    public let provider: String
    public let url: URL
    public let deviceCode: String?
}

struct ClaudeAccountCredential: Codable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    var needsRefresh: Bool { expiresAt.timeIntervalSinceNow <= 60 }
}

/// Independent PKCE grant; never reads or rotates the official CLI's credential.
/// Protocol also documented by claudexbar/docs/AUTH.md; profile-only scope follows
/// the local BrrainzTools implementation. This is not a public provider API contract.
struct ClaudeAccountOAuth: Sendable {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let redirect = "https://platform.claude.com/oauth/code/callback"
    let http: any CodexHTTPClient

    struct Pending: Sendable {
        let verifier: String
        let state: String
        let createdAt: Date
        init() {
            verifier = Self.random(); state = Self.random(); createdAt = Date()
        }
        private static func random() -> String {
            Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64URL
        }
        var url: URL {
            var url = URLComponents(string: "https://claude.com/cai/oauth/authorize")!
            url.queryItems = ["code": "true", "client_id": ClaudeAccountOAuth.clientID,
                "response_type": "code", "redirect_uri": ClaudeAccountOAuth.redirect,
                "scope": "user:profile", "code_challenge": Data(SHA256.hash(data: Data(verifier.utf8))).base64URL,
                "code_challenge_method": "S256", "state": state]
                .sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            return url.url!
        }
        func code(from input: String, now: Date = Date()) throws -> String {
            guard (0..<1800).contains(now.timeIntervalSince(createdAt)) else { throw LinkedAccountError.expiredLogin }
            let parts = input.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "#", omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, parts[1] == state else { throw LinkedAccountError.invalidCode }
            return String(parts[0])
        }
    }

    func complete(_ pending: Pending, input: String) async throws -> ClaudeAccountCredential {
        try await token(["grant_type": "authorization_code", "code": pending.code(from: input),
            "state": pending.state, "redirect_uri": Self.redirect, "client_id": Self.clientID,
            "code_verifier": pending.verifier])
    }
    func refresh(_ credential: ClaudeAccountCredential) async throws -> ClaudeAccountCredential {
        try await token(["grant_type": "refresh_token", "refresh_token": credential.refreshToken,
            "client_id": Self.clientID, "scope": "user:profile"], previous: credential.refreshToken)
    }
    private func token(_ body: [String: String], previous: String? = nil) async throws -> ClaudeAccountCredential {
        var request = URLRequest(url: URL(string: "https://platform.claude.com/v1/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let data = try await response(request)
        struct Response: Decodable {
            let access_token: String; let refresh_token: String?; let expires_in: Double; let scope: String?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              !response.access_token.isEmpty, let refresh = response.refresh_token ?? previous, !refresh.isEmpty,
              response.expires_in.isFinite, response.expires_in > 0,
              response.scope == nil || response.scope!.split(separator: " ").contains("user:profile") else {
            throw LinkedAccountError.invalidResponse
        }
        return ClaudeAccountCredential(accessToken: response.access_token, refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(response.expires_in))
    }
    func profile(_ credential: ClaudeAccountCredential) async throws -> NativeUsage.Profile {
        try NativeUsage.decodeProfile(await resource("profile", credential: credential))
    }
    func usage(_ credential: ClaudeAccountCredential) async throws -> ClaudeUsageReading {
        try ClaudeUsageReading.decode(await resource("usage", credential: credential))
    }
    private func resource(_ name: String, credential: ClaudeAccountCredential) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/\(name)")!)
        request.setValue("Bearer " + credential.accessToken, forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await response(request)
    }
    private func response(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await http.data(for: request)
        guard response.statusCode == 200 else { throw LinkedAccountError.http(response.statusCode) }
        guard data.count <= 131_072 else { throw LinkedAccountError.invalidResponse }
        return data
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// A single service actor serializes credential rotation. No cookies, caching,
/// automatic HTTP retries, or cross-origin redirects on auth requests.
final class LinkedAccountHTTP: NSObject, CodexHTTPClient, URLSessionTaskDelegate, @unchecked Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw LinkedAccountError.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 131_072 else { throw LinkedAccountError.invalidResponse }
            data.append(byte)
        }
        return (data, response)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct ManagedCodexTokens: CodexAuthTokenStore {
    let reference: LinkedCredentialReference
    let identity: String
    let secrets: any LinkedAccountSecrets
    func load() throws -> CodexAuthTokens? {
        guard let data = try secrets.read(reference) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let tokens = try decoder.decode(CodexAuthTokens.self, from: data)
        guard try ScopedCodexTokens.identity(tokens) == identity else { throw LinkedAccountError.wrongAccount }
        return tokens
    }
    func save(_ tokens: CodexAuthTokens) throws {
        guard try ScopedCodexTokens.identity(tokens) == identity else { throw LinkedAccountError.wrongAccount }
        try secrets.write(Self.encode(tokens), for: reference)
    }
    func delete() throws { try secrets.delete(reference) }
    static func encode(_ tokens: CodexAuthTokens) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(tokens)
    }
}
