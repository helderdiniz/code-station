import Foundation
import Observation

// The reviews on each session's pull request, read from GitHub. Nothing is saved: GitHub
// is the record, and the store only holds what it last said.
@MainActor
@Observable
final class PullRequestReviewStore {
    struct Loaded: Equatable {
        var pullRequest: PullRequest
        var status: PullRequestStatus
        var reviews: [PullRequestReview]

        var isOpen: Bool { status.state == .open }
    }

    private(set) var loaded: [UUID: [Loaded]] = [:]
    private(set) var errors: [UUID: String] = [:]
    private(set) var loading: Set<UUID> = []
    // The account gh is signed in as. Its replies count as answers.
    private(set) var selfLogin: String?
    // Pull requests with a reply or a resolve in flight, so a second click waits for the first.
    private(set) var busy: Set<String> = []


    // Opening a session: find the pull request each checkout's branch is on, remember it
    // on the session the way `gh pr create` would have, then read every pull request the
    // session carries.
    func load(_ sessionID: UUID, store: ProjectStore) async {
        guard let session = store.session(sessionID), !loading.contains(sessionID) else { return }
        loading.insert(sessionID)
        defer { loading.remove(sessionID) }
        if selfLogin == nil { selfLogin = await GitHubPullRequests.signedInLogin() }
        for root in store.workingDirectories(for: session) {
            if let found = await GitHubPullRequests.pullRequest(forBranchAt: root) {
                store.notePullRequest(found, for: sessionID)
            }
        }
        await read(sessionID, store: store)
    }

    // One reading that fails keeps the last good one, so a hiccup in gh does not empty the
    // tab and zero the count until the next beat.
    private func read(_ sessionID: UUID, store: ProjectStore) async {
        var result: [Loaded] = []
        for pullRequest in store.session(sessionID)?.pullRequests ?? [] {
            do {
                let fetched = try await GitHubPullRequests.fetch(pullRequest)
                result.append(Loaded(pullRequest: pullRequest, status: fetched.status, reviews: fetched.reviews))
                errors[sessionID] = nil
            } catch {
                errors[sessionID] = (error as? GitHubPullRequests.Failure)?.message ?? error.localizedDescription
                if let previous = loaded[sessionID]?.first(where: { $0.pullRequest.url == pullRequest.url }) {
                    result.append(previous)
                }
            }
        }
        loaded[sessionID] = result
    }

    // Threads on open pull requests still waiting for the person's answer.
    func waitingCount(_ sessionID: UUID) -> Int {
        Self.waiting(in: loaded[sessionID] ?? [], selfLogin: selfLogin).count
    }

    nonisolated static func waiting(in loaded: [Loaded], selfLogin: String?) -> [PullRequestReviewThread] {
        loaded.filter(\.isOpen).flatMap { $0.reviews.flatMap(\.threads) }.filter { !$0.isAnswered(by: selfLogin) }
    }

    // MARK: - What the person just did

    // GitHub has been told; the next read will say the same, so the screen says it now.
    func setResolved(_ resolved: Bool, threadID: Int, in sessionID: UUID) {
        update(threadID, in: sessionID) { $0.isResolved = resolved }
    }

    func noteReply(_ body: String, threadID: Int, in sessionID: UUID) {
        let author = Reviewer(login: selfLogin ?? "", avatarURL: nil)
        update(threadID, in: sessionID) {
            $0.comments.append(PullRequestReviewComment(id: -$0.comments.count, author: author, body: body,
                                                        createdAt: Date(), url: ""))
        }
    }

    private func update(_ threadID: Int, in sessionID: UUID, _ change: (inout PullRequestReviewThread) -> Void) {
        guard var entries = loaded[sessionID] else { return }
        for e in entries.indices {
            for r in entries[e].reviews.indices {
                for t in entries[e].reviews[r].threads.indices where entries[e].reviews[r].threads[t].id == threadID {
                    change(&entries[e].reviews[r].threads[t])
                }
            }
        }
        loaded[sessionID] = entries
    }

    func beginWork(on url: String) -> Bool { busy.insert(url).inserted }
    func endWork(on url: String) { busy.remove(url) }
}

// Whose reviews are on screen. Automation and people are read in different moods, so
// each can be looked at on its own.
enum PullRequestReviewerFilter: CaseIterable {
    case everyone, people, automation

    var title: String {
        switch self {
        case .everyone: "All"
        case .people: "People"
        case .automation: "AI"
        }
    }

    func includes(_ review: PullRequestReview) -> Bool {
        switch self {
        case .everyone: true
        case .people: !review.author.isAutomated
        case .automation: review.author.isAutomated
        }
    }
}

// Everything one reviewer has said on a pull request, newest first.
struct PullRequestReviewerGroup: Equatable, Identifiable {
    let author: Reviewer
    let reviews: [PullRequestReview]

    var id: String { author.login }
    var latest: PullRequestReview { reviews[0] }
    var threads: [PullRequestReviewThread] { reviews.flatMap(\.threads) }

    // One group per reviewer, the most recently active first.
    static func grouping(_ reviews: [PullRequestReview],
                         showing filter: PullRequestReviewerFilter) -> [PullRequestReviewerGroup] {
        var byLogin: [String: [PullRequestReview]] = [:]
        for review in reviews where filter.includes(review) {
            byLogin[review.author.login, default: []].append(review)
        }
        return byLogin.values
            .map { PullRequestReviewerGroup(author: $0[0].author, reviews: $0.sorted { $0.submittedAt > $1.submittedAt }) }
            .sorted { $0.latest.submittedAt > $1.latest.submittedAt }
    }
}
