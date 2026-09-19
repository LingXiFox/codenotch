import XCTest
@testable import Codenotch

final class CodexAppServerQuotaTests: XCTestCase {
    func testPrimaryFiveHourParses() throws {
        let snapshot = CodexAppServerQuota.parseResponse(Data(#"{
          "id":2,"result":{"rateLimits":{"limitId":"codex","planType":"plus",
          "primary":{"usedPercent":42,"windowDurationMins":300,"resetsAt":1800001000},"secondary":null}}
        }"#.utf8))
        XCTAssertEqual(snapshot?.plan, "plus")
        XCTAssertEqual(snapshot?.windows.count, 1)
        XCTAssertEqual(snapshot?.windows[0].id, "primary")
        XCTAssertEqual(snapshot?.windows[0].usedFraction ?? -1, 0.42, accuracy: 0.0001)
        XCTAssertEqual(snapshot?.windows[0].duration, 18_000)
    }

    func testWeeklyOnlyPrimaryRemainsUsable() throws {
        let snapshot = CodexAppServerQuota.parseResponse(Data(#"{
          "id":2,"result":{"rateLimits":{"limitId":"codex",
          "primary":{"usedPercent":31,"windowDurationMins":10080,"resetsAt":1800600000},"secondary":null}}
        }"#.utf8))
        XCTAssertEqual(snapshot?.windows.count, 1)
        XCTAssertEqual(snapshot?.windows[0].usedFraction ?? -1, 0.31, accuracy: 0.0001)
        XCTAssertEqual(snapshot?.windows[0].duration, 604_800)
        let ids = CodexLocalProvider.ringIDs(from: snapshot?.windows ?? [])
        XCTAssertEqual(ids.headline, "primary")
        XCTAssertEqual(ids.weekly, "primary")
    }

    func testRateLimitsByLimitIDCodexFallback() throws {
        let snapshot = CodexAppServerQuota.parseResponse(Data(#"{
          "id":2,"result":{"rateLimits":{"limitId":"other","primary":null,"secondary":null},
          "rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":"17","windowDurationMins":"300","resetsAt":"1800001000"}},
          "base_model_inference":{"limitId":"base_model_inference","primary":{"usedPercent":99,"windowDurationMins":10080}}}}}
        }"#.utf8))
        XCTAssertEqual(snapshot?.windows.count, 1)
        XCTAssertEqual(snapshot?.windows[0].usedFraction ?? -1, 0.17, accuracy: 0.0001)
    }

    func testUnrelatedExtraBucketDoesNotBecomeHeadline() throws {
        let snapshot = CodexAppServerQuota.parseResponse(Data(#"{
          "id":2,"result":{"rateLimitsByLimitId":{
            "base_model_inference":{"limitId":"base_model_inference","primary":{"usedPercent":99,"windowDurationMins":10080}},
            "codex":{"limitId":"codex","primary":{"usedPercent":23,"windowDurationMins":300}}
          }}
        }"#.utf8))
        XCTAssertEqual(snapshot?.windows.count, 1)
        XCTAssertEqual(snapshot?.windows[0].usedFraction ?? -1, 0.23, accuracy: 0.0001)
    }
}
