import Foundation
import SwiftUI

// How much of an agent account's limits has gone, as each agent's own `/usage` would put
// it. The limits belong to the account rather than to any session, so they are read on
// their own and held once per agent, whichever session is on screen.
struct AccountUsage: Equatable, Sendable {
    let windows: [AccountUsageWindow]
    let checkedAt: Date

    // The window worth showing when there is room for one: the first, which each agent
    // lists as its shortest, unless another is far enough along to be the one that will
    // stop work first.
    var headline: AccountUsageWindow? {
        guard let first = windows.first else { return nil }
        let pressing = windows.filter { $0.usedPercent >= AccountUsageWindow.warningPercent }
            .max { $0.usedPercent < $1.usedPercent }
        guard let pressing, pressing.usedPercent > first.usedPercent else { return first }
        return pressing
    }
}

extension AccountUsageWindow {
    static let warningPercent = 75
    static let criticalPercent = 90

    var colour: Color {
        if usedPercent >= Self.criticalPercent { return Theme.deletion }
        if usedPercent >= Self.warningPercent { return Theme.attention }
        return Theme.dotOn
    }
}

enum AccountUsageReading: Sendable {
    case usage(AccountUsage)
    // Why there is nothing to show, in words the tooltip can use.
    case unavailable(String)
    // The service asked not to be asked again for a while.
    case retryAfter(Duration)
}

// Where one agent keeps its account's limits. Each agent keeps them somewhere different,
// so a new agent only needs a source of its own for the rest of the app to show them.
protocol AccountUsageSource: Sendable {
    var agent: AgentKind { get }
    func read() async -> AccountUsageReading
}

@MainActor
@Observable
final class AccountUsageMonitor {
    nonisolated static let pollInterval: Duration = .seconds(300)
    // A finished turn asks for a fresh read, and a run of short turns would otherwise
    // ask for one each.
    nonisolated static let soonestRepeat: TimeInterval = 60
    nonisolated static let defaultBackoff: TimeInterval = 300

    private(set) var usage: [AgentKind: AccountUsage] = [:]
    private(set) var problems: [AgentKind: String] = [:]
    private(set) var refreshing: Set<AgentKind> = []

    @ObservationIgnored private let sources: [AgentKind: any AccountUsageSource]
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var isInstalled: (AgentKind) -> Bool = { _ in true }
    @ObservationIgnored private var lastAttempt: [AgentKind: Date] = [:]
    @ObservationIgnored private var holdUntil: [AgentKind: Date] = [:]

    init(sources: [any AccountUsageSource] = AccountUsageMonitor.standardSources(),
         now: @escaping () -> Date = Date.init) {
        self.sources = Dictionary(sources.map { ($0.agent, $0) }, uniquingKeysWith: { first, _ in first })
        self.now = now
    }

    nonisolated static func standardSources() -> [any AccountUsageSource] {
        [ClaudeUsageSource(), CodexUsageSource(), CopilotUsageSource()]
    }

    func supports(_ agent: AgentKind) -> Bool { sources[agent] != nil }

    func keepChecking(isInstalled: @escaping (AgentKind) -> Bool) async {
        self.isInstalled = isInstalled
        while !Task.isCancelled {
            for agent in AgentKind.allCases where supports(agent) && isInstalled(agent) {
                await refresh(agent)
            }
            try? await Task.sleep(for: Self.pollInterval)
        }
    }

    func refresh(_ agent: AgentKind) async {
        guard let source = sources[agent], !refreshing.contains(agent) else { return }
        let started = now()
        if let hold = holdUntil[agent], hold > started { return }
        refreshing.insert(agent)
        lastAttempt[agent] = started
        let reading = await source.read()
        refreshing.remove(agent)
        switch reading {
        case .usage(let fresh):
            usage[agent] = fresh
            problems[agent] = nil
        case .unavailable(let reason):
            problems[agent] = reason
        case .retryAfter(let wait):
            holdUntil[agent] = started.addingTimeInterval(Self.seconds(wait))
            problems[agent] = "\(agent.title) asked to wait before its usage is checked again."
        }
    }

    // A read after spend, unless one has just been made.
    func refreshSoon(_ agent: AgentKind) {
        guard supports(agent), isInstalled(agent) else { return }
        if let last = lastAttempt[agent], now().timeIntervalSince(last) < Self.soonestRepeat { return }
        Task { await refresh(agent) }
    }

    // What a running turn reports moves the reading on between reads, without a call of
    // its own.
    func absorb(_ limit: RateLimit, for agent: AgentKind) {
        let live = Self.liveWindows(limit)
        guard !live.isEmpty else { return }
        usage[agent] = Self.merged(usage[agent], live: live, at: now())
    }

    // MARK: - Pure pieces

    // Claude Code reports the windows it read off the turn's responses. Only the windows
    // the usage endpoint also lists are taken, so both sources fill the same rows.
    nonisolated static func liveWindows(_ limit: RateLimit) -> [AccountUsageWindow] {
        var fractions: [String: RateLimit.Window] = [:]
        if let utilization = limit.utilization {
            fractions[limit.kind] = RateLimit.Window(utilization: utilization, resetsAt: limit.resetsAt)
        }
        // The headers speak for every window at once, so they win over a lone warning.
        fractions.merge(limit.windows) { _, window in window }
        return ClaudeUsage.kinds.compactMap { kind, title, shortTitle in
            fractions[kind].map {
                AccountUsageWindow(id: kind, title: title,
                                   usedPercent: min(100, max(0, Int(($0.utilization * 100).rounded()))),
                                   resetsAt: $0.resetsAt, shortTitle: shortTitle)
            }
        }
    }

    nonisolated static func merged(_ usage: AccountUsage?, live: [AccountUsageWindow],
                                   at date: Date) -> AccountUsage {
        var windows = usage?.windows ?? []
        for window in live {
            if let index = windows.firstIndex(where: { $0.id == window.id }) {
                windows[index] = window
            } else {
                windows.append(window)
            }
        }
        let order = ClaudeUsage.kinds.map(\.kind)
        windows.sort {
            (order.firstIndex(of: $0.id) ?? order.count) < (order.firstIndex(of: $1.id) ?? order.count)
        }
        return AccountUsage(windows: windows, checkedAt: date)
    }

    nonisolated private static func seconds(_ duration: Duration) -> TimeInterval {
        let (seconds, attoseconds) = duration.components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
