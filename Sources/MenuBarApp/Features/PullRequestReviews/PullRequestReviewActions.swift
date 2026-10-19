import Foundation

// What one click on a review does. Each step here is the first time anything leaves the
// machine, which is why nothing in this file runs without a button behind it.
@MainActor
enum PullRequestReviewActions {
    enum Failure: Error, Equatable {
        case noCheckout
        case wrongBranch(checkout: String, pullRequest: String)
        case git(String)
        case github(String)

        var message: String {
            switch self {
            case .noCheckout: "The checkout this pull request belongs to is gone."
            case .wrongBranch(let checkout, let pullRequest):
                "The checkout is on \(checkout) but the pull request is on \(pullRequest). Switch the checkout to that branch in the Changes tab first."
            case .git(let text): text
            case .github(let text): text
            }
        }
    }

    // The checkout whose origin is the pull request's repository. A workspace session has
    // one per project, and only one of them is where this pull request's branch lives.
    static func root(for loaded: PullRequestReviewStore.Loaded, sessionID: UUID, store: ProjectStore) async -> String? {
        guard let session = store.session(sessionID) else { return nil }
        let roots = store.workingDirectories(for: session)
        guard roots.count > 1 else { return roots.first }
        // With several checkouts and no way to ask git which is which, guessing would
        // commit into the wrong repository.
        guard let owner = loaded.pullRequest.owner, let name = loaded.pullRequest.repository else { return nil }
        for root in roots where await GitActions.originContains("\(owner)/\(name)", at: root) { return root }
        return roots.first
    }

    // A session pointed at somebody's pull request may be sitting on a branch of its own.
    // A commit there would never reach the pull request, so the branch is checked first.
    static func onPullRequestBranch(_ loaded: PullRequestReviewStore.Loaded, root: String) -> Failure? {
        let wanted = loaded.status.headBranch
        guard !wanted.isEmpty else { return nil }
        let current = GitHead.branch(at: root) ?? "no branch"
        return current == wanted ? nil : .wrongBranch(checkout: current, pullRequest: wanted)
    }

    // Commits the files the agent named, pushes the branch, and only then answers the
    // reviewer. A push that fails leaves the reply unsent, so GitHub never shows an answer
    // that points at a change it cannot see. `reply` is the text as the person left it.
    static func approve(_ proposal: PullRequestReviewProposal, reply: String, thread: PullRequestReviewThread,
                        on loaded: PullRequestReviewStore.Loaded, sessionID: UUID, store: ProjectStore) async -> Failure? {
        if proposal.action == .fix, !proposal.files.isEmpty {
            guard let root = await root(for: loaded, sessionID: sessionID, store: store) else { return .noCheckout }
            if let failure = onPullRequestBranch(loaded, root: root) { return failure }
            let message = "address review comment on \((thread.path as NSString).lastPathComponent)"
            if let failure = await GitActions.commitPaths(proposal.files, message: message, at: root) { return .git(failure) }
            if let failure = await GitActions.push(hasUpstream: false, at: root) { return .git(failure) }
        }
        return await self.reply(reply, thread: thread, on: loaded)
    }

    static func reply(_ body: String, thread: PullRequestReviewThread, on loaded: PullRequestReviewStore.Loaded) async -> Failure? {
        let text = body.trimmed
        guard !text.isEmpty else { return nil }
        return await github { try await GitHubPullRequests.reply(text, to: thread, on: loaded.pullRequest) }
    }

    static func setResolved(_ resolved: Bool, _ thread: PullRequestReviewThread,
                            on loaded: PullRequestReviewStore.Loaded) async -> Failure? {
        await github { try await GitHubPullRequests.setResolved(resolved, thread, on: loaded.pullRequest) }
    }

    // Puts the files the agent touched back the way the branch had them.
    static func discard(_ proposal: PullRequestReviewProposal, on loaded: PullRequestReviewStore.Loaded,
                        sessionID: UUID, store: ProjectStore) async -> Failure? {
        guard proposal.action == .fix, !proposal.files.isEmpty else { return nil }
        guard let root = await root(for: loaded, sessionID: sessionID, store: store) else { return .noCheckout }
        return await GitActions.restorePaths(proposal.files, at: root).map { .git($0) }
    }

    private static func github(_ work: () async throws -> Void) async -> Failure? {
        do {
            try await work()
            return nil
        } catch let failure as GitHubPullRequests.Failure {
            return .github(failure.message)
        } catch {
            return .github(error.localizedDescription)
        }
    }
}
