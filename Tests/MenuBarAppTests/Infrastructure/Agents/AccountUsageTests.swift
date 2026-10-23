import Foundation
import Testing
@testable import MenuBarApp

// The account limits each agent keeps, read the way that agent's own usage view reads
// them, and moved on by what a running turn reports.
struct AccountUsageTests {

    // MARK: - Claude

    @Test func readsClaudeWindowsInTheOrderUsageListsThem() throws {
        let body = """
        {"five_hour":{"utilization":42.7,"resets_at":"2026-10-17T15:00:00.412673+00:00"},
         "seven_day":{"utilization":18,"resets_at":"2026-10-21T09:00:00Z"},
         "seven_day_opus":null,
         "seven_day_sonnet":{"utilization":3.0,"resets_at":"2026-10-21T09:00:00+00:00"},
         "extra_usage":{"is_enabled":false,"utilization":null}}
        """
        let usage = try #require(ClaudeUsage.decode(Data(body.utf8)))
        #expect(usage.windows.map(\.id) == ["five_hour", "seven_day", "seven_day_sonnet"])
        #expect(usage.windows.map(\.usedPercent) == [42, 18, 3])
        #expect(usage.windows.first?.title == "Current session")
        // Microseconds and all, which the formatter would otherwise refuse.
        let session = try #require(usage.windows.first?.resetsAt)
        #expect(abs(session.timeIntervalSince1970 - 1_792_249_200) < 1)
        #expect(usage.windows.first?.shortTitle == "Session")
        #expect(usage.windows[1].resetsAt == Date(timeIntervalSince1970: 1_792_573_200))
    }

    @Test func claudeExtraUsageIsShownOnlyWhenTurnedOn() throws {
        let body = """
        {"five_hour":{"utilization":5,"resets_at":null},
         "extra_usage":{"is_enabled":true,"monthly_limit":5000,"used_credits":1250,"utilization":25.0}}
        """
        let usage = try #require(ClaudeUsage.decode(Data(body.utf8)))
        #expect(usage.windows.map(\.id) == ["five_hour", "extra_usage"])
        #expect(usage.windows.last?.usedPercent == 25)
        #expect(usage.windows.first?.resetsAt == nil)
    }

    @Test func anAnswerWithoutWindowsIsNotUsage() {
        #expect(ClaudeUsage.decode(Data(#"{"error":"nope"}"#.utf8)) == nil)
        #expect(ClaudeUsage.decode(Data("not json".utf8)) == nil)
    }

    @Test func readsTheLoginClaudeCodeKeeps() throws {
        let stored = """
        {"claudeAiOauth":{"accessToken":"sk-ant-oat01-abc","refreshToken":"sk-ant-ort01-def",\
        "expiresAt":1792249200000,"scopes":["user:inference","user:profile"]}}
        """
        let login = try #require(ClaudeCredentials.parse(Data(stored.utf8)))
        #expect(login.accessToken == "sk-ant-oat01-abc")
        #expect(login.expiresAt == Date(timeIntervalSince1970: 1_792_249_200))
        #expect(!login.hasExpired(at: Date(timeIntervalSince1970: 1_792_249_199)))
        #expect(login.hasExpired(at: Date(timeIntervalSince1970: 1_792_249_200)))
        #expect(ClaudeCredentials.parse(Data(#"{"claudeAiOauth":{"accessToken":""}}"#.utf8)) == nil)
    }

    @Test func anExpiredLoginIsNotSentOrRenewed() async {
        let source = ClaudeUsageSource(
            credentials: { ClaudeCredentials(accessToken: "x", expiresAt: Date(timeIntervalSince1970: 10)) },
            now: { Date(timeIntervalSince1970: 20) })
        guard case .unavailable(let reason) = await source.read() else {
            Issue.record("expected the reading to be unavailable")
            return
        }
        #expect(reason.contains("expired"))
    }

