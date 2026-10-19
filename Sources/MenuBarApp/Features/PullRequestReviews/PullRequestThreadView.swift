import AppKit
import SwiftUI

// Folded, a thread is one line: who said it, their first words, and where. Open, it is
// the code, the whole conversation and the reply box.
struct PullRequestThreadView: View {
    @Environment(PullRequestReviewStore.self) private var reviews
    let thread: PullRequestReviewThread
    let review: PullRequestReview
    let entry: PullRequestReviewStore.Loaded
    let sessionID: UUID
    let unfolded: Bool
    let toggle: () -> Void
    let openChanges: () -> Void
    let failed: (String) -> Void

    @State private var hunk: NSAttributedString?
    @State private var reopening = false

    private var answered: Bool { thread.isAnswered(by: reviews.selfLogin) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                DisclosureHeader(isExpanded: Binding(get: { unfolded }, set: { _ in toggle() })) { summaryLabel }
                    .frame(maxWidth: .infinity, alignment: .leading)
                GlyphButton(icon: "arrow.up.right", side: 22) {
                    if let link = thread.first?.url, let url = URL(string: link) { NSWorkspace.shared.open(url) }
                }
                .appTooltip("Open this thread on GitHub")
            }
            if unfolded {
                if let hunk {
                    DiffTextView(text: hunk, fitsContent: true)
                        .frame(maxHeight: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
                }
                ForEach(thread.comments) { comment in
                    CommentRow(comment: comment)
                }
                if entry.isOpen { footer }
            }
        }
        .padding(12)
        .surface(Theme.card, cornerRadius: 10, border: Theme.hairline)
        .task(id: unfolded) {
            guard unfolded, hunk == nil else { return }
            hunk = await PullRequestReviewHunk.render(thread.diffHunk, path: thread.path)
        }
    }

    // Everything on the line is one line tall and gives way in a fixed order when the
    // card is narrow: the preview of the words shrinks first, then the file name.
    private var summaryLabel: some View {
        HStack(alignment: .center, spacing: 8) {
            if let author = thread.first?.author {
                PullRequestReviewerAvatar(reviewer: author, side: 18)
                Text(author.login).font(.system(size: 12, weight: .semibold)).lineLimit(1).layoutPriority(2)
            }
            if !unfolded {
                Text(thread.body.split(whereSeparator: \.isNewline).first.map(String.init) ?? "")
                    .font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 6)
            if thread.comments.count > 1 {
                Text(counted(thread.comments.count - 1, "reply", plural: "replies"))
                    .font(.mono(10)).foregroundStyle(.secondary).lineLimit(1).layoutPriority(2)
            }
            if answered { PullRequestAnsweredTick() }
            Text(thread.place).font(.mono(10.5)).foregroundStyle(.secondary).lineLimit(1)
                .truncationMode(.middle).layoutPriority(1)
        }
    }

    // A resolved thread can be opened again on GitHub; an open one gets the reply box.
    @ViewBuilder private var footer: some View {
        if thread.isResolved {
            HStack(spacing: 10) {
                PullRequestAnsweredTick()
                Text("resolved").font(.system(size: 11.5)).foregroundStyle(.secondary)
                InlineLink(title: reopening ? "Reopening…" : "Reopen", size: 11.5, action: reopen).disabled(reopening)
            }
        } else {
            PullRequestReplyBox(review: review, thread: thread, entry: entry, sessionID: sessionID,
                                openChanges: openChanges, failed: failed)
        }
    }

    private func reopen() {
        reopening = true
        Task {
            if let failure = await PullRequestReviewActions.setResolved(false, thread, on: entry) {
                failed(failure.message)
            } else {
                reviews.setResolved(false, threadID: thread.id, in: sessionID)
            }
            reopening = false
        }
    }
}

private struct CommentRow: View {
    let comment: PullRequestReviewComment

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            PullRequestReviewerAvatar(reviewer: comment.author, side: 18)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(comment.author.login).font(.system(size: 12, weight: .semibold))
                    if comment.author.isAutomated { MonoChip(text: "AI", size: 9.5, tint: Theme.botStage) }
                    Text(RelativeTime.short(comment.createdAt)).font(.mono(10)).foregroundStyle(.secondary)
                }
                GitHubProse(comment.body)
            }
        }
        .padding(.leading, 18)
    }
}
