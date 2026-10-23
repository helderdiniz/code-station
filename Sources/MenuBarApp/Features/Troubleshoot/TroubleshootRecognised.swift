import Foundation

// What a brief already names, read off its text as it is typed: the trace ids, a time, the
// projects it mentions and a version. Showing them back under the editor is what tells the
// person a pasted id or link was understood before the brief is sent. Nothing here changes
// the brief; the agent still reads the words as they were written.
enum TroubleshootRecognised {
    enum Kind: Equatable {
        case trace
        case time
        case projects
        case version
    }

    struct Detail: Identifiable, Equatable {
        let kind: Kind
        let label: String

        var id: String { label }

        var icon: String {
            switch kind {
            case .trace: "link"
            case .time: "clock"
            case .projects: "shippingbox"
            case .version: "tag"
            }
        }
    }

    static func details(in text: String, projects: [String] = []) -> [Detail] {
        var found: [Detail] = []
        for traceID in TraceInput.traceIDs(in: text) {
            found.append(Detail(kind: .trace, label: "Trace " + shortened(traceID)))
        }
        if let time = timeWindow(in: text) {
            found.append(Detail(kind: .time, label: time))
        }
        let named = projects.filter { !$0.isEmpty && text.localizedCaseInsensitiveContains($0) }
        if !named.isEmpty {
            found.append(Detail(kind: .projects, label: named.joined(separator: ", ")))
        }
        if let version = text.firstMatch(of: versionPattern) {
            found.append(Detail(kind: .version, label: "Version \(version.output.1)"))
        }
        return found
    }

    // "Since 14:05 UTC": a clock time led by a word that places it. The leading word is
    // kept, since "since" and "at" ask the agent for different windows, and the zone is
    // kept only when one was written. Nothing is assumed about one that was not.
    static func timeWindow(in text: String) -> String? {
        guard let match = text.firstMatch(of: timePattern) else { return nil }
        let lead = String(match.output.1)
        let time = String(match.output.2)
        let zone = match.output.3.map { " " + String($0).uppercased() } ?? ""
        return lead.prefix(1).uppercased() + lead.dropFirst().lowercased() + " " + time + zone
    }

    // The first eight characters and the last four, which is how a trace id is read back
    // in a conversation: enough to tell two apart, short enough for a chip.
    static func shortened(_ traceID: String) -> String {
        guard traceID.count > 14 else { return traceID }
        return String(traceID.prefix(8)) + "…" + String(traceID.suffix(4))
    }

    // Built on each use: a regex is not safe to share between threads.
    private static var timePattern: Regex<(Substring, Substring, Substring, Substring?)> {
        /\b(since|at|around|from|after|before)\s+(?:about\s+|around\s+|roughly\s+)?(\d{1,2}:\d{2})(?:\s*(UTC|GMT|Z|BST|CET|CEST|WET|WEST|EET|EEST|EST|EDT|CST|CDT|PST|PDT))?\b/
            .ignoresCase()
    }

    // Three numbers with dots between, and nothing dotted on either side, so the first
    // three parts of an IP address are not read as a release.
    private static var versionPattern: Regex<(Substring, Substring)> {
        /(?:^|[^\d.])(\d+\.\d+\.\d+)(?![\d.])/
    }
}

// How much a diagnosis has turned up, by kind, for the strip that sits over its
// conversation. Counted off the same items the Evidence tab draws, so the two agree.
struct TroubleshootEvidenceTally: Equatable {
    var traces = 0
    var logLines = 0
    var queries = 0
    var charts = 0

    @MainActor
    init(messages: [ChatMessage]) {
        for item in TroubleshootEvidence.items(in: messages) {
            switch item.kind {
            case .trace, .fetchedTrace:
                traces += 1
            case .logs(let spec):
                logLines += spec.entries.count
            case .query(let rendering):
                if case .logs(let entries, _) = rendering.result {
                    logLines += entries.count
                } else {
                    queries += 1
                }
            case .chart:
                charts += 1
            }
        }
    }

    var isEmpty: Bool { traces == 0 && logLines == 0 && queries == 0 && charts == 0 }

    // "1 trace", "14 log lines", "2 queries", "1 chart": only the kinds there are any of.
    var readings: [String] {
        [
            traces > 0 ? counted(traces, "trace") : nil,
            logLines > 0 ? counted(logLines, "log line") : nil,
            queries > 0 ? counted(queries, "query", plural: "queries") : nil,
            charts > 0 ? counted(charts, "chart") : nil,
        ].compactMap { $0 }
    }
}
