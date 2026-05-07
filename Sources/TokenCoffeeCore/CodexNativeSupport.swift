import Foundation

struct CodexNativeConfiguration: Sendable {
    let issuerBaseURL: URL
    let backendBaseURL: URL
    let clientID: String
    let deviceLoginTimeout: TimeInterval
    let tokenRefreshInterval: TimeInterval
    let accessTokenRefreshSkew: TimeInterval
    let devicePollIntervalOverride: TimeInterval?
    let userAgent: String

    static func defaultConfiguration() -> CodexNativeConfiguration {
        CodexNativeConfiguration(
            issuerBaseURL: URL(string: "https://auth.openai.com")!,
            backendBaseURL: URL(string: "https://chatgpt.com/backend-api")!,
            clientID: "app_EMoamEEZ73f0CkXaXp7hrann",
            deviceLoginTimeout: 15 * 60,
            tokenRefreshInterval: 8 * 24 * 60 * 60,
            accessTokenRefreshSkew: 5 * 60,
            devicePollIntervalOverride: nil,
            userAgent: "TokenCoffee"
        )
    }

    var deviceUserCodeURL: URL {
        issuerBaseURL
            .appendingPathComponent("api")
            .appendingPathComponent("accounts")
            .appendingPathComponent("deviceauth")
            .appendingPathComponent("usercode")
    }

    var deviceTokenURL: URL {
        issuerBaseURL
            .appendingPathComponent("api")
            .appendingPathComponent("accounts")
            .appendingPathComponent("deviceauth")
            .appendingPathComponent("token")
    }

    var deviceVerificationURL: URL {
        issuerBaseURL
            .appendingPathComponent("codex")
            .appendingPathComponent("device")
    }

    var deviceCallbackURL: URL {
        issuerBaseURL
            .appendingPathComponent("deviceauth")
            .appendingPathComponent("callback")
    }

    var tokenURL: URL {
        issuerBaseURL
            .appendingPathComponent("oauth")
            .appendingPathComponent("token")
    }

    var usageURL: URL {
        if backendBaseURL.path.contains("/backend-api") {
            return backendBaseURL.appendingPathComponent("wham").appendingPathComponent("usage")
        }
        return backendBaseURL.appendingPathComponent("api").appendingPathComponent("codex").appendingPathComponent("usage")
    }
}

struct CodexAuthTokens: Codable, Equatable, Sendable {
    let idToken: String
    let accessToken: String
    let refreshToken: String
    let lastRefresh: Date
}

protocol CodexAuthTokenStore: Sendable {
    func load() async throws -> CodexAuthTokens?
    func save(_ tokens: CodexAuthTokens) async throws
    func delete() async throws
}

protocol CodexHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionCodexHTTPClient: CodexHTTPClient, @unchecked Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodexNativeHTTPError.invalidResponse("Response was not HTTP.")
        }
        return (data, httpResponse)
    }
}

enum CodexNativeHTTPError: Error, LocalizedError, Sendable {
    case invalidResponse(String)
    case unexpectedStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case let .invalidResponse(message):
            message
        case let .unexpectedStatus(status, body):
            if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                "HTTP \(status)"
            } else {
                "HTTP \(status): \(body)"
            }
        }
    }
}

extension CodexHTTPClient {
    func validatedData(for request: URLRequest) async throws -> Data {
        let (data, response) = try await self.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw CodexNativeHTTPError.unexpectedStatus(response.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    func statusData(for request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await self.data(for: request)
        return (data, response.statusCode)
    }
}

struct CodexJWTClaims: Sendable {
    let expiration: Date?
    let email: String?
    let planType: String?
    let accountID: String?
    let isFedRAMP: Bool

    static func parse(_ jwt: String) -> CodexJWTClaims {
        guard let payload = decodePayload(jwt),
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return CodexJWTClaims(expiration: nil, email: nil, planType: nil, accountID: nil, isFedRAMP: false)
        }

        let profile = object["https://api.openai.com/profile"] as? [String: Any]
        let auth = object["https://api.openai.com/auth"] as? [String: Any]
        let expiration = (object["exp"] as? TimeInterval).map { Date(timeIntervalSince1970: $0) }
        let email = object["email"] as? String ?? profile?["email"] as? String
        let accountID = auth?["chatgpt_account_id"] as? String
        let planType = auth?["chatgpt_plan_type"] as? String
        let isFedRAMP = auth?["chatgpt_account_is_fedramp"] as? Bool ?? false

        return CodexJWTClaims(
            expiration: expiration,
            email: email,
            planType: planType,
            accountID: accountID,
            isFedRAMP: isFedRAMP
        )
    }

    private static func decodePayload(_ jwt: String) -> Data? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else {
            return nil
        }

        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: base64)
    }
}

struct FlexibleDouble: Decodable, Sendable {
    let value: Double

    init(value: Double) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let double = try? container.decode(Double.self) {
            self.value = double
        } else if let int = try? container.decode(Int.self) {
            self.value = Double(int)
        } else if let string = try? container.decode(String.self),
                  let double = Double(string) {
            self.value = double
        } else {
            throw DecodingError.typeMismatch(
                Double.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected numeric value.")
            )
        }
    }
}

struct FlexibleInt: Decodable, Sendable {
    let value: Int

    init(value: Int) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self) {
            self.value = int
        } else if let double = try? container.decode(Double.self) {
            self.value = Int(double)
        } else if let string = try? container.decode(String.self),
                  let int = Int(string) {
            self.value = int
        } else {
            throw DecodingError.typeMismatch(
                Int.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected integer value.")
            )
        }
    }
}

struct FlexibleString: Decodable, Sendable {
    let value: String

    init(value: String) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self.value = string
        } else if let int = try? container.decode(Int.self) {
            self.value = String(int)
        } else if let double = try? container.decode(Double.self) {
            self.value = String(double)
        } else {
            throw DecodingError.typeMismatch(
                String.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected string value.")
            )
        }
    }
}

func codexFormURLEncoded(_ pairs: [(String, String)]) -> Data {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "+&=")
    let encoded = pairs
        .map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }
        .joined(separator: "&")
    return Data(encoded.utf8)
}
