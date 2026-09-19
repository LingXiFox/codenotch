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
        let resetTime: String?
    }

    struct ListSummary: Equatable, Sendable {
        let gemProRemaining: Int?
        let gemFlashRemaining: Int?
        let claudeRemaining: Int?

        func remaining(for family: QuotaFamily) -> Int? {
            switch family {
            case .gemPro: return gemProRemaining
            case .gemFlash: return gemFlashRemaining
            case .claude: return claudeRemaining
            }
        }
    }

    enum QuotaFamily: CaseIterable, Sendable {
        case gemPro
        case gemFlash
        case claude
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
            guard let row = parseListRow(line) else { continue }
            let status = row.status

            profiles.append(AGMProfile(
                email: row.email,
                alias: aliasForEmail[row.email.lowercased()],
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

    static func parseListSummaries(_ output: String) -> [String: ListSummary] {
        var summaries: [String: ListSummary] = [:]
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            guard let row = parseListRow(line) else { continue }
            summaries[row.email.lowercased()] = row.summary
        }
        return summaries
    }

    static func parseQuotaInfo(_ output: String) -> [QuotaRow] {
        let pattern = #"^\s*(GOOGLE|ANTHROPIC|OTHER)\s+(.+?)\s+(\d{1,3})%(?:\s+(\S.*?))?\s*$"#
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
                  let score = Int(line[scoreRange])
            else { continue }

            let reset: String?
            if match.range(at: 4).location != NSNotFound,
               let resetRange = Range(match.range(at: 4), in: line) {
                let value = String(line[resetRange]).trimmingCharacters(in: .whitespaces)
                reset = value.isEmpty ? nil : value
            } else {
                reset = nil
            }

            rows.append(QuotaRow(
                provider: String(line[providerRange]),
                model: String(line[modelRange]).trimmingCharacters(in: .whitespaces),
                remainingPercent: min(max(score, 0), 100),
                resetTime: reset
            ))
        }
        return rows
    }

    static func reconcileQuotaRows(_ rows: [QuotaRow], with summary: ListSummary?) -> [QuotaRow] {
        guard let summary else { return rows }
        var merged = rows
        for family in QuotaFamily.allCases {
            guard let remaining = summary.remaining(for: family) else { continue }
            let minimumDetailed = rows
                .filter { quotaFamily(for: $0) == family }
                .map(\.remainingPercent)
                .min()
            if let minimumDetailed, minimumDetailed <= remaining { continue }
            merged.append(QuotaRow(
                provider: syntheticProvider(for: family),
                model: syntheticLabel(for: family),
                remainingPercent: remaining,
                resetTime: nil
            ))
        }
        return merged
    }

    static func info(executable: URL, profile: AGMProfile) async -> CommandResult {
        await run(executable: executable, arguments: ["info", profile.email], timeout: 5)
    }

    static func list(executable: URL) async -> CommandResult {
        await run(executable: executable, arguments: ["list"], timeout: 5)
    }

    static func refreshAll(executable: URL, timeout: TimeInterval = 45) async -> CommandResult {
        await run(executable: executable, arguments: ["refresh-all"], timeout: timeout)
    }

    static func refreshHadPartialFailure(_ result: CommandResult) -> Bool {
        let text = "\(result.stdout)\n\(result.stderr)"
        let pattern = #"Completed:\s*\d+\s+successful,\s*(\d+)\s+failed"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges >= 2,
              let failedRange = Range(match.range(at: 1), in: text),
              let failed = Int(text[failedRange]) else {
            return false
        }
        return failed > 0
    }

    private struct ParsedListRow {
        let email: String
        let status: String
        let summary: ListSummary
    }

    private static func parseListRow(_ line: String) -> ParsedListRow? {
        let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let email = fields.first, email.contains("@") else { return nil }

        let summaryColumnCount = min(3, max(fields.count - 1, 0))
        let tail = Array(fields.suffix(summaryColumnCount))
        let summary = ListSummary(
            gemProRemaining: parsePercent(tail[safe: 0]),
            gemFlashRemaining: parsePercent(tail[safe: 1]),
            claudeRemaining: parsePercent(tail[safe: 2])
        )
        let status = fields.dropFirst().dropLast(summaryColumnCount)
            .filter { $0 != "-" }
            .joined(separator: ",")
            .lowercased()
        return ParsedListRow(email: email, status: status, summary: summary)
    }

    private static func parsePercent(_ value: String?) -> Int? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "-" else { return nil }
        let raw = trimmed.hasSuffix("%") ? String(trimmed.dropLast()) : trimmed
        guard let percent = Int(raw) else { return nil }
        return min(max(percent, 0), 100)
    }

    private static func quotaFamily(for row: QuotaRow) -> QuotaFamily? {
        switch row.provider {
        case "GOOGLE":
            if row.model.localizedCaseInsensitiveContains("flash") { return .gemFlash }
            return .gemPro
        case "ANTHROPIC":
            return .claude
        default:
            return row.model.localizedCaseInsensitiveContains("claude") ? .claude : nil
        }
    }

    private static func syntheticProvider(for family: QuotaFamily) -> String {
        switch family {
        case .gemPro, .gemFlash: return "GOOGLE"
        case .claude: return "ANTHROPIC"
        }
    }

    private static func syntheticLabel(for family: QuotaFamily) -> String {
        switch family {
        case .gemPro: return "GEM-PRO (summary)"
        case .gemFlash: return "GEM-FLASH (summary)"
        case .claude: return "CLAUDE (summary)"
        }
    }
}


