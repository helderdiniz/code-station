import Foundation

// What a diagnosis has found so far, read off its transcript: the traces and log lines the
// agent drew, the Grafana results it fetched, and its charts. Nothing here is fetched; the
// transcript is the only source, so the Evidence tab always agrees with the conversation.
enum TroubleshootEvidence {
    enum Kind {
        // A trace the agent wrote out in a reply.
        case trace(TranscriptTraceSpec)
        // A trace read whole from the agent's own Tempo call.
        case fetchedTrace(TraceToolCall, Trace)
        case logs(TranscriptLogsSpec)
        case query(GrafanaRendering)
        case chart(TranscriptChartSpec)

        var isTrace: Bool {
            switch self {
            case .trace, .fetchedTrace: true
            case .logs, .query, .chart: false
            }
        }

        var traceID: String? {
            switch self {
            case .trace(let spec): spec.trace.traceID
            case .fetchedTrace(_, let trace): trace.traceID
            case .logs, .query, .chart: nil
            }
        }
    }

    struct Item: Identifiable {
        let id: String
        let messageID: UUID
        // The call it came from, for evidence that is a call's result rather than a block
        // in a reply.
        let toolID: String?
        let date: Date
        let kind: Kind
    }

    @MainActor
    static func items(in messages: [ChatMessage]) -> [Item] {
        let all = messages.filter { $0.role == .assistant }.flatMap(MessageEvidence.items)
        // The agent usually draws a trace it has just fetched. The fetched one is whole and
        // exactly what Tempo said, so a drawing of the same trace is left out beside it.
        let fetched = Set(all.compactMap { item -> String? in
            if case .fetchedTrace(_, let trace) = item.kind { trace.traceID } else { nil }
        })
        return all.filter { item in
            guard case .trace(let spec) = item.kind else { return true }
            return spec.trace.traceID.isEmpty || !fetched.contains(spec.trace.traceID)
        }
    }

    @MainActor
    static func count(in messages: [ChatMessage]) -> Int { items(in: messages).count }
}

// One reply's evidence, kept while the reply stays as it is. The tab and its header both
// ask on every redraw, and a streaming reply redraws many times a second.
@MainActor
private enum MessageEvidence {
    private struct Entry {
        let signature: Signature
        let items: [TroubleshootEvidence.Item]
    }

    private struct Signature: Equatable {
        let textLength: Int
        let toolCount: Int
        let resultLength: Int
    }

    private static var entries: [UUID: Entry] = [:]
    private static let limit = 2_000

    static func items(_ message: ChatMessage) -> [TroubleshootEvidence.Item] {
        let signature = Signature(
            textLength: message.text.utf8.count,
            toolCount: message.tools.count,
            resultLength: message.tools.reduce(0) { $0 + ($1.result?.utf8.count ?? 0) })
        if let entry = entries[message.id], entry.signature == signature { return entry.items }
        let items = read(message)
        if entries.count >= limit { entries.removeAll(keepingCapacity: true) }
        entries[message.id] = Entry(signature: signature, items: items)
        return items
    }

    private static func read(_ message: ChatMessage) -> [TroubleshootEvidence.Item] {
        var items: [TroubleshootEvidence.Item] = []
        for tool in message.tools {
            let kind: TroubleshootEvidence.Kind? = switch ToolRenderingCache.rendering(of: tool) {
            case .grafana(let rendering): .query(rendering)
            case .trace(.trace(let call, let trace)): .fetchedTrace(call, trace)
            case .trace(.truncated), .none: nil
            }
            if let kind {
                items.append(.init(id: "\(message.id)-tool-\(tool.id)", messageID: message.id,
                                   toolID: tool.id, date: tool.finishedAt ?? message.date,
                                   kind: kind))
            }
        }
        for segment in MessageSegment.split(message.text) where segment.isDrawn && !segment.isOpen {
            let kind: TroubleshootEvidence.Kind?
            if segment.isTrace, case .success(let spec) = TranscriptTraceSpec.parse(segment.text) {
                kind = .trace(spec)
            } else if segment.isLogs, case .success(let spec) = TranscriptLogsSpec.parse(segment.text) {
                kind = .logs(spec)
            } else if segment.isChart, case .success(let spec) = TranscriptChartSpec.parse(segment.text) {
                kind = .chart(spec)
            } else {
                kind = nil
            }
            if let kind {
                items.append(.init(id: "\(message.id)-block-\(segment.id)", messageID: message.id,
                                   toolID: nil, date: message.date, kind: kind))
            }
        }
        return items
    }
}
