import CryptoKit
import Foundation

/// One Antigravity account managed by `agm`.
///
/// Codenotch deliberately does not read agm's encrypted SQLite store or master
/// key. `agm` owns OAuth lifecycle and encryption; this profile only carries the
/// non-secret identity returned by its CLI.
struct AGMProfile: Equatable, Hashable, Sendable {
    static let providerPrefix = "gemini-agm-"

    let email: String
    let alias: String?
    let isAgyActive: Bool
    let isIDEActive: Bool

    var id: String {
        let digest = SHA256.hash(data: Data(email.lowercased().utf8))
        let suffix = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return Self.providerPrefix + suffix
    }

    var displayName: String {
        if let alias, !alias.isEmpty {
            return "Antigravity (\(alias))"
        }
        let local = email.split(separator: "@", maxSplits: 1).first.map(String.init) ?? email
        return "Antigravity (\(local))"
    }

    var sourceName: String {
        if let alias, !alias.isEmpty { return "agm \(alias)" }
        return "agm"
    }

    static func isAGM(providerID: String) -> Bool {
        providerID.hasPrefix(providerPrefix)
    }

    static func discover() -> [AGMProfile] {
        guard let executable = AGMBridge.findExecutable() else { return [] }
        let list = AGMBridge.runSync(executable: executable, arguments: ["list"], timeout: 3)
        guard list.exitCode == 0 else { return [] }

        let aliasesResult = AGMBridge.runSync(executable: executable, arguments: ["alias"], timeout: 3)
        let aliases = aliasesResult.exitCode == 0 ? aliasesResult.stdout : ""
        return AGMBridge.parseProfiles(list: list.stdout, aliases: aliases)
    }
}
