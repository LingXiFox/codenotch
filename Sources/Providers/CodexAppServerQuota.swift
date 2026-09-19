import Foundation

/// Read-only one-shot client for Codex's supported app-server rate-limit API.
/// It never starts a thread or sends a prompt; it only initializes the local
/// JSON-RPC server and calls `account/rateLimits/read`.
enum CodexAppServerQuota {
    struct Snapshot: Equatable, Sendable {
        let windows: [LimitWindow]
        let plan: String?
    }

    static func fetch(profile: CodexProfile, timeout: TimeInterval = 10) async -> Snapshot? {
        guard let executable = findExecutable() else { return nil }
        return await Task.detached(priority: .utility) {
            run(executable: executable, profile: profile, timeout: timeout)
        }.value
    }

    static func parseResponse(_ data: Data, now: Date = Date()) -> Snapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any] else { return nil }

        let direct = result["rateLimits"] as? [String: Any]
        let byID = result["rateLimitsByLimitId"] as? [String: Any]
        let codex = byID?["codex"] as? [String: Any]
        let source = usableRateLimit(direct) ? direct : codex
        guard let source else { return nil }

        var windows: [LimitWindow] = []
        if let primary = source["primary"] as? [String: Any],
           let window = window(id: "primary", object: primary, now: now) {
            windows.append(window)
        }
        if let secondary = source["secondary"] as? [String: Any],
           let window = window(id: "secondary", object: secondary, now: now) {
            windows.append(window)
        }
        guard !windows.isEmpty else { return nil }

        let plan = (source["planType"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Snapshot(windows: windows, plan: plan?.isEmpty == false ? plan : nil)
    }

    static func findExecutable(fileManager: FileManager = .default) -> URL? {
        let env = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        if let explicit = env["CODENOTCH_CODEX_PATH"], !explicit.isEmpty {
            candidates.append(explicit)
        }
        if let path = env["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/codex" })
        }
        let home = NSHomeDirectory()
        candidates.append(contentsOf: [
            "\(home)/.local/bin/codex",
            "\(home)/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ])
        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lic", "command -v codex 2>/dev/null"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let path = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .last?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty, fileManager.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    private static func run(executable: URL, profile: CodexProfile, timeout: TimeInterval) -> Snapshot? {
        // Prefer the flag supported by current Codex builds, but retry without
        // it for older installations where stdio is the default transport.
        for arguments in [["app-server", "--stdio"], ["app-server"]] {
            if let snapshot = runOnce(executable: executable,
                                      arguments: arguments,
                                      profile: profile,
                                      timeout: timeout) {
                return snapshot
            }
        }
        return nil
    }

    private static func runOnce(executable: URL,
                                arguments: [String],
                                profile: CodexProfile,
                                timeout: TimeInterval) -> Snapshot? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = profile.configDirectory.path
        process.environment = environment

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var buffer = Data()
        var response: Data?

        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            lock.lock()
            defer { lock.unlock() }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                guard response == nil,
                      let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      Self.int(object["id"]) == 2 else { continue }
                response = Data(line)
                semaphore.signal()
            }
        }

        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            return nil
        }

        let messages = [
            #"{"jsonrpc":"2.0","method":"initialize","id":1,"params":{"clientInfo":{"name":"codenotch","title":"Codenotch","version":"1.0"}}}"#,
            #"{"jsonrpc":"2.0","method":"initialized","params":{}}"#,
            #"{"jsonrpc":"2.0","method":"account/rateLimits/read","id":2,"params":{}}"#,
        ]
        for message in messages {
            guard let data = (message + "\n").data(using: .utf8) else { continue }
            input.fileHandleForWriting.write(data)
        }

        let deadline = DispatchTime.now() + timeout
        _ = semaphore.wait(timeout: deadline)
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }

        lock.lock()
        let final = response
        lock.unlock()
        guard let final else { return nil }
        return parseResponse(final)
    }

    private static func usableRateLimit(_ value: [String: Any]?) -> Bool {
        guard let value else { return false }
        return value["primary"] is [String: Any] || value["secondary"] is [String: Any]
    }

    private static func window(id: String, object: [String: Any], now: Date) -> LimitWindow? {
        guard let used = number(object["usedPercent"]), used.isFinite else { return nil }
        let durationMinutes = number(object["windowDurationMins"])
        let resets = number(object["resetsAt"])
        let duration = durationMinutes.map { $0 * 60 }
        let resetDate = resets.map { Date(timeIntervalSince1970: $0) }
        let label: String
        if let duration {
            let hours = duration / 3600
            if abs(hours - 5) < 0.1 { label = L10n.t("5h limit") }
            else if abs(duration - 7 * 86400) < 3600 { label = L10n.t("Weekly limit") }
            else if duration >= 86400 { label = L10n.t("\(Int((duration / 86400).rounded()))d limit") }
            else { label = L10n.t("\(Int(hours.rounded()))h limit") }
        } else {
            label = id == "primary" ? L10n.t("Current session") : L10n.t("Longer window")
        }
        return LimitWindow(
            id: id,
            label: label,
            usedFraction: min(max(used / 100, 0), 1),
            resetsAt: resetDate,
            duration: duration
        )
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let value as Double: return value
        case let value as Int: return Double(value)
        case let value as NSNumber: return value.doubleValue
        case let value as String: return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default: return nil
        }
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }
}
