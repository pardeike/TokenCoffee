import Foundation

/// TokenCoffee's read-only history matching contract, also vendored by BrrainzTools.
/// No credentials, filesystem access or app dependencies belong here.
public enum UsageHistoryContract {
    public static let version = 1
    public static let resetTolerance: TimeInterval = 5

    public static func matchesReset(_ stored: Date?, live: Date) -> Bool {
        stored.map { abs($0.timeIntervalSince(live)) <= resetTolerance } ?? false
    }

    public static func claudeIdentity(organizationID: String, accountID: String) -> String? {
        guard let organization = UUID(uuidString: organizationID),
              let account = UUID(uuidString: accountID) else { return nil }
        return organization.uuidString.lowercased() + ":" + account.uuidString.lowercased()
    }
}
