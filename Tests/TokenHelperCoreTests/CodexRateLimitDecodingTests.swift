import XCTest
@testable import TokenHelperCore

final class CodexRateLimitDecodingTests: XCTestCase {
    func testDecodesCodexRateLimitPayload() throws {
        let data = """
        {
          "rateLimits": {
            "limitId": "codex",
            "limitName": null,
            "primary": {"usedPercent": 5, "windowDurationMins": 300, "resetsAt": 1777987901},
            "secondary": {"usedPercent": 3, "windowDurationMins": 10080, "resetsAt": 1778540328},
            "credits": {"hasCredits": false, "unlimited": false, "balance": "0"},
            "planType": "pro",
            "rateLimitReachedType": null
          },
          "rateLimitsByLimitId": {
            "codex": {
              "limitId": "codex",
              "limitName": null,
              "primary": {"usedPercent": 5, "windowDurationMins": 300, "resetsAt": 1777987901},
              "secondary": {"usedPercent": 3, "windowDurationMins": 10080, "resetsAt": 1778540328},
              "credits": {"hasCredits": false, "unlimited": false, "balance": "0"},
              "planType": "pro",
              "rateLimitReachedType": null
            },
            "codex_bengalfox": {
              "limitId": "codex_bengalfox",
              "limitName": "GPT-5.3-Codex-Spark",
              "primary": {"usedPercent": 0, "windowDurationMins": 300, "resetsAt": 1777990029},
              "secondary": {"usedPercent": 0, "windowDurationMins": 10080, "resetsAt": 1778576829},
              "credits": null,
              "planType": "pro",
              "rateLimitReachedType": null
            }
          }
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(CodexRateLimitsResponse.self, from: data)

        XCTAssertEqual(response.codexSnapshot.limitId, "codex")
        XCTAssertEqual(response.codexSnapshot.primary?.windowDurationMins, 300)
        XCTAssertEqual(response.codexSnapshot.secondary?.windowDurationMins, 10_080)
        XCTAssertEqual(response.codexSnapshot.secondary?.usedPercent, 3)
        XCTAssertEqual(response.rateLimitsByLimitId?["codex_bengalfox"]?.limitName, "GPT-5.3-Codex-Spark")
    }

    func testParsesAppServerResponseAmongNotifications() throws {
        let output = """
        {"id":1,"result":{"userAgent":"TokenHelper/0.128.0"}}
        {"method":"remoteControl/status/changed","params":{"status":"disabled","environmentId":null}}
        {"id":2,"result":{"rateLimits":{"limitId":"codex","limitName":null,"primary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":1777987901},"secondary":{"usedPercent":4,"windowDurationMins":10080,"resetsAt":1778540328},"credits":{"hasCredits":false,"unlimited":false,"balance":"0"},"planType":"pro","rateLimitReachedType":null},"rateLimitsByLimitId":{"codex":{"limitId":"codex","limitName":null,"primary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":1777987901},"secondary":{"usedPercent":4,"windowDurationMins":10080,"resetsAt":1778540328},"credits":{"hasCredits":false,"unlimited":false,"balance":"0"},"planType":"pro","rateLimitReachedType":null}}}}
        """

        let response = try CodexRateLimitClient().parseRateLimitResponse(from: output)

        XCTAssertEqual(response?.codexSnapshot.limitId, "codex")
        XCTAssertEqual(response?.codexSnapshot.primary?.usedPercent, 12)
        XCTAssertEqual(response?.codexSnapshot.secondary?.usedPercent, 4)
    }

    func testParsesAppServerRateLimitError() throws {
        let output = #"{"id":2,"error":{"message":"not logged in"}}"#

        XCTAssertThrowsError(try CodexRateLimitClient().parseRateLimitResponse(from: output)) { error in
            XCTAssertEqual(error as? CodexRateLimitClient.ClientError, .serverError("not logged in"))
        }
    }
}
