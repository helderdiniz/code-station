import Foundation

// MARK: - Claude Code

// The numbers Claude Code's own `/usage` shows. They come from an endpoint of the Claude
// account that the CLI calls with its login, which it keeps in the login keychain.
enum ClaudeUsage {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let beta = "oauth-2025-04-20"

    // The windows in the order `/usage` lists them, with the names it gives them.
    static let kinds: [(kind: String, title: String, shortTitle: String)] = [
        ("five_hour", "Current session", "Session"),
        ("seven_day", "Current week (all models)", "Week"),
        ("seven_day_sonnet", "Current week (Sonnet)", "Week · Sonnet"),
        ("seven_day_opus", "Current week (Opus)", "Week · Opus"),
    ]

    // The session window is five hours and the rest run a week, which the endpoint takes
    // as known rather than saying.
    static func length(of kind: String) -> TimeInterval? {
        if kind == "five_hour" { return 5 * 3_600 }
        return kind.hasPrefix("seven_day") ? 7 * 86_400 : nil
    }

    static func decode(_ data: Data, checkedAt: Date = Date()) -> AccountUsage? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var windows: [AccountUsageWindow] = kinds.compactMap { kind, title, shortTitle in
            guard let raw = object[kind] as? [String: Any],
                  let utilization = number(raw["utilization"]) else { return nil }
            return AccountUsageWindow(id: kind, title: title,
                                      usedPercent: percent(utilization),
                                      resetsAt: (raw["resets_at"] as? String).flatMap(isoDate),
                                      shortTitle: shortTitle, length: length(of: kind))
        }
        if let extra = object["extra_usage"] as? [String: Any],
           extra["is_enabled"] as? Bool == true,
           let utilization = number(extra["utilization"]) {
            windows.append(AccountUsageWindow(id: "extra_usage", title: "Extra usage this month",
                                              usedPercent: percent(utilization), resetsAt: nil,
                                              shortTitle: "Extra usage"))
        }
        // An account with no limits to report still answers, with every window empty.
        guard !windows.isEmpty || kinds.contains(where: { object.keys.contains($0.kind) }) else {
            return nil
        }
        return AccountUsage(windows: windows, checkedAt: checkedAt)
    }

    static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        return (value as? NSNumber)?.doubleValue
    }

    // Already a percentage here, unlike the fraction the stream carries.
    private static func percent(_ utilization: Double) -> Int {
        min(100, max(0, Int(utilization.rounded(.down))))
    }

    static func isoDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        // Microseconds are more digits than the formatter takes.
        let trimmed = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return formatter.date(from: trimmed)
    }
}

// The login Claude Code keeps for the account. Only read, never renewed: renewing it
// would hand Claude Code a login it does not know about and sign it out.
struct ClaudeCredentials: Equatable, Sendable {
    static let keychainService = "Claude Code-credentials"

    let accessToken: String
    let expiresAt: Date?

    func hasExpired(at date: Date) -> Bool {
        expiresAt.map { $0 <= date } ?? false
    }

    static func parse(_ data: Data) -> ClaudeCredentials? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        let expiresAt = ClaudeUsage.number(oauth["expiresAt"])
            .map { Date(timeIntervalSince1970: $0 / 1000) }
        return ClaudeCredentials(accessToken: token, expiresAt: expiresAt)
    }

    // Read through `security` rather than by the app itself. The keychain asks once
    // whether `security` may read the item, and remembers the answer; the app's own
    // binary changes with every build, and would be asked again each time.
    static func read() async -> ClaudeCredentials? {
        guard let output = try? await CommandRunner.run(
            executable: "/usr/bin/security",
            arguments: ["find-generic-password", "-s", keychainService, "-w"],
            timeout: .seconds(60),
            outputByteLimit: 65_536
        ), output.succeeded else { return nil }
        return parse(Data(output.output.utf8))
    }
}

actor ClaudeUsageSource: AccountUsageSource {
    nonisolated let agent = AgentKind.claudeCode

    private let session: URLSession
    private let credentials: @Sendable () async -> ClaudeCredentials?
    private let now: @Sendable () -> Date
    // Held so a read every few minutes does not go to the keychain each time.
    private var cached: ClaudeCredentials?
    // A refused or missing login is not asked for again for a while, since each ask can
    // put the keychain's prompt back on screen.
    private var credentialsFailedAt: Date?
    static let credentialsRetry: TimeInterval = 3_600

    init(session: URLSession = .shared,
         credentials: @escaping @Sendable () async -> ClaudeCredentials? = ClaudeCredentials.read,
         now: @escaping @Sendable () -> Date = Date.init) {
        self.session = session
        self.credentials = credentials
        self.now = now
    }

    func read() async -> AccountUsageReading {
        let recentlyFailed = credentialsFailedAt.map { now().timeIntervalSince($0) < Self.credentialsRetry } ?? false
        if (cached == nil || cached?.hasExpired(at: now()) == true) && !recentlyFailed {
            cached = await credentials()
            credentialsFailedAt = cached == nil ? now() : nil
        }
        guard let login = cached else {
            return .unavailable("Sign in to Claude Code, and allow the keychain to share its login, to see its limits.")
        }
        guard !login.hasExpired(at: now()) else {
            return .unavailable("Claude Code's login has expired. It renews it on its next turn.")
        }

        var request = URLRequest(url: ClaudeUsage.endpoint, timeoutInterval: 15)
        request.setValue("Bearer \(login.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(ClaudeUsage.beta, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else {
            return .unavailable("Claude's usage could not be reached.")
        }
        switch http.statusCode {
        case 200:
            return ClaudeUsage.decode(data, checkedAt: now()).map { .usage($0) }
                ?? .unavailable("Claude answered with usage this app cannot read.")
        case 401:
            cached = nil
            return .unavailable("Claude refused the login. Run /login in Claude Code.")
        // A missing permission does not pass with time, unlike being asked to slow down.
        case 403:
            return .unavailable("Claude Code's login is not allowed to read its usage. Run /login in Claude Code.")
        case 429:
            return .retryAfter(retryAfter(http))
        default:
            return .unavailable("Claude's usage could not be read (HTTP \(http.statusCode)).")
        }
    }
}

