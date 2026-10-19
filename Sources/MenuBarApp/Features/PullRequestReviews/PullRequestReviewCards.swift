import SwiftUI

// Everything one reviewer has said, behind one line: who, how many threads, how many
// still open. Folded unless something of theirs is still waiting for an answer.
struct PullRequestReviewerGroupView: View {
    @Environment(PullRequestReviewStore.self) private var reviews
    let group: PullRequestReviewerGroup
    let entry: PullRequestReviewStore.Loaded
    let sessionID: UUID
    let openChanges: () -> Void
    let failed: (String) -> Void

    @State private var unfolded: Bool?

    private var open: Int { group.threads.filter { !$0.isAnswered(by: reviews.selfLogin) }.count }
    private var isUnfolded: Binding<Bool> {
        Binding(get: { unfolded ?? (open > 0) }, set: { unfolded = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DisclosureHeader(isExpanded: isUnfolded) { headerLabel }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .surface(Theme.sunken, cornerRadius: 10, border: Theme.hairline)
            if isUnfolded.wrappedValue {
                ForEach(group.reviews) { review in
                    PullRequestReviewCard(review: review, entry: entry, sessionID: sessionID,
                                          openChanges: openChanges, failed: failed)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headerLabel: some View {
        HStack(spacing: 9) {
            PullRequestReviewerAvatar(reviewer: group.author, side: 24)
            Text(group.author.login).font(.system(size: 13, weight: .semibold))
            if group.author.isAutomated { MonoChip(text: "AI", size: 9.5, tint: Theme.botStage) }
            MonoChip(text: group.latest.kind.title, size: 9.5, tint: group.latest.kind.ink)
            Spacer(minLength: 6)
            Text(summary).font(.mono(10.5)).lineLimit(1).layoutPriority(1)
                .foregroundStyle(open == 0 ? Color.secondary : Theme.attentionText)
            if open == 0, !group.threads.isEmpty { PullRequestAnsweredTick() }
        }
    }

    // "3 reviews · 5 threads · 2 open", dropping whatever is zero or one of one.
    private var summary: String {
        var parts: [String] = []
        if group.reviews.count > 1 { parts.append(counted(group.reviews.count, "review")) }
        if !group.threads.isEmpty {
            parts.append(counted(group.threads.count, "thread"))
            parts.append(open == 0 ? "all answered" : "\(open) open")
        }
        if parts.isEmpty { parts.append(RelativeTime.short(group.latest.submittedAt)) }
        return parts.joined(separator: " · ")
    }
}

// One review inside its reviewer's group: the verdict, the summary if there is one, and
// its threads, each folded to a line until opened. A summary has no thread under it, so
// there is nothing to answer there; the threads are where answers go.
struct PullRequestReviewCard: View {
    let review: PullRequestReview
    let entry: PullRequestReviewStore.Loaded
    let sessionID: UUID
    let openChanges: () -> Void
    let failed: (String) -> Void

    @State private var isUnfolded = true
    @State private var unfoldedThreads: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DisclosureHeader(isExpanded: $isUnfolded) {
                HStack(spacing: 9) {
                    MonoChip(text: review.kind.title, size: 9.5, tint: review.kind.ink)
                    Text(RelativeTime.short(review.submittedAt)).font(.mono(10.5)).foregroundStyle(.secondary)
                    if !isUnfolded, !review.threads.isEmpty {
                        Text(counted(review.threads.count, "thread")).font(.mono(10.5)).foregroundStyle(.secondary)
                    }
                }
            }
            if isUnfolded {
                if !review.body.isEmpty { GitHubProse(review.body) }
                ForEach(review.threads) { thread in
                    PullRequestThreadView(thread: thread, review: review, entry: entry, sessionID: sessionID,
                                          unfolded: unfoldedThreads.contains(thread.id),
                                          toggle: { toggle(thread.id) }, openChanges: openChanges, failed: failed)
                }
            }
        }
        // The prose inside measures itself against the width it is offered. Without a
        // definite one it falls back to its own idea of a line, and draws wrong.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 24)
        .padding(.trailing, 4)
    }

    private func toggle(_ id: Int) {
        if !unfoldedThreads.insert(id).inserted { unfoldedThreads.remove(id) }
    }
}
