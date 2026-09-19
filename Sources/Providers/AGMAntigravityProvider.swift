import Foundation
import os

/// Read-only bridge to the user's existing `agm` account registry.
///
/// `agm` remains the sole owner of refresh tokens, encryption, account
/// switching and the Cloud Code request. Codenotch only asks it to refresh a
/// named account and then parses the non-secret quota table it prints.
enum AGMBridge {
    struct CommandResult: Sendable {
        let stdout: String
        let stderr: String
        let exitCode: Int32

        var combinedError: String {
            let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? stdout.trimmingCharacters(in: .whitespacesAndNewlines) : text
        }
    }

    struct QuotaRow: Equatable, Sendable {
        let provider: String
        let model: String
        let remainingPercent: Int
        let resetTime: String
    }

    static func findExecutable(fileManager: FileManager = .default) -> URL? {
        let env = ProcessInfo.processInfo.environment
        var candidates: [String] = []

        if let explicit = env["CODENOTCH_AGM_PATH"], !explicit.isEmpty {
            candidates.append(explicit)
        }
        if let path = env["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/agm" })
        }

        let home = NSHomeDirectory()
        candidates.append(contentsOf: [
            "\(home)/.local/bin/agm",
            "\(home)/bin/agm",
            "\(home)/go/bin/agm",
            "/opt/homebrew/bin/agm",
            "/usr/local/bin/agm",
        ])

        for path in candidates where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        let shell = URL(fileURLWithPath: "/bin/zsh")
        let probe = runSync(executable: shell,
                            arguments: ["-lic", "command -v agm 2>/dev/null"],
                            timeout: 2)
        let path = probe.stdout
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .last?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty, fileManager.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    static func runSync(executable: URL, arguments: [String], timeout: TimeInterval) -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        do {
            try process.run()
        } catch {
            return CommandResult(stdout: "", stderr: error.localizedDescription, exitCode: -1)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.025)
        }
        if process.isRunning {
            process.terminate()
            let grace = Date().addingTimeInterval(0.25)
            while process.isRunning && Date() < grace {
                Thread.sleep(forTimeInterval: 0.025)
            }
        }

        let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let code: Int32 = process.isRunning ? -2 : process.terminationStatus
        return CommandResult(stdout: stdout, stderr: stderr, exitCode: code)
    }

    static func run(executable: URL, arguments: [String],
                    timeout: TimeInterval = 20) async -> CommandResult {
        await Task.detached(priority: .utility) {
            runSync(executable: executable, arguments: arguments, timeout: timeout)
        }.value
    }

    static func parseProfiles(list: String, aliases: String) -> [AGMProfile] {
        var aliasForEmail: [String: String] = [:]
        for raw in aliases.split(whereSeparator: \.isNewline) {
            let fields = raw.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2, fields[0] != "ALIAS", fields[1].contains("@") else { continue }
            aliasForEmail[fields[1].lowercased()] = fields[0]
        }

        var profiles: [AGMProfile] = []
        for raw in list.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let email = fields.first, email.contains("@"),
                  let emailRange = line.range(of: email) else { continue }

            let tail = String(line[emailRange.upperBound...])
            let status = tail.split(whereSeparator: \.isWhitespace)
                .map(String.init)
                .prefix { value in
                    value != "-" && !value.hasSuffix("%")
                }
                .joined(separator: ",")

            profiles.append(AGMProfile(
                email: email,
                alias: aliasForEmail[email.lowercased()],
                isAgyActive: status.contains("cli"),
                isIDEActive: status.contains("ide")
            ))
        }

        var seen = Set<String>()
        return profiles
            .filter { seen.insert($0.email.lowercased()).inserted }
            .sorted {
                let left = $0.alias ?? $0.email
                let right = $1.alias ?? $1.email
                return left.localizedStandardCompare(right) == .orderedAscending
            }
    }

    static func parseQuotaInfo(_ output: String) -> [QuotaRow] {
        let pattern = #"^\s*(GOOGLE|ANTHROPIC|OTHER)\s+(.+?)\s+(\d{1,3})%\s+(\S.*?)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        var rows: [QuotaRow] = []
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  match.numberOfRanges == 5,
                  let providerRange = Range(match.range(at: 1), in: line),
                  let modelRange = Range(match.range(at: 2), in: line),
                  let scoreRange = Range(match.range(at: 3), in: line),
                  let resetRange = Range(match.range(at: 4), in: line),
                  let score = Int(line[scoreRange])
            else { continue }

            rows.append(QuotaRow(
                provider: String(line[providerRange]),
                model: String(line[modelRange]).trimmingCharacters(in: .whitespaces),
                remainingPercent: min(max(score, 0), 100),
                resetTime: String(line[resetRange]).trimmingCharacters(in: .whitespaces)
            ))
        }
        return rows
    }

    static func info(executable: URL, profile: AGMProfile) async -> CommandResult {
        await run(executable: executable, arguments: ["info", profile.email], timeout: 5)
    }

    static func refresh(executable: URL, profile: AGMProfile) async -> CommandResult {
        await run(executable: executable, arguments: ["refresh", profile.email], timeout: 30)
    }
}