actor AGMRefreshCoordinator {
    struct Outcome: Sendable {
        let attempted: Bool
        let successfulAt: Date?
        let fullySuccessful: Bool
        let message: String?
    }

    private struct State {
        var lastAttempt: Date?
        var lastSuccessful: Date?
        var lastOutcome: Outcome?
        var inFlight: Task<Outcome, Never>?
    }

    private var states: [String: State] = [:]

    func refreshIfNeeded(executable: URL, ttl: TimeInterval, now: Date) async -> Outcome {
        let key = executable.path
        var state = states[key] ?? State()
        if let inFlight = state.inFlight {
            return await inFlight.value
        }
        let due = state.lastAttempt.map { now.timeIntervalSince($0) >= ttl } ?? true
        if !due {
            return state.lastOutcome ?? Outcome(
                attempted: false,
                successfulAt: state.lastSuccessful,
                fullySuccessful: true,
                message: nil
            )
        }

        state.lastAttempt = now
        let task = Task { [executable] in
            let result = await AGMBridge.refreshAll(executable: executable, timeout: 45)
            let partialFailure = AGMBridge.refreshHadPartialFailure(result)
            let successful = result.exitCode == 0 && !partialFailure
            let message: String?
            if successful {
                message = nil
            } else if partialFailure {
                message = "AGM refresh-all partially failed"
            } else {
                message = result.combinedError
            }
            return Outcome(
                attempted: true,
                successfulAt: successful ? now : nil,
                fullySuccessful: successful,
                message: message
            )
        }
        state.inFlight = task
        states[key] = state

        var outcome = await task.value
        state = states[key] ?? State()
        state.inFlight = nil
        if outcome.fullySuccessful {
            state.lastSuccessful = outcome.successfulAt ?? state.lastSuccessful ?? now
        } else {
            outcome = Outcome(
                attempted: true,
                successfulAt: state.lastSuccessful,
                fullySuccessful: false,
                message: outcome.message
            )
        }
        state.lastOutcome = outcome
        states[key] = state
        return outcome
    }
}

actor AGMAntigravityProvider: UsageProvider {
    nonisolated let profile: AGMProfile
    nonisolated let id: String
    nonisolated let displayName: String
    nonisolated let glyph = ProviderGlyph.antigravity

    private let executable: URL
    private let liveTTL: TimeInterval
    private var lastSuccessfulRefresh: Date?
    private var cachedWindows: [LimitWindow] = []
    private static let refreshCoordinator = AGMRefreshCoordinator()

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
        let refresh = await Self.refreshCoordinator.refreshIfNeeded(
            executable: executable,
            ttl: liveTTL,
            now: now
        )
        if let refreshedAt = refresh.successfulAt {
            lastSuccessfulRefresh = refreshedAt
        }
        if refresh.attempted, !refresh.fullySuccessful, let message = refresh.message {
            Log.usage.error("\(self.id, privacy: .public) AGM refresh-all failed: \(message, privacy: .public)")
        }

        let info = await AGMBridge.info(executable: executable, profile: profile)
        let list = await AGMBridge.list(executable: executable)
        let summaries = list.exitCode == 0 ? AGMBridge.parseListSummaries(list.stdout) : [:]
        let summary = summaries[profile.email.lowercased()]
        if info.exitCode == 0 {
            let rows = AGMBridge.reconcileQuotaRows(AGMBridge.parseQuotaInfo(info.stdout), with: summary)
            let windows = Self.windows(from: rows, now: now)
            if !windows.isEmpty {
                cachedWindows = windows
                let status: ProviderStatus = refresh.attempted && !refresh.fullySuccessful
                    ? .stale(since: lastSuccessfulRefresh ?? now)
                    : .ok
                return snapshot(windows: windows, status: status)
            }
        }

        if !cachedWindows.isEmpty {
            return snapshot(windows: cachedWindows,
                            status: .stale(since: lastSuccessfulRefresh ?? now))
        }

        let message = refresh.message ?? info.combinedError
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
            let reset = row.resetTime.flatMap(AntigravityCredentials.parse)
            let interval = reset.map { $0.timeIntervalSince(now) }
            let weekly = (interval ?? 0) > 24 * 3600
            let group = row.provider == "GOOGLE"
                ? L10n.t("Gemini Models")
                : L10n.t("Claude and GPT models")
            let prefix = row.provider == "GOOGLE" ? "gemini" : "3p"
            let model = slug(row.model)
            let cadence = reset == nil ? "unknown" : (weekly ? "weekly" : "hourly")
            return LimitWindow(
                id: "\(prefix)-\(model)-\(cadence)",
                group: group,
                label: row.model,
                usedFraction: 1 - Double(row.remainingPercent) / 100,
                resetsAt: reset,
                duration: reset == nil ? nil : (weekly ? 7 * 86400 : 5 * 3600)
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