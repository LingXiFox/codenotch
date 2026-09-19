import CryptoKit
import SQLite3
import XCTest
@testable import Codenotch

final class AGMCredentialStoreTests: XCTestCase {
    func testDecryptsAGMVersionedAESGCMToken() throws {
        let key = Data((0..<32).map { UInt8($0) })
        let iv = Data((32..<48).map { UInt8($0) })
        let json = #"{"access_token":"token-a","email":"one@example.com","project_id":"project-a","expiry_timestamp":1900000000}"#
        let nonce = try AES.GCM.Nonce(data: iv)
        let box = try AES.GCM.seal(Data(json.utf8), using: SymmetricKey(data: key), nonce: nonce)
        let encoded = "agm_enc_v1:\(iv.testHex):\(box.tag.testHex):\(box.ciphertext.testHex)"

        let clear = try AGMCredentialStore.decryptTokenJSON(encoded, keyData: key)
        XCTAssertEqual(clear, json)
    }

    func testPlaintextTokenAndExactEmailLookup() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let dbURL = dir.appendingPathComponent("cloud_accounts.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        guard let db else { return XCTFail("db") }
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE accounts (id TEXT, email TEXT, token_json TEXT);", nil, nil, nil), SQLITE_OK)

        let one = #"{"access_token":"one-token","email":"one@example.com","project_id":"p1"}"#
        let two = #"{"access_token":"two-token","email":"two@example.com","project_id":"p2"}"#
        try insert(db: db, id: "1", email: "one@example.com", token: one)
        try insert(db: db, id: "2", email: "two@example.com", token: two)

        let credential = try AGMCredentialStore.load(
            email: "TWO@example.com",
            dbURL: dbURL,
            keyURL: dir.appendingPathComponent("missing.mk")
        )
        XCTAssertEqual(credential.accountID, "2")
        XCTAssertEqual(credential.email, "two@example.com")
        XCTAssertEqual(credential.accessToken, "two-token")
        XCTAssertEqual(credential.projectID, "p2")
    }

    func testDailyQuotaParserProducesUsedFraction() throws {
        let data = Data(#"{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-hourly","displayName":"5-hour Limit","remainingFraction":0.72,"resetTime":"2026-09-20T01:00:00Z"}]}]}"#.utf8)
        let now = ISO8601DateFormatter().date(from: "2026-09-19T22:00:00Z")!
        let windows = AntigravityQuotaParser.parse(data, now: now)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].usedFraction ?? -1, 0.28, accuracy: 0.0001)
    }

    private func insert(db: OpaquePointer, id: String, email: String, token: String) throws {
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO accounts(id,email,token_json) VALUES(?1,?2,?3);", -1, &stmt, nil), SQLITE_OK)
        guard let stmt else { return XCTFail("stmt") }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, id, -1, transient)
        sqlite3_bind_text(stmt, 2, email, -1, transient)
        sqlite3_bind_text(stmt, 3, token, -1, transient)
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
    }
}

private extension Data {
    var testHex: String { map { String(format: "%02x", $0) }.joined() }
}