// MARK: - Codex

// Codex answers for its limits through its app server, the same read the settings pane
// already makes.
struct CodexUsageSource: AccountUsageSource {
    let agent = AgentKind.codex

    func read() async -> AccountUsageReading {
        guard let path = ProcessManager.resolve("codex") else {
            return .unavailable("Codex is not installed.")
        }
        guard let usage = await CodexUsageReader.read(at: path, searchPath: ProcessManager.searchPath) else {
            return .unavailable("Codex did not report its limits. Sign in to Codex to see them.")
        }
        return .usage(AccountUsage(windows: usage.windows, checkedAt: usage.checkedAt))
    }
}

// MARK: - Copilot

// Copilot's monthly allowances, from the endpoint its editors read. It takes the GitHub
// login the `gh` CLI holds.
enum CopilotUsage {
    static let endpoint = URL(string: "https://api.github.com/copilot_internal/user")!

    private static let quotas: [(key: String, title: String, shortTitle: String)] = [
        ("premium_interactions", "Premium requests this month", "Premium"),
        ("chat", "Chat messages this month", "Chat"),
        ("completions", "Code completions this month", "Completions"),
    ]

    enum Decoded: Equatable {
        case usage(AccountUsage)
        case unlimited
    }

    static func decode(_ data: Data, checkedAt: Date = Date()) -> Decoded? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let snapshots = object["quota_snapshots"] as? [String: Any] else { return nil }
        let resetsAt = (object["quota_reset_date_utc"] as? String).flatMap(ClaudeUsage.isoDate)
            ?? (object["quota_reset_date"] as? String).flatMap(day)
        var sawUnlimited = false
        let windows: [AccountUsageWindow] = quotas.compactMap { key, title, shortTitle in
            guard let quota = snapshots[key] as? [String: Any] else { return nil }
            if quota["unlimited"] as? Bool == true {
                sawUnlimited = true
                return nil
            }
            guard let remaining = ClaudeUsage.number(quota["percent_remaining"]) else { return nil }
            let used = min(100, max(0, Int((100 - remaining).rounded())))
            return AccountUsageWindow(id: key, title: title, usedPercent: used, resetsAt: resetsAt,
                                      shortTitle: shortTitle)
        }
        if windows.isEmpty { return sawUnlimited ? .unlimited : nil }
        return .usage(AccountUsage(windows: windows, checkedAt: checkedAt))
    }

    private static func day(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)
    }
}

struct CopilotUsageSource: AccountUsageSource {
    let agent = AgentKind.copilot
    var session: URLSession = .shared

    func read() async -> AccountUsageReading {
        guard let token = await Self.githubToken() else {
            return .unavailable("Sign in with the GitHub CLI (gh auth login) to see Copilot's allowances.")
        }
        var request = URLRequest(url: CopilotUsage.endpoint, timeoutInterval: 15)
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else {
            return .unavailable("GitHub could not be reached.")
        }
        switch http.statusCode {
        case 200:
            switch CopilotUsage.decode(data) {
            case .usage(let usage): return .usage(usage)
            case .unlimited: return .unavailable("This Copilot plan has no monthly limit.")
            case nil: return .unavailable("GitHub answered with allowances this app cannot read.")
            }
        case 403:
            return .unavailable("This GitHub account has no access to Copilot's allowances.")
        case 429:
            return .retryAfter(retryAfter(http))
        default:
            return .unavailable("Copilot's allowances could not be read (HTTP \(http.statusCode)).")
        }
    }

    private static func githubToken() async -> String? {
        guard let gh = ProcessManager.resolve("gh") else { return nil }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ProcessManager.searchPath
        guard let output = try? await CommandRunner.run(
            executable: gh, arguments: ["auth", "token"], environment: environment,
            timeout: .seconds(10), outputByteLimit: 8_192
        ), output.succeeded else { return nil }
        let token = output.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }
}

// MARK: - Shared

// How long a service asked to be left alone, or a few minutes when it did not say.
private func retryAfter(_ response: HTTPURLResponse) -> Duration {
    let seconds = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
        ?? AccountUsageMonitor.defaultBackoff
    return .seconds(min(3_600, max(60, seconds)))
}
