import SwiftUI

// Prompts typed ahead, above the composer where what happens next belongs. A queue that
// is not moving on its own - the last turn failed, or was stopped - gets a button,
// since nothing else would ever start it. Chat and Design draw the same strip, so the
// two screens cannot drift apart.
struct SessionQueueStrip: View {
    let sessionID: UUID
    let busy: Bool
    let blocked: Bool
    // A short panel caps the list and scrolls inside it, so the queue cannot push the
    // composer off the bottom.
    var maxListHeight: CGFloat?
    let onRecall: () -> Void

    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    @State private var shownCount = 0
    @State private var listHeight: CGFloat = 0

    var body: some View {
        let waiting = runner.queued(sessionID)
        if !waiting.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                heading(count: waiting.count)
                if let maxListHeight {
                    ScrollView {
                        rows(waiting)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(height: min(listHeight, maxListHeight))
                } else {
                    rows(waiting)
                }
            }
            // Leaving is faster than arriving, so the curve follows which way the count went.
            .motion(waiting.count < shownCount ? Motion.leave : Motion.reveal,
                    value: waiting.map(\.id))
            .onChange(of: waiting.count, initial: true) { shownCount = $1 }
            .transition(.fold)
        }
    }

    private func heading(count: Int) -> some View {
        HStack(spacing: 6) {
            // The count sits in the heading because the list can be scrolled past or
            // capped, and how much is waiting is the part worth knowing.
            HStack(spacing: 0) {
                Text("QUEUED · ")
                Text("\(count)")
                    .contentTransition(.numericText(value: Double(count)))
                if busy {
                    Text(" · RUNS WHEN THIS TURN ENDS")
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .kerning(1.2)
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            if !busy && !blocked {
                InlineLink(title: "Send now", size: 12) {
                    runner.runQueue(sessionID, store: store)
                }
                .transition(.fadeIn)
            }
        }
        .foregroundStyle(Theme.accent)
        .motion(Motion.control, value: busy)
    }

    private func rows(_ waiting: [SessionRunner.QueuedPrompt]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(waiting) { item in
                HStack(alignment: .top, spacing: 8) {
                    Text(item.text)
                        .font(.system(size: 13))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    glyphButton("pencil", tooltip: "Take it back into the composer to rework",
                                label: "Edit queued prompt") {
                        runner.recall(item.id, sessionID: sessionID)
                        onRecall()
                    }
                    glyphButton("xmark", tooltip: "Remove from the queue",
                                label: "Remove queued prompt") {
                        runner.unqueue(item.id, sessionID: sessionID)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fieldSurface(cornerRadius: 8)
                .transition(.asymmetric(insertion: .fadeIn, removal: .fold))
            }
        }
    }

    private func glyphButton(_ symbol: String, tooltip: String, label: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverLift(amount: Motion.smallLift)
        .appTooltip(tooltip)
        .accessibilityLabel(label)
    }
}
