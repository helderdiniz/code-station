import SwiftUI

// Everything a diagnosis has turned up, on one board: its traces first, since they say
// where to look, then the log lines, query results and charts in the order the agent
// found them. Each card goes back to the reply it came from, where the reasoning is.
struct TroubleshootEvidenceView: View {
    @Environment(SessionRunner.self) private var runner

    let session: ChatSession
    let showInConversation: (UUID, String?) -> Void

    private var items: [TroubleshootEvidence.Item] { TroubleshootEvidence.items(in: session.messages) }

    var body: some View {
        let items = items
        let traces = items.filter(\.kind.isTrace)
        let rest = items.filter { !$0.kind.isTrace }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                heading(count: items.count)
                if runner.state(session.id).isBusy { workingNote }
                if items.isEmpty {
                    emptyCard
                } else {
                    if !traces.isEmpty {
                        section(traces.count == 1 ? "TRACE" : "TRACES", traces)
                    }
                    if !rest.isEmpty {
                        section("LOGS, QUERIES AND CHARTS", rest)
                    }
                }
            }
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    private func heading(count: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Evidence").font(.serif(21))
            Text(count == 0
                 ? "What the agent finds lands here: the traces it fetches, the log lines it picks out, and its charts."
                 : "\(counted(count, "piece")) of evidence from the diagnosis, each one taken from the conversation.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var workingNote: some View {
        HStack(spacing: 8) {
            LoopSpinner(size: 14)
            Text("The agent is still investigating. New evidence shows up here as it arrives.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
        }
    }

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nothing yet")
                .font(.system(size: 13, weight: .semibold))
            Text("Paste a trace into the brief, or ask the agent to fetch one, and it is drawn here as a waterfall. Log lines and charts the agent shows in its replies are gathered here too.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 11)
    }

    private func section(_ title: String, _ items: [TroubleshootEvidence.Item]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title)
            ForEach(items) { item in
                card(item)
            }
        }
    }

    private func card(_ item: TroubleshootEvidence.Item) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(Self.origin(item.kind))
                    .scaledMono(10.5, .bold)
                    .foregroundStyle(.secondary)
                Text(GrafanaResultView.clock(item.date))
                    .scaledMono(10.5)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                InlineAskButton(title: "Show in conversation") {
                    showInConversation(item.messageID, item.toolID)
                }
            }
            content(item.kind)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 11)
    }

    @ViewBuilder private func content(_ kind: TroubleshootEvidence.Kind) -> some View {
        switch kind {
        case .trace(let spec):
            TranscriptTraceCard(spec: spec, maxHeight: 560)
        case .fetchedTrace(let call, let trace):
            TranscriptTraceCard(spec: TranscriptTraceSpec(title: nil, server: call.server,
                                                          omittedSpans: 0, trace: trace),
                                maxHeight: 560)
        case .logs(let spec):
            GrafanaResultView(source: .init(logs: spec), result: spec.result)
        case .query(let rendering):
            GrafanaResultView(source: .init(call: rendering.call), result: rendering.result)
        case .chart(let spec):
            TranscriptChartView(spec: spec)
        }
    }

    static func origin(_ kind: TroubleshootEvidence.Kind) -> String {
        switch kind {
        case .trace: "DRAWN BY THE AGENT"
        case .fetchedTrace: "FETCHED FROM TEMPO"
        case .logs: "LOG LINES THE AGENT PICKED"
        case .query: "QUERIED BY THE AGENT"
        case .chart: "CHARTED BY THE AGENT"
        }
    }
}
