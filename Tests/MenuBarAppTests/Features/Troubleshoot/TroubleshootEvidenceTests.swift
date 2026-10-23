import Foundation
import Testing
@testable import MenuBarApp

@MainActor
struct TroubleshootEvidenceTests {
    private static let traceID = TraceToolCallTests.id

    private static func drawnTrace(_ id: String = traceID) -> String {
        """
        ```trace
        {"traceId":"\(id)","spans":[{"id":"a1","service":"api","name":"GET /","start":0,"duration":5}]}
        ```
        """
    }

    private static let logs = """
        ```logs
        {"server":"grafana-platform-dev","lines":[{"time":"2026-10-23T14:02:11Z","message":"boom"}]}
        ```
        """

    private static let chart = """
        ```chart
        {"kind":"bar","series":[{"label":"errors","points":[["api",3]]}]}
        ```
        """

    private func reply(_ text: String, tools: [ToolUse] = []) -> ChatMessage {
        ChatMessage(role: .assistant, text: text, tools: tools)
    }

    private func fetchedTrace(id: String = "fetch-1") throws -> ToolUse {
        var tool = try TraceToolCallTests.tool(
            "mcp__grafana-edge-dev__grafana_api_request",
            ["endpoint": "/api/datasources/proxy/uid/T/api/traces/\(Self.traceID)"],
            result: TraceParserTests.v2)
        tool.id = id
        return tool
    }

    private func lokiQuery() throws -> ToolUse {
        var tool = try TraceToolCallTests.tool(
            "mcp__grafana-platform-dev__query_loki_logs", ["logql": "{namespace=\"ledger\"}"],
            result: #"{"data":[{"timestamp":"\"1790935200000000000\"","line":"msg=boom","labels":{}}]}"#)
        tool.id = "loki-1"
        return tool
    }

    @Test func gathersEveryKindOfEvidenceInTheOrderItWasFound() throws {
        let messages = [
            ChatMessage(role: .user, text: Self.drawnTrace()),
            reply("Querying.", tools: [try lokiQuery()]),
            reply("What I found:\n\n\(Self.drawnTrace("b7ad6b7169203331"))\n\n\(Self.logs)\n\n\(Self.chart)"),
        ]
        let items = TroubleshootEvidence.items(in: messages)

        #expect(items.map { TroubleshootEvidenceView.origin($0.kind) } == [
            "QUERIED BY THE AGENT", "DRAWN BY THE AGENT", "LOG LINES THE AGENT PICKED",
            "CHARTED BY THE AGENT",
        ])
        #expect(items.first?.toolID == "loki-1")
        #expect(items.first?.messageID == messages[1].id)
        #expect(items.dropFirst().allSatisfy { $0.toolID == nil && $0.messageID == messages[2].id })
    }

    // The agent usually draws the trace it has just fetched. The fetched one is what Tempo
    // said, whole, so it is the one kept.
    @Test func aTraceFetchedWholeStandsInForTheAgentsDrawingOfIt() throws {
        let messages = [reply("Fetched.", tools: [try fetchedTrace()]),
                        reply(Self.drawnTrace())]
        let items = TroubleshootEvidence.items(in: messages)

        #expect(items.count == 1)
        guard case .fetchedTrace(_, let trace)? = items.first?.kind else {
            Issue.record("expected the fetched trace"); return
        }
        #expect(trace.traceID == Self.traceID)
    }

    @Test func aBlockStillArrivingOrBrokenIsNotEvidence() {
        let open = reply("Looking:\n\n```trace\n{\"spans\":[")
        let broken = reply("```logs\nnot json\n```")
        #expect(TroubleshootEvidence.items(in: [open, broken]).isEmpty)
        #expect(TroubleshootEvidence.count(in: [open, broken]) == 0)
    }

    // A reply is read again once it changes, so a block that finishes streaming shows up.
    @Test func aReplyThatGrowsIsReadAgain() {
        var message = reply("Looking:\n\n```trace\n{\"spans\":[")
        #expect(TroubleshootEvidence.count(in: [message]) == 0)
        message.text = "Looking:\n\n" + Self.drawnTrace()
        #expect(TroubleshootEvidence.count(in: [message]) == 1)
    }

    @Test func aCallThatFailedOrWasCutIsLeftInTheConversation() throws {
        var failed = try lokiQuery()
        failed.isError = true
        var cut = try fetchedTrace(id: "fetch-2")
        cut.result = String(TraceParserTests.v2.prefix(200)) + StreamEvent.truncationMarker
        #expect(TroubleshootEvidence.items(in: [reply("", tools: [failed, cut])]).isEmpty)
    }
}

struct GrafanaFollowUpTests {
    private static let loki = GrafanaResultView.Source(logs: TranscriptLogsSpec(
        title: nil, server: "grafana-platform-dev", query: #"{namespace="ledger"}"#, entries: []))

    @Test func widensTheSameQueryOnTheSameGrafana() {
        #expect(GrafanaResultView.widen(Self.loki, to: "6h")
                == #"Run the Loki query `{namespace="ledger"}` on grafana-platform-dev again over the last 6h, and show what it found."#)
    }

    @Test func asksForTheLinesAroundOneEntryAsALogsBlock() {
        let entry = GrafanaToolResult.LogEntry(id: 0, rawTimestamp: "", date: nil, line: "boom",
                                               labels: ["namespace": "ledger"], fields: [:],
                                               metadata: [:], level: nil, message: "boom")
        let text = GrafanaResultView.around(Self.loki, entry: entry,
                                            at: Date(timeIntervalSince1970: 1_792_764_131.418))
        #expect(text.contains(#"from the stream {namespace="ledger"} on grafana-platform-dev"#))
        #expect(text.contains("2026-10-23T14:02:11.418Z"))
        #expect(text.contains("```logs block"))
    }

    @Test func asksForASpansLogsOnTheGrafanaThatHoldsThem() {
        let span = Trace.Span(id: "b2", parentID: "a1", service: "ledger", operation: "INSERT entry",
                              kind: "client", startNanos: 0, durationNanos: 2_000_000_000,
                              isError: true, statusMessage: nil, attributes: [],
                              resourceAttributes: [], events: [])
        let text = TraceFollowUp.spanLogs(span, traceID: TraceToolCallTests.id)
        #expect(text.contains("ledger's logs for trace `\(TraceToolCallTests.id)`"))
        #expect(text.contains("which failed"))
        #expect(text.contains("```logs block"))
    }

    @Test func findsATraceIdUnderAnyNameTracersUse() {
        func entry(_ fields: [String: String], metadata: [String: String] = [:]) -> GrafanaToolResult.LogEntry {
            .init(id: 0, rawTimestamp: "", date: nil, line: "", labels: [:], fields: fields,
                  metadata: metadata, level: nil, message: "")
        }
        #expect(GrafanaResultView.traceID(in: entry(["traceId": TraceToolCallTests.id])) == TraceToolCallTests.id)
        #expect(GrafanaResultView.traceID(in: entry([:], metadata: ["trace_id": TraceToolCallTests.id])) == TraceToolCallTests.id)
        #expect(GrafanaResultView.traceID(in: entry(["trace_id": "none"])) == nil)
    }
}