actor AGMAntigravityProvider: UsageProvider {
    nonisolated let profile: AGMProfile
    nonisolated let id: String
    nonisolated let displayName: String
    nonisolated let glyph = ProviderGlyph.antigravity

    private let executable: URL
    private let liveTTL: TimeInterval
    private var lastRefreshAttempt: Date?
    private var lastSuccessfulRefresh: Date?
    private var cachedWindows: [LimitWindow] = []

    init(profile: AGMProfile,
         executable: URL? = AGMBridge.findExecutable(),
         liveTTL: TimeInterval = 5 * 60) {
        self.profile = profile
        self.id = profile.id
        self.displayName = profile.displayName
        self.executable = executable ?? URL(fileURLWithPath: "/usr/bin/false")
        self.liveTTL = liveTTL
    }

    nonisolated var signInRoute: SignInRoute {
        .guidance(L10n.t("Manage this Antigravity account with agm."))
    }

    nonisolated func account() -> ProviderAccount? {
        var active: [String] = []
        if profile.isAgyActive { active.append("CLI") }
        if profile.isIDEActive { active.append("IDE") }
        return ProviderAccount(
            label: profile.email,
            plan: active.isEmpty ? "AGM" : active.joined(separator: " + "),
            source: profile.sourceName,
            manageURL: URL(string: "https://antigravity.google")
        )
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        let now = Date()
        let due = lastRefreshAttempt.map { now.timeIntervalSince($0) >= liveTTL } ?? true
        var refreshed = false
        var refreshFailure: String?

        if due {
            lastRefreshAttempt = now
            let result = await AGMBridge.refresh(executable: executable, profile: profile)
            if result.exitCode == 0 {
                lastSuccessfulRefresh = now
                refreshed = true
            } else {
                refreshFailure = result.combinedError
                Log.usage.error("\(self.id, privacy: .public) AGM refresh failed: \(result.combinedError, privacy: .public)")
            }
        }

        let info = await AGMBridge.info(executable: executable, profile: profile)
        if info.exitCode == 0 {
            let rows = AGMBridge.parseQuotaInfo(info.stdout)
            let windows = Self.windows(from: rows, now: now)
            if !windows.isEmpty {
                cachedWindows = windows
                let status: ProviderStatus = due && !refreshed
                    ? .stale(since: lastSuccessfulRefresh ?? now)
                    : .ok
                return snapshot(windows: windows, status: status)
            }
        }

        if !cachedWindows.isEmpty {
            return snapshot(windows: cachedWindows,
                            status: .stale(since: lastSuccessfulRefresh ?? now))
        }

        let message = refreshFailure ?? info.combinedError
        if message.lowercased().contains("not found") || message.lowercased().contains("no accounts") {
            throw UsageProviderError.needsAuth
        }
        throw UsageProviderError.badResponse(status: info.exitCode == 0 ? 0 : Int(info.exitCode))
    }

    private func snapshot(windows: [LimitWindow], status: ProviderStatus) -> ProviderSnapshot {
        ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: .official,
            status: status,
            windows: windows,
            headlineID: resolveHeadlineID(for: windows),
            weeklyID: resolveWeeklyID(for: windows)
        )
    }

    nonisolated static func windows(from rows: [AGMBridge.QuotaRow], now: Date) -> [LimitWindow] {
        rows.map { row in
            let reset = AntigravityCredentials.parse(row.resetTime)
            let interval = reset?.timeIntervalSince(now) ?? 0
            let weekly = interval > 24 * 3600
            let group = row.provider == "GOOGLE"
                ? L10n.t("Gemini Models")
                : L10n.t("Claude and GPT models")
            let prefix = row.provider == "GOOGLE" ? "gemini" : "3p"
            let model = slug(row.model)
            return LimitWindow(
                id: "\(prefix)-\(model)-\(weekly ? "weekly" : "hourly")",
                group: group,
                label: row.model,
                usedFraction: 1 - Double(row.remainingPercent) / 100,
                resetsAt: reset,
                duration: weekly ? 7 * 86400 : 5 * 3600
            )
        }
        .sorted {
            if $0.group != $1.group { return ($0.group ?? "") < ($1.group ?? "") }
            if $0.duration != $1.duration { return ($0.duration ?? 0) < ($1.duration ?? 0) }
            return $0.label < $1.label
        }
    }

    nonisolated func resolveHeadlineID(for windows: [LimitWindow]) -> String? {
        let preferredLimit = Preferences.storedAntigravityHeadlineLimit()
        let preferredModel = Preferences.storedAntigravityHeadlineModel()
        let modelCandidates = windows.filter { $0.id.hasPrefix(preferredModel.rawValue) }
        let candidates = modelCandidates.isEmpty ? windows : modelCandidates

        if preferredLimit != .automatic {
            let limited = candidates.filter { matches($0, cadence: preferredLimit) }
            if let mostUsed = limited.max(by: constrainedBefore) { return mostUsed.id }
        }

        let fractional = candidates.filter { $0.usedFraction != nil }
        let usable = fractional.filter { ($0.usedFraction ?? 0) < 1 }
        return (usable.isEmpty ? fractional : usable).max(by: constrainedBefore)?.id
            ?? candidates.first?.id
    }

    nonisolated func resolveWeeklyID(for windows: [LimitWindow]) -> String? {
        let preferredModel = Preferences.storedAntigravityHeadlineModel()
        let modelCandidates = windows.filter { $0.id.hasPrefix(preferredModel.rawValue) }
        let candidates = modelCandidates.isEmpty ? windows : modelCandidates
        let weekly = candidates.filter { $0.duration == 7 * 86400 || $0.id.hasSuffix("-weekly") }
        return weekly.max(by: constrainedBefore)?.id
    }

    private nonisolated func matches(_ window: LimitWindow,
                                     cadence: AntigravityHeadlineLimit) -> Bool {
        switch cadence {
        case .fiveHour: return window.duration == 5 * 3600 || window.id.hasSuffix("-hourly")
        case .weekly: return window.duration == 7 * 86400 || window.id.hasSuffix("-weekly")
        case .automatic: return true
        }
    }

    private nonisolated func constrainedBefore(_ lhs: LimitWindow, _ rhs: LimitWindow) -> Bool {
        let left = lhs.usedFraction ?? 0
        let right = rhs.usedFraction ?? 0
        if left != right { return left < right }
        return lhs.id > rhs.id
    }

    private nonisolated static func slug(_ value: String) -> String {
        let lowered = value.lowercased()
        let mapped = lowered.map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        return String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
    }
}
