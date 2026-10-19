import Foundation
import Testing
@testable import MenuBarApp

// The few rules the tab decides on its own: what counts as answered, how reviewers are
// grouped and filtered, and how GitHub's HTML becomes markdown.
struct PullRequestReviewRulesTests {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    private func reviewer(_ login: String, automated: Bool = false) -> Reviewer {
        Reviewer(login: login, avatarURL: nil, isAutomated: automated)
    }

    private func thread(_ id: Int, replies: [String] = [], resolved: Bool = false) -> PullRequestReviewThread {
        var comments = [PullRequestReviewComment(id: id, author: reviewer("maria"), body: "Fix this", createdAt: now, url: "")]
        comments += replies.enumerated().map {
            PullRequestReviewComment(id: id + $0.offset + 1, author: reviewer($0.element), body: "…", createdAt: now, url: "")
        }
        return PullRequestReviewThread(id: id, path: "A.swift", line: 1, diffHunk: "@@", comments: comments, isResolved: resolved)
    }

    private func review(_ id: Int, _ kind: PullRequestReview.Kind, by login: String, automated: Bool = false,
                        after seconds: TimeInterval = 0) -> PullRequestReview {
        PullRequestReview(id: id, kind: kind, author: reviewer(login, automated: automated), body: "Hm",
                          submittedAt: now.addingTimeInterval(seconds))
    }

    @Test func aThreadIsAnsweredWhenResolvedOrWhenTheLastWordIsThePersonsOwn() {
        // Arrange
        let resolved = thread(10, resolved: true)
        let replied = thread(20, replies: ["joao"])
        let followedUp = thread(30, replies: ["joao", "maria"])

        // Act
        let answers = [resolved.isAnswered(by: nil), replied.isAnswered(by: "joao"),
                       replied.isAnswered(by: nil), followedUp.isAnswered(by: "joao")]

        // Assert
        #expect(answers == [true, true, false, false])
    }

    // The number on the tab and the sidebar card: open pull requests only, and only the
    // threads nobody has answered for the person.
    @Test func countsThreadsWaitingOnOpenPullRequestsOnly() {
        // Arrange
        let open = PullRequestReviewStore.Loaded(
            pullRequest: PullRequest(number: 1, url: "https://github.com/e/a/pull/1"),
            status: PullRequestStatus(state: .open, title: "", headBranch: "b"),
            reviews: [PullRequestReview(id: 1, kind: .commented, author: reviewer("maria"), body: "", submittedAt: now,
                                        threads: [thread(10), thread(20, replies: ["joao"]), thread(30, resolved: true)])])
        var merged = open
        merged.status.state = .merged
        merged.pullRequest.url = "https://github.com/e/a/pull/2"

        // Act
        let waiting = PullRequestReviewStore.waiting(in: [open, merged], selfLogin: "joao")
        let unknownSelf = PullRequestReviewStore.waiting(in: [open], selfLogin: nil)

        // Assert
        #expect(waiting.map(\.id) == [10])
        #expect(unknownSelf.map(\.id) == [10, 20])
    }

    @Test func groupsByReviewerMostRecentlyActiveFirstNewestReviewFirst() {
        // Arrange
        let reviews = [review(1, .commented, by: "maria", after: 10),
                       review(2, .commented, by: "Copilot", automated: true, after: 20),
                       review(3, .approved, by: "maria", after: 30)]

        // Act
        let groups = PullRequestReviewerGroup.grouping(reviews, showing: .everyone)

        // Assert
        #expect(groups.map(\.author.login) == ["maria", "Copilot"])
        #expect(groups[0].reviews.map(\.id) == [3, 1])
    }

    @Test func peopleAndAutomationFiltersKeepOnlyTheirOwn() {
        // Arrange
        let reviews = [review(1, .commented, by: "maria"), review(2, .commented, by: "Copilot", automated: true)]

        // Act
        let people = PullRequestReviewerGroup.grouping(reviews, showing: .people).map(\.author.login)
        let bots = PullRequestReviewerGroup.grouping(reviews, showing: .automation).map(\.author.login)

        // Assert
        #expect(people == ["maria"])
        #expect(bots == ["Copilot"])
    }

    @Test func turnsGitHubsHTMLIntoMarkdownAndLeavesMarkdownAlone() {
        // Arrange
        let html = "<!-- marker -->\r\n<details>\r\n<summary><strong>What changed</strong></summary>\r\n\r\nAdds docs.\r\n</details>\r\n<a href=\"/x/y\" class=\"Link\">Add a skill</a> or <b>bold</b>"
        let table = "| File | Note |\n| --- | --- |\n| a.md | b |"
        let picture = "<picture><source srcset=\"x.svg\"></picture> <a href=\"/t\">Title</a> · New\n<sub>Review effort: Balanced</sub>"

        // Act
        let cleaned = GitHubMarkdown.clean(html)

        // Assert
        #expect(cleaned == "**What changed**\n\nAdds docs.\n\n[Add a skill](/x/y) or **bold**")
        #expect(GitHubMarkdown.clean(table) == table)
        #expect(GitHubMarkdown.clean(picture) == "[Title](/t) · New\nReview effort: Balanced")
    }

    @Test func classifiesEachHunkLineByItsFirstCharacter() {
        // Arrange
        let hunk = "@@ -40,3 +40,4 @@\n context\n-old\n+new"

        // Act
        let lines = PullRequestReviewHunk.lines(hunk)

        // Assert
        #expect(lines.map(\.kind) == [.hunk, .context, .deletion, .addition])
    }
}
