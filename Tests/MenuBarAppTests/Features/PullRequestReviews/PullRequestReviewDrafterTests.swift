import Foundation
import Testing
@testable import MenuBarApp

@MainActor
@Suite(.serialized)
struct PullRequestReviewDrafterTests {
    private var thread: PullRequestReviewThread {
        PullRequestReviewThread(id: 1, path: "README.md", line: 1, diffHunk: "", comments: [])
    }

    private var review: PullRequestReview {
        PullRequestReview(id: 1, kind: .commented, author: Reviewer(login: "reviewer", avatarURL: nil),
                          body: "", submittedAt: Date(), threads: [thread])
    }

    private var entry: PullRequestReviewStore.Loaded {
        PullRequestReviewStore.Loaded(pullRequest: PullRequest(number: 1, url: "https://github.com/team/app/pull/1"),
                                      status: PullRequestStatus(state: .open, title: "", headBranch: "main", headRepositoryURL: "https://github.com/team/app"), reviews: [review])
    }

    @Test func draftWaitsForTheRequestedSessionEvenWhenDesignSpokeLast() async throws {
        let harness = try RunnerHarness(agent: .codex, script: "exit 1")
        defer { harness.tearDown() }
        try harness.makeProjectARepository()
        try GitRepo.run(["remote", "add", "origin", "https://github.com/team/app.git"], in: harness.projectURL)
        let design = try harness.store.startDesign(for: harness.session.id).get()
        harness.store.append(ChatMessage(role: .user, text: "Draw a page"), to: design.id)
        let reviews = PullRequestReviewStore()
        harness.runner.onTurnEnded = { reviews.turnEnded($0) }
        #expect(LiveConversation.id(of: harness.session.id, store: harness.store, runner: harness.runner) == design.id)
        var outcome: PullRequestReviewDrafter.Outcome?

        let task = Task {
            outcome = await PullRequestReviewDrafter.draft(review: review, thread: thread, on: entry,
                sessionID: harness.session.id, store: harness.store, runner: harness.runner, reviews: reviews)
        }
        defer { task.cancel() }
        #expect(await waitUntil { outcome != nil })
        task.cancel()
        await task.value
        #expect(outcome == .noAnswer)
        #expect(reviews.drafting.isEmpty)
        #expect(reviews.busy.isEmpty)
    }

    @Test func launchFailureEndsDraftingWithoutATurnEndedEvent() async throws {
        let harness = try RunnerHarness(agent: .codex, script: "exit 1")
        defer { harness.tearDown() }
        try harness.makeProjectARepository()
        try GitRepo.run(["remote", "add", "origin", "https://github.com/team/app.git"], in: harness.projectURL)
        try FileManager.default.removeItem(at: harness.executable)
        let reviews = PullRequestReviewStore()
        var outcome: PullRequestReviewDrafter.Outcome?

        let task = Task {
            outcome = await PullRequestReviewDrafter.draft(review: review, thread: thread, on: entry,
                sessionID: harness.session.id, store: harness.store, runner: harness.runner, reviews: reviews)
        }
        defer { task.cancel() }
        #expect(await waitUntil { outcome != nil })
        task.cancel()
        await task.value
        #expect(outcome == .noAnswer)
        #expect(reviews.drafting.isEmpty)
        #expect(reviews.busy.isEmpty)
    }

    @Test func cancellingAWaitRemovesItWithoutWaitingForTheAgent() async {
        let reviews = PullRequestReviewStore()
        let sessionID = UUID()
        var started = false
        let task = Task { await reviews.waitForTurnEnd(sessionID) { started = true; return true } }
        #expect(await waitUntil { started })
        task.cancel()
        #expect(await task.value == false)
        reviews.turnEnded(sessionID)
    }

    @Test func aTurnEndingDuringStartIsNotMissed() async {
        let reviews = PullRequestReviewStore()
        let sessionID = UUID()
        #expect(await reviews.waitForTurnEnd(sessionID) { reviews.turnEnded(sessionID); return true })
    }

    @Test func draftRecordsActualChangesEvenWhenTheAgentOmitsThem() async throws {
        let harness = try RunnerHarness(agent: .codex, script: """
        printf 'agent fix' > README.md
        printf '[{"threadID":99,"action":"reply","reply":"Fixed","files":[]}]' > .code-station/review-proposals/1.json
        exit 0
        """)
        defer { harness.tearDown() }
        try harness.makeProjectARepository()
        try GitRepo.run(["remote", "add", "origin", "https://github.com/team/app.git"], in: harness.projectURL)
        let reviews = PullRequestReviewStore()
        harness.runner.onTurnEnded = { reviews.turnEnded($0) }

        let outcome = await PullRequestReviewDrafter.draft(review: review, thread: thread, on: entry,
            sessionID: harness.session.id, store: harness.store, runner: harness.runner, reviews: reviews)

        #expect(outcome == .proposed)
        let proposal = try #require(reviews.proposals[1])
        #expect(proposal.action == .fix)
        #expect(proposal.files == ["README.md"])
        #expect(await proposal.changes?.discard() == nil)
        #expect(!FileManager.default.fileExists(atPath: harness.projectURL.appendingPathComponent("README.md").path))
    }
}
