import Foundation
import XCTest
@testable import TokenCoffeeCore

final class UsageHistoryContractTests: XCTestCase {
    func testResetBoundaryAndDifferentCycle() {
        let reset = Date(timeIntervalSince1970: 1_800_000_000.672)
        XCTAssertTrue(UsageHistoryContract.matchesReset(reset.addingTimeInterval(1.328), live: reset))
        for offset in [-5.0, 5.0] {
            XCTAssertTrue(UsageHistoryContract.matchesReset(reset.addingTimeInterval(offset), live: reset))
        }
        for offset in [-5.01, 5.01, 604800] {
            XCTAssertFalse(UsageHistoryContract.matchesReset(reset.addingTimeInterval(offset), live: reset))
        }
        XCTAssertFalse(UsageHistoryContract.matchesReset(nil, live: reset))
    }

    func testIdentityNormalizesUUIDsButSeparatesMembersAndOrganizations() {
        let a = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        let b = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
        let identity = UsageHistoryContract.claudeIdentity(organizationID: a, accountID: b)
        XCTAssertEqual(identity, a.lowercased() + ":" + b.lowercased())
        XCTAssertEqual(identity, UsageHistoryContract.claudeIdentity(organizationID: a.lowercased(), accountID: b.lowercased()))
        XCTAssertNotEqual(identity, UsageHistoryContract.claudeIdentity(organizationID: a, accountID: a))
        XCTAssertNotEqual(identity, UsageHistoryContract.claudeIdentity(organizationID: b, accountID: b))
        XCTAssertNil(UsageHistoryContract.claudeIdentity(organizationID: "bad", accountID: b))
        XCTAssertNil(UsageHistoryContract.claudeIdentity(organizationID: a, accountID: "bad"))
    }
}
