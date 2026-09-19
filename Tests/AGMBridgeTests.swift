import XCTest
@testable import Codenotch

final class AGMBridgeTests: XCTestCase {
    func testParsesMultipleProfilesAndAliases() {
        let list = """
        EMAIL                                STATUS            GEM-PRO  GEM-FLASH     CLAUDE
        ------------------------------------------------------------------------------------
        one@example.com                      cli                    74%        80%        65%
        two@example.com                      ide                    92%        95%        88%
        three@example.com                                          43%        61%        57%
        """
        let aliases = """
        ALIAS            EMAIL
        pro1             one@example.com
        pro2             two@example.com
        pro3             three@example.com
        """

        let profiles = AGMBridge.parseProfiles(list: list, aliases: aliases)

        XCTAssertEqual(profiles.count, 3)
        XCTAssertEqual(profiles.map(\.alias), ["pro1", "pro2", "pro3"])
        XCTAssertTrue(profiles[0].isAgyActive)
        XCTAssertTrue(profiles[1].isIDEActive)
        XCTAssertFalse(profiles[2].isAgyActive)
        XCTAssertFalse(profiles[2].isIDEActive)
        XCTAssertNotEqual(profiles[0].id, profiles[1].id)
        XCTAssertTrue(profiles.allSatisfy { AGMProfile.isAGM(providerID: $0.id) })
    }

    func testQuotaInfoParsesRemainingPercentAndReset() {
        let info = """
        Account: one@example.com
        Token expiry: 2026-09-19T22:00:00+08:00

        PROVIDER     MODEL                                             SCORE  RESET
        ------------------------------------------------------------------------------------------
        GOOGLE       cloudaicompanion.googleapis.com/gemini-3.5-pro     74%  2026-09-20T01:00:00+08:00
        ANTHROPIC    cloudaicompanion.googleapis.com/claude-sonnet      61%  2026-09-25T12:00:00+08:00
        """

        let rows = AGMBridge.parseQuotaInfo(info)

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].provider, "GOOGLE")
        XCTAssertEqual(rows[0].remainingPercent, 74)
        XCTAssertEqual(rows[1].provider, "ANTHROPIC")
        XCTAssertEqual(rows[1].remainingPercent, 61)
    }

    func testQuotaInfoRetainsRowsWithBlankReset() {
        let info = """
        PROVIDER     MODEL                                             SCORE  RESET
        ------------------------------------------------------------------------------------------
        GOOGLE       cloudaicompanion.googleapis.com/gemini-3.5-pro     74%
        """

        let rows = AGMBridge.parseQuotaInfo(info)

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].remainingPercent, 74)
        XCTAssertNil(rows[0].resetTime)
    }

    func testListSummaryReconciliationKeepsMostConstrainedRemaining() {
        let detailed = [
            AGMBridge.QuotaRow(
                provider: "GOOGLE",
                model: "gemini-pro",
                remainingPercent: 74,
                resetTime: "2026-09-19T17:00:00Z"
            )
        ]
        let summary = AGMBridge.ListSummary(gemProRemaining: 43, gemFlashRemaining: nil, claudeRemaining: nil)

        let merged = AGMBridge.reconcileQuotaRows(detailed, with: summary)

        XCTAssertEqual(merged.count, 2)
        XCTAssertTrue(merged.contains { $0.model == "gemini-pro" && $0.remainingPercent == 74 })
        XCTAssertTrue(merged.contains { $0.model == "GEM-PRO (summary)" && $0.remainingPercent == 43 })
    }

    func testQuotaWindowsNeverTurnMissingDataIntoZeroUsage() {
        let now = AntigravityCredentials.parse("2026-09-19T12:00:00Z")!
        let rows = [
            AGMBridge.QuotaRow(
                provider: "GOOGLE",
                model: "gemini-pro",
                remainingPercent: 74,
                resetTime: "2026-09-19T17:00:00Z"
            )
        ]

        let windows = AGMAntigravityProvider.windows(from: rows, now: now)

        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].usedFraction ?? -1, 0.26, accuracy: 0.0001)
        XCTAssertEqual(windows[0].duration, 5 * 3600)
    }

    func testUnknownResetDoesNotInventFiveHourCadence() {
        let now = AntigravityCredentials.parse("2026-09-19T12:00:00Z")!
        let rows = [
            AGMBridge.QuotaRow(
                provider: "GOOGLE",
                model: "gemini-pro",
                remainingPercent: 74,
                resetTime: nil
            )
        ]

        let windows = AGMAntigravityProvider.windows(from: rows, now: now)

        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].usedFraction ?? -1, 0.26, accuracy: 0.0001)
        XCTAssertNil(windows[0].resetsAt)
        XCTAssertNil(windows[0].duration)
        XCTAssertTrue(windows[0].id.hasSuffix("-unknown"))
    }
}