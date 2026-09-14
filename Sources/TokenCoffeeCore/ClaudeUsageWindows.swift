import Foundation

/// One login can supply several diagrams. A model limit is not another account.
public struct ClaudeUsageDiagram: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let usedPercent: Double
    public let resetsAt: Date?
    public let windowMinutes: Int
}

public struct ClaudeUsageReading: Equatable, Sendable {
    public let session: RateLimitWindow?
    public let diagrams: [ClaudeUsageDiagram]

    public static func decode(_ data: Data) throws -> Self {
        struct Response: Decodable {
            struct Window: Decodable { let utilization: Double?; let resets_at: String? }
            struct Limit: Decodable {
                struct Scope: Decodable {
                    struct Model: Decodable { let id: String?; let display_name: String? }
                    let model: Model?
                }
                let kind: String?
                let group: String?
                let percent: Double?
                let resets_at: String?
                let is_active: Bool?
                let scope: Scope?
            }
            let five_hour: Window?
            let seven_day: Window?
            let limits: [Limit]?
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        func percent(_ value: Double) throws -> Double {
            guard value.isFinite, (0...100).contains(value) else { throw Failure.invalidPercent }
            return value
        }
        func date(_ value: String?) throws -> Date? {
            guard let value else { return nil }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: value) else { throw Failure.invalidReset }
            return date
        }
        func text(_ value: String?) -> String? {
            guard let value else { return nil }
            let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty || clean.count > 160 || clean.contains(where: { $0.isNewline }) ? nil : clean
        }
        var diagrams: [ClaudeUsageDiagram] = []
        if let value = response.seven_day?.utilization {
            diagrams.append(ClaudeUsageDiagram(id: "general", title: "General", usedPercent: try percent(value),
                resetsAt: try date(response.seven_day?.resets_at), windowMinutes: 10_080))
        }
        var seen = Set<String>()
        for limit in response.limits ?? [] {
            // is_active is not availability: the live response marks both General
            // and Fable false while the exhausted session is true.
            guard limit.kind == "weekly_scoped", limit.group == "weekly",
                  let model = limit.scope?.model, let title = text(model.display_name),
                  let value = limit.percent else { continue }
            let id = text(model.id).map { "model:" + $0 } ?? "model-name:" + title.lowercased()
            guard title.lowercased() != "all models", id.lowercased() != "model:all-models" else { continue }
            guard seen.insert(id).inserted else { throw Failure.duplicateScope }
            diagrams.append(ClaudeUsageDiagram(id: id, title: title, usedPercent: try percent(value),
                resetsAt: try date(limit.resets_at), windowMinutes: 10_080))
        }
        let session: RateLimitWindow?
        if let value = response.five_hour?.utilization {
            session = RateLimitWindow(usedPercent: try percent(value), windowDurationMins: 300,
                resetsAt: try date(response.five_hour?.resets_at).map { Int($0.timeIntervalSince1970.rounded(.up)) })
        } else { session = nil }
        guard !diagrams.isEmpty || session != nil else { throw Failure.noDiagrams }
        return Self(session: session, diagrams: diagrams)
    }

    public enum Failure: Error { case invalidPercent, invalidReset, duplicateScope, noDiagrams }
}
