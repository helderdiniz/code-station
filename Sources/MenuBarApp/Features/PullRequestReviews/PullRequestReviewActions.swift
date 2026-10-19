import Foundation

// What one click on a review does. Each step here is the first time anything leaves the
// machine, which is why nothing in this file runs without a button behind it.
@MainActor
enum PullRequestReviewActions {
    enum Failure: Error, Equatable {
        case github(String)

        var message: String {
            switch self {
            case .github(let text): text
            }
        }
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
