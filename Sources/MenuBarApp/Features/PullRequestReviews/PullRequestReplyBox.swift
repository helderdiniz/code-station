import SwiftUI

// Under every open thread: the way to answer or resolve it by hand.
struct PullRequestReplyBox: View {
    @Environment(PullRequestReviewStore.self) private var reviews
    let review: PullRequestReview
    let thread: PullRequestReviewThread
    let entry: PullRequestReviewStore.Loaded
    let sessionID: UUID
    let openChanges: () -> Void
    let failed: (String) -> Void

    @State private var reply = ""
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "pencil.line").font(.system(size: 10.5))
                Text("Your reply").font(.system(size: 11.5, weight: .semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            AppTextEditor(text: $reply, placeholder: "Reply to the reviewer…", minHeight: 56)
            buttons
        }
        .padding(12)
        .surface(Theme.field, cornerRadius: 10, border: Theme.hairline)
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            ActionButton(title: "Send reply", tone: .dark, height: 28, size: 12) {
                run(resolves: false) { await PullRequestReviewActions.reply(reply, thread: thread, on: entry) }
            }
            .disabled(reply.trimmed.isEmpty)
            if working { ProgressView().controlSize(.small) }
            Spacer(minLength: 0)
            InlineLink(title: "Resolve", size: 11.5, tint: .secondary) {
                run(resolves: true) { await PullRequestReviewActions.setResolved(true, thread, on: entry) }
            }
        }
        .disabled(working || reviews.busy.contains(entry.pullRequest.url))
    }

    // After a click the screen says what GitHub now holds: the reply as the last word,
    // or the thread resolved. The next read says the same.
    private func run(resolves: Bool, _ work: @escaping () async -> PullRequestReviewActions.Failure?) {
        let url = entry.pullRequest.url
        guard reviews.beginWork(on: url) else { return }
        working = true
        let sent = reply
        Task {
            let failure = await work()
            working = false
            reviews.endWork(on: url)
            if let failure {
                failed(failure.message)
                return
            }
            if resolves {
                reviews.setResolved(true, threadID: thread.id, in: sessionID)
            } else {
                reviews.noteReply(sent, threadID: thread.id, in: sessionID)
            }
        }
    }
}
