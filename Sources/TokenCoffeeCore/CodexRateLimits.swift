import Foundation

public struct CodexRateLimitsResponse: Codable, Equatable, Sendable {
    public let rateLimits: RateLimitSnapshot
    public let rateLimitsByLimitId: [String: RateLimitSnapshot]?

    public init(rateLimits: RateLimitSnapshot, rateLimitsByLimitId: [String: RateLimitSnapshot]? = nil) {
        self.rateLimits = rateLimits
        self.rateLimitsByLimitId = rateLimitsByLimitId
    }

    public var codexSnapshot: RateLimitSnapshot {
        rateLimitsByLimitId?["codex"] ?? rateLimits
    }
}

public struct RateLimitSnapshot: Codable, Equatable, Sendable {
    public let limitId: String?
    public let limitName: String?
    public let primary: RateLimitWindow?
    public let secondary: RateLimitWindow?
    public let credits: CreditsSnapshot?
    public let planType: String?
    public let rateLimitReachedType: String?

    public init(
        limitId: String?,
        limitName: String?,
        primary: RateLimitWindow?,
        secondary: RateLimitWindow?,
        credits: CreditsSnapshot?,
        planType: String?,
        rateLimitReachedType: String?
    ) {
        self.limitId = limitId
        self.limitName = limitName
        self.primary = primary
        self.secondary = secondary
        self.credits = credits
        self.planType = planType
        self.rateLimitReachedType = rateLimitReachedType
    }
}

public struct RateLimitWindow: Codable, Equatable, Sendable {
    public let usedPercent: Double
    public let windowDurationMins: Int?
    public let resetsAt: Int?

    public init(usedPercent: Double, windowDurationMins: Int?, resetsAt: Int?) {
        self.usedPercent = usedPercent
        self.windowDurationMins = windowDurationMins
        self.resetsAt = resetsAt
    }

    public var resetDate: Date? {
        resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }
}

public struct CreditsSnapshot: Codable, Equatable, Sendable {
    public let hasCredits: Bool
    public let unlimited: Bool
    public let balance: String?

    public init(hasCredits: Bool, unlimited: Bool, balance: String?) {
        self.hasCredits = hasCredits
        self.unlimited = unlimited
        self.balance = balance
    }
}

