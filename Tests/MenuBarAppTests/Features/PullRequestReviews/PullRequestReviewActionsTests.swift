import Foundation
import Testing
@testable import MenuBarApp

@MainActor
@Suite(.serialized)
struct PullRequestReviewActionsTests {
    private var entry: PullRequestReviewStore.Loaded {
        PullRequestReviewStore.Loaded(pullRequest: PullRequest(number: 1, url: "https://github.com/team/app/pull/1"),
                                      status: PullRequestStatus(state: .open, title: "", headBranch: "main", headRepositoryURL: "https://github.com/team/app"), reviews: [])
    }

    @Test(arguments: ["https://github.com/team/app.git", "git@github.com:team/app.git", "ssh://git@github.com/team/app.git",
                      "https://github.com/TEAM/APP/"])
    func matchesHTTPSAndSSHRemotes(remote: String) {
        #expect(GitActions.remoteMatches(remote, repositoryURL: "https://github.com/team/app"))
    }

    @Test(arguments: ["https://github.com/team/app-settings.git", "git@github.com:other-team/app.git",
                      "https://enterprise.example/team/app.git", "https://github.com/other/team/app.git",
                      "/some/path/team/app.git"])
    func rejectsOtherRepositoriesAndHosts(remote: String) {
        #expect(!GitActions.remoteMatches(remote, repositoryURL: "https://github.com/team/app"))
    }

    @Test func selectsTheExactRepositoryInAWorkspace() async throws {
        let settings = try GitRepo()
        let app = try GitRepo()
        try settings.git("remote", "add", "origin", "https://github.com/team/app-settings.git")
        try app.git("remote", "add", "origin", "git@github.com:team/app.git")
        let (store, scratch) = TestStore.make()
        defer { withExtendedLifetime(scratch) {} }
        let first = try #require(store.addProject(at: settings.url))
        let second = try #require(store.addProject(at: app.url))
        let workspace = try #require(store.addWorkspace(name: "Review", projectIDs: [first.id, second.id], leadProjectID: first.id))
        let session = try #require(store.newSession(in: workspace.id, projects: [SessionProject(projectID: first.id), SessionProject(projectID: second.id)]))

        #expect(await PullRequestReviewActions.root(for: entry, sessionID: session.id, store: store) == app.path)
        try app.git("remote", "set-url", "origin", "https://github.com/team/unrelated.git")
        #expect(await PullRequestReviewActions.root(for: entry, sessionID: session.id, store: store) == nil)
        try app.git("remote", "set-url", "origin", "https://github.com/team/app.git")
        try settings.git("remote", "set-url", "origin", "https://github.com/team/app.git")
        #expect(await PullRequestReviewActions.root(for: entry, sessionID: session.id, store: store) == nil)
    }

    @Test func aSingleCheckoutMustMatchTheHeadRepositoryIncludingForks() async throws {
        let repo = try GitRepo()
        try repo.git("remote", "add", "origin", "https://github.com/team/app-settings.git")
        let (store, scratch) = TestStore.make()
        defer { withExtendedLifetime(scratch) {} }
        let project = try #require(store.addProject(at: repo.url))
        let session = store.newSession(in: project.id)

        #expect(await PullRequestReviewActions.root(for: entry, sessionID: session.id, store: store) == nil)
        var fork = entry
        fork.status.headRepositoryURL = "https://github.com/contributor/app"
        try repo.git("remote", "set-url", "origin", "https://github.com/team/app.git")
        #expect(await PullRequestReviewActions.root(for: fork, sessionID: session.id, store: store) == nil)
        try repo.git("remote", "set-url", "origin", "git@github.com:contributor/app.git")
        #expect(await PullRequestReviewActions.root(for: fork, sessionID: session.id, store: store) == repo.path)
    }

    @Test func aProposalWithoutABaselineCannotDiscardFiles() async throws {
        let repo = try GitRepo()
        try repo.git("remote", "add", "origin", "https://github.com/team/app.git")
        try repo.write("README.md", "user edit")
        let (store, scratch) = TestStore.make()
        defer { withExtendedLifetime(scratch) {} }
        let project = try #require(store.addProject(at: repo.url))
        let session = store.newSession(in: project.id)
        let proposal = PullRequestReviewProposal(threadID: 1, action: .fix, reply: "Fixed", files: ["README.md"])

        #expect(await PullRequestReviewActions.discard(proposal, on: entry, sessionID: session.id, store: store) != nil)
        #expect(repo.read("README.md") == "user edit")
    }

    @Test func refusesAnOriginThatPushesToAnotherRepository() async throws {
        let repo = try GitRepo()
        try repo.git("remote", "add", "origin", "https://github.com/team/app.git")
        try repo.git("remote", "set-url", "--push", "origin", "git@github.com:other/app.git")

        #expect(await GitActions.originMatches(repositoryURL: "https://github.com/team/app", at: repo.path) == false)
    }

    @Test func refusesMultiplePushDestinations() async throws {
        let repo = try GitRepo()
        try repo.git("remote", "add", "origin", "https://github.com/team/app.git")
        try repo.git("remote", "set-url", "--add", "--push", "origin", "git@github.com:team/app.git")
        try repo.git("remote", "set-url", "--add", "--push", "origin", "git@github.com:other/app.git")

        #expect(await GitActions.originMatches(repositoryURL: "https://github.com/team/app", at: repo.path) == false)
    }
}
