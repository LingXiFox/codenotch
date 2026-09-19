import CryptoKit
import Foundation
import SQLite3

/// Read-only compatibility layer for agm's encrypted account registry.
///
/// Codenotch never writes agm's database or master key and never changes the
/// active account. The only purpose of this reader is to borrow the exact
/// access token for one already-known account so Cloud Code can be queried
/// without switching the user's CLI/IDE session.
enum AGMCredentialStore {
    struct Credential: Equatable, Sendable {
        let accountID: String
        let email: String
        let accessToken: String
        let projectID: String?
        let expiryTimestamp: Int64?
    }

    enum StoreError: Error {
        case databaseMissing
        case keyMissing
        case accountMissing
        case unreadableToken
        case decryptFailed
    }

    private struct TokenPayload: Decodable {
        let accessToken: String
        let email: String?
        let projectID: String?
        let expiryTimestamp: Int64?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case email
            case projectID = "project_id"
            case expiryTimestamp = "expiry_timestamp"
        }
    }

    static func load(email: String,
                     environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Credential {
        let locations = paths(environment: environment)
        return try load(email: email, dbURL: locations.db, keyURL: locations.key)
    }

    /// Internal overload kept injectable for tests. Reads the DB in read-only
    /// mode and matches the email exactly (case-insensitive).
    static func load(email: String, dbURL: URL, keyURL: URL) throws -> Credential {
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            throw StoreError.databaseMissing
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db else {
            if let db { sqlite3_close(db) }
            throw StoreError.databaseMissing
        }
        defer { sqlite3_close(db) }

        let sql = "SELECT id, email, token_json FROM accounts WHERE lower(email) = lower(?1) LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw StoreError.accountMissing
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, email, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let idRaw = sqlite3_column_text(stmt, 0),
              let emailRaw = sqlite3_column_text(stmt, 1),
              let tokenRaw = sqlite3_column_text(stmt, 2) else {
            throw StoreError.accountMissing
        }

        let accountID = String(cString: idRaw)
        let storedEmail = String(cString: emailRaw)
        guard storedEmail.caseInsensitiveCompare(email) == .orderedSame else {
            throw StoreError.accountMissing
        }

        let encoded = String(cString: tokenRaw)
        let tokenJSON: String
        let trimmed = encoded.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            tokenJSON = trimmed
        } else {
            let key = try loadPlainMasterKey(at: keyURL)
            tokenJSON = try decryptTokenJSON(trimmed, keyData: key)
        }

        guard let data = tokenJSON.data(using: .utf8),
              let payload = try? JSONDecoder().decode(TokenPayload.self, from: data),
              !payload.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StoreError.unreadableToken
        }

        if let payloadEmail = payload.email,
           !payloadEmail.isEmpty,
           payloadEmail.caseInsensitiveCompare(storedEmail) != .orderedSame {
            throw StoreError.unreadableToken
        }

        return Credential(
            accountID: accountID,
            email: storedEmail,
            accessToken: payload.accessToken,
            projectID: payload.projectID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            expiryTimestamp: payload.expiryTimestamp
        )
    }

    static func decryptTokenJSON(_ value: String, keyData: Data) throws -> String {
        guard keyData.count == 32 else { throw StoreError.keyMissing }
        var payload = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if payload.hasPrefix("agm_enc_v1:") {
            payload.removeFirst("agm_enc_v1:".count)
        }
        let parts = payload.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let iv = Data(hex: String(parts[0])),
              let tag = Data(hex: String(parts[1])),
              let ciphertext = Data(hex: String(parts[2])) else {
            throw StoreError.decryptFailed
        }

        do {
            let nonce = try AES.GCM.Nonce(data: iv)
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            let clear = try AES.GCM.open(box, using: SymmetricKey(data: keyData))
            guard let text = String(data: clear, encoding: .utf8) else {
                throw StoreError.decryptFailed
            }
            return text
        } catch {
            throw StoreError.decryptFailed
        }
    }

    private static func loadPlainMasterKey(at url: URL) throws -> Data {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            throw StoreError.keyMissing
        }
        let hex = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hex.count == 64, let key = Data(hex: hex), key.count == 32 else {
            throw StoreError.keyMissing
        }
        return key
    }

    private static func paths(environment: [String: String]) -> (db: URL, key: URL) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dataDir: URL
        if let explicit = environment["AGM_DATA_DIR"], !explicit.isEmpty {
            dataDir = URL(fileURLWithPath: explicit)
        } else if let explicit = environment["ANTIGRAVITY_AGENT_DIR"], !explicit.isEmpty {
            dataDir = URL(fileURLWithPath: explicit)
        } else {
            dataDir = home.appendingPathComponent(".antigravity-agent", isDirectory: true)
        }

        let db: URL
        if let explicit = environment["AGM_DB_PATH"], !explicit.isEmpty {
            db = URL(fileURLWithPath: explicit)
        } else {
            db = dataDir.appendingPathComponent("cloud_accounts.db")
        }
        return (db, dataDir.appendingPathComponent(".mk"))
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

private extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}