    @Test func aRefusedKeychainIsNotAskedAgainOnEveryRead() async {
        final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_000) }
        actor Asks { var count = 0; func add() { count += 1 } }
        let clock = Clock()
        let asks = Asks()
        let source = ClaudeUsageSource(
            credentials: { await asks.add(); return nil },
            now: { clock.now })
        _ = await source.read()
        clock.now += 300
        _ = await source.read()
        #expect(await asks.count == 1)
        clock.now += ClaudeUsageSource.credentialsRetry
        _ = await source.read()
        #expect(await asks.count == 2)
    }

    // MARK: - Copilot

    @Test func readsCopilotAllowances() throws {
        let body = """
        {"copilot_plan":"individual","quota_reset_date":"2026-11-01",
         "quota_snapshots":{
           "premium_interactions":{"entitlement":300,"remaining":210,"percent_remaining":70.0,"unlimited":false},
           "chat":{"unlimited":true},"completions":{"unlimited":true}}}
        """
        guard case .usage(let usage)? = CopilotUsage.decode(Data(body.utf8)) else {
            Issue.record("expected Copilot usage")
            return
        }
        #expect(usage.windows.map(\.id) == ["premium_interactions"])
        #expect(usage.windows.first?.usedPercent == 30)
        #expect(usage.windows.first?.resetsAt == Date(timeIntervalSince1970: 1_793_491_200))
    }

    @Test func anUnlimitedCopilotPlanHasNothingToCount() {
        let body = #"{"quota_snapshots":{"premium_interactions":{"unlimited":true}}}"#
        #expect(CopilotUsage.decode(Data(body.utf8)) == .unlimited)
        #expect(CopilotUsage.decode(Data(#"{"login":"me"}"#.utf8)) == nil)
    }

    // MARK: - What a turn reports

    @Test func readsEveryWindowARateLimitEventCarries() {
        let line = """
        {"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1792249200,\
        "rateLimitType":"five_hour","unifiedWindows":{"five_hour":{"utilization":0.31,"resetsAt":1792249200},\
        "seven_day":{"utilization":0.12,"resetsAt":1792573200}}},"session_id":"c716258a"}
        """
        guard case .rateLimit(let limit)? = StreamEvent.parse(line).first else {
            Issue.record("expected a rate limit event")
            return
        }
        #expect(limit.utilization == nil)
        #expect(limit.windows["five_hour"] == RateLimit.Window(
            utilization: 0.31, resetsAt: Date(timeIntervalSince1970: 1_792_249_200)))
        #expect(limit.windows["seven_day"]?.utilization == 0.12)

        let live = AccountUsageMonitor.liveWindows(limit)
        #expect(live.map(\.id) == ["five_hour", "seven_day"])
        #expect(live.map(\.usedPercent) == [31, 12])
    }

    @Test func aTurnMovesTheWindowsItReportsAndKeepsTheRest() {
        let read = AccountUsage(windows: [
            AccountUsageWindow(id: "five_hour", title: "Current session", usedPercent: 20, resetsAt: nil),
            AccountUsageWindow(id: "seven_day_sonnet", title: "Current week (Sonnet)", usedPercent: 4, resetsAt: nil),
        ], checkedAt: Date(timeIntervalSince1970: 0))
        let live = [
            AccountUsageWindow(id: "seven_day", title: "Current week (all models)", usedPercent: 11, resetsAt: nil),
            AccountUsageWindow(id: "five_hour", title: "Current session", usedPercent: 26, resetsAt: nil),
        ]
        let merged = AccountUsageMonitor.merged(read, live: live, at: Date(timeIntervalSince1970: 5))
        #expect(merged.windows.map(\.id) == ["five_hour", "seven_day", "seven_day_sonnet"])
        #expect(merged.windows.map(\.usedPercent) == [26, 11, 4])
        #expect(merged.checkedAt == Date(timeIntervalSince1970: 5))
    }

    @MainActor
    @Test func anOlderEventDoesNotUndoANewerOne() {
        let monitor = AccountUsageMonitor(sources: [])
        let earlierWarning = RateLimit(kind: "seven_day", status: "allowed_warning", resetsAt: nil,
                                       utilization: 0.8,
                                       windows: ["five_hour": .init(utilization: 0.9, resetsAt: nil),
                                                 "seven_day": .init(utilization: 0.8, resetsAt: nil)])
        let later = RateLimit(kind: "five_hour", status: "allowed", resetsAt: nil, utilization: nil,
                              windows: ["five_hour": .init(utilization: 0.1, resetsAt: nil),
                                        "seven_day": .init(utilization: 0.82, resetsAt: nil)])
        monitor.absorb(earlierWarning, for: .claudeCode)
        monitor.absorb(later, for: .claudeCode)
        #expect(monitor.usage[.claudeCode]?.windows.map(\.usedPercent) == [10, 82])
    }

    // MARK: - The card

    @Test func aResetSaysTheDayOnlyWhenItIsNotToday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let now = Date(timeIntervalSince1970: 1_792_195_200) // midnight UTC
        let later = now.addingTimeInterval(9 * 3_600)
        let friday = now.addingTimeInterval(4 * 86_400 + 9 * 3_600)
        let nextMonth = now.addingTimeInterval(20 * 86_400)
        let time = later.formatted(date: .omitted, time: .shortened)
        #expect(AccountUsageWindow.resetLine(later, now: now, calendar: calendar) == time)
        #expect(AccountUsageWindow.resetLine(friday, now: now, calendar: calendar).hasSuffix(time))
        #expect(AccountUsageWindow.resetLine(friday, now: now, calendar: calendar) != time)
        #expect(!AccountUsageWindow.resetLine(nextMonth, now: now, calendar: calendar).contains(":"))
    }

    @Test func theUsageBandSaysHowOldTheReadingIs() {
        #expect(SessionFactsChip.usageStatus(checkedAt: nil, checking: false, hasProblem: false)
                == "not checked yet")
        #expect(SessionFactsChip.usageStatus(checkedAt: nil, checking: false, hasProblem: true)
                == "couldn't check")
        #expect(SessionFactsChip.usageStatus(checkedAt: Date(), checking: true, hasProblem: false)
                == "checking…")
        #expect(SessionFactsChip.usageStatus(checkedAt: Date(), checking: false, hasProblem: false)
                == "checked just now")
        #expect(SessionFactsChip.usageStatus(checkedAt: Date().addingTimeInterval(-300),
                                             checking: false, hasProblem: false)
                == "checked 5m ago")
        // A failed check is the news, even with an older reading still on screen.
        #expect(SessionFactsChip.usageStatus(checkedAt: Date().addingTimeInterval(-300),
                                             checking: false, hasProblem: true)
                == "couldn't check")
    }

    @Test func aFailedCheckSaysHowOldTheLastGoodReadingIs() {
        #expect(SessionFactsChip.problemLine("Claude's usage could not be reached.", lastReading: nil)
                == "Claude's usage could not be reached.")
        #expect(SessionFactsChip.problemLine("Claude's usage could not be reached.",
                                             lastReading: Date().addingTimeInterval(-52 * 60))
                == "Claude's usage could not be reached. The last good reading was 52m ago.")
    }

    // MARK: - Pace

    private func window(used: Int, resetsIn: TimeInterval?, length: TimeInterval?,
                        now: Date) -> AccountUsageWindow {
        AccountUsageWindow(id: "five_hour", title: "Current session", usedPercent: used,
                           resetsAt: resetsIn.map { now.addingTimeInterval($0) },
                           shortTitle: "Session", length: length)
    }

    @Test func placesThePaceMarkAtTheElapsedShareOfTheWindow() {
        let now = Date()
        let halfway = window(used: 10, resetsIn: 2.5 * 3_600, length: 5 * 3_600, now: now)
        #expect(abs((halfway.elapsedFraction(now: now) ?? 0) - 0.5) < 0.0001)
        // Without a length the start is unknown, so there is no mark to draw.
        #expect(window(used: 10, resetsIn: 3_600, length: nil, now: now).elapsedFraction(now: now) == nil)
        #expect(window(used: 10, resetsIn: nil, length: 5 * 3_600, now: now).elapsedFraction(now: now) == nil)
        // A reset further off than the window is long means the window has not started.
        #expect(window(used: 0, resetsIn: 6 * 3_600, length: 5 * 3_600, now: now).elapsedFraction(now: now) == nil)
    }

    @Test func flagsAWindowBurningFasterThanTime() {
        let now = Date()
        // Half the time gone: 55% is within the slack, 56% is ahead.
        #expect(window(used: 55, resetsIn: 2.5 * 3_600, length: 5 * 3_600, now: now).pace(now: now) == .steady)
        #expect(window(used: 56, resetsIn: 2.5 * 3_600, length: 5 * 3_600, now: now).pace(now: now) == .ahead)
        #expect(window(used: 100, resetsIn: 2.5 * 3_600, length: 5 * 3_600, now: now).pace(now: now) == .usedUp)
        // With no clock to measure against, only a full window is worth saying.
        #expect(window(used: 90, resetsIn: nil, length: nil, now: now).pace(now: now) == .steady)
        #expect(window(used: 100, resetsIn: nil, length: nil, now: now).pace(now: now) == .usedUp)
    }

    @Test func saysWhenAWindowResetsWithoutAHover() {
        let now = Date()
        #expect(window(used: 4, resetsIn: 3 * 3_600 + 12 * 60, length: nil, now: now)
                    .resetsLine(now: now) == "resets in 3h 12m")
        #expect(window(used: 4, resetsIn: 20 * 60, length: nil, now: now).resetsLine(now: now)
                    == "resets in 20m")
        let later = now.addingTimeInterval(3 * 86_400)
        #expect(window(used: 4, resetsIn: 3 * 86_400, length: nil, now: now).resetsLine(now: now)
                    == "resets \(AccountUsageWindow.resetLine(later, now: now))")
        #expect(window(used: 4, resetsIn: nil, length: nil, now: now).resetsLine(now: now) == nil)
    }

    @Test func speaksAWindowWithItsPaceAndReset() {
        let now = Date()
        let busy = window(used: 71, resetsIn: 2 * 3_600 + 24 * 60, length: 5 * 3_600, now: now)
        #expect(SessionFactsChip.windowSpoken(busy, pace: busy.pace(now: now),
                                              resets: busy.resetsLine(now: now))
                    == "Current session, 71% used, ahead of pace, resets in 2h 24m")
    }

    @Test func knowsHowLongClaudesWindowsRun() {
        #expect(ClaudeUsage.length(of: "five_hour") == TimeInterval(5 * 3_600))
        #expect(ClaudeUsage.length(of: "seven_day") == TimeInterval(7 * 86_400))
        #expect(ClaudeUsage.length(of: "seven_day_opus") == TimeInterval(7 * 86_400))
        #expect(ClaudeUsage.length(of: "extra_usage") == nil)
    }

    // MARK: - The monitor

    @MainActor
    @Test func theMonitorKeepsTheLastReadingThroughAProblem() async {
        let source = ScriptedSource(readings: [
            .usage(AccountUsage(windows: [
                AccountUsageWindow(id: "five_hour", title: "Current session", usedPercent: 40, resetsAt: nil),
            ], checkedAt: Date(timeIntervalSince1970: 0))),
            .unavailable("Claude's usage could not be reached."),
        ])
        let monitor = AccountUsageMonitor(sources: [source])
        #expect(monitor.supports(.claudeCode))
        #expect(!monitor.supports(.codex))

        await monitor.refresh(.claudeCode)
        #expect(monitor.usage[.claudeCode]?.windows.first?.usedPercent == 40)
        #expect(monitor.problems[.claudeCode] == nil)

        await monitor.refresh(.claudeCode)
        #expect(monitor.usage[.claudeCode]?.windows.first?.usedPercent == 40)
        #expect(monitor.problems[.claudeCode] == "Claude's usage could not be reached.")
    }

    @MainActor
    @Test func theMonitorWaitsWhenTheServiceAsksItTo() async {
        let source = ScriptedSource(readings: [
            .retryAfter(.seconds(300)),
            .unavailable("should not be asked"),
        ])
        var clock = Date(timeIntervalSince1970: 1_000)
        let monitor = AccountUsageMonitor(sources: [source], now: { clock })

        await monitor.refresh(.claudeCode)
        await monitor.refresh(.claudeCode)
        #expect(await source.reads == 1)

        clock = clock.addingTimeInterval(301)
        await monitor.refresh(.claudeCode)
        #expect(await source.reads == 2)
    }
}

private actor ScriptedSource: AccountUsageSource {
    nonisolated let agent = AgentKind.claudeCode
    private var readings: [AccountUsageReading]
    private(set) var reads = 0

    init(readings: [AccountUsageReading]) { self.readings = readings }

    func read() async -> AccountUsageReading {
        reads += 1
        return readings.isEmpty ? .unavailable("done") : readings.removeFirst()
    }
}
