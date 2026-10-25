import Foundation
import Testing
@testable import MenuBarApp

// Questions about the whole change are asked and answered in a card that grows out of the
// session header, over the diff, rather than at the foot of the file list.
@MainActor
struct WholeChangeAskTests {
    private func whole(_ text: String, created: Date, resolved: Bool = false, answered: Date? = nil) -> ReviewQuestion {
        var question = ReviewQuestion.whole(root: "/repo", agent: .claudeCode, question: text)
        question.created = created
        question.resolved = resolved
        if let answered {
            question.exchanges[0].answer = "Because."
            question.exchanges[0].answered = answered
        }
        return question
    }

    @Test func threadsReadOldestFirstWithResolvedOnesApart() {
        let now = Date()
        let lines = ReviewQuestion(root: "/repo", path: "App.swift", anchor: DiffAnchor(side: .new, line: 3),
                                   excerpt: "", agent: .claudeCode, question: "What is this?")
        let newer = whole("Newer", created: now)
        let older = whole("Older", created: now.addingTimeInterval(-60))
        let done = whole("Done", created: now.addingTimeInterval(-120), resolved: true)

        let threads = WholeChangeThreads.split([newer, lines, done, older])

        #expect(threads.open.map(\.text) == ["Older", "Newer"])
        #expect(threads.resolved.map(\.text) == ["Done"])
    }

    @Test func theNewestOpenThreadShowsUnlessAnotherIsPicked() {
        let now = Date()
        let first = whole("First", created: now.addingTimeInterval(-60))
        let second = whole("Second", created: now)
        #expect(WholeChangeThreads.expanded(nil, in: [first, second]) == second.id)
        #expect(WholeChangeThreads.expanded(first.id, in: [first, second]) == first.id)
        // A pick that has since been resolved or deleted falls back to the newest.
        #expect(WholeChangeThreads.expanded(UUID(), in: [first, second]) == second.id)
        #expect(WholeChangeThreads.expanded(nil, in: []) == nil)
    }

    @Test func onlyAnAnswerThatLandsWhileTheCardIsAwayIsUnread() {
        let seen = Date()
        let before = whole("Before", created: seen.addingTimeInterval(-60), answered: seen.addingTimeInterval(-1))
        let after = whole("After", created: seen.addingTimeInterval(-60), answered: seen.addingTimeInterval(1))
        let answering = whole("Answering", created: seen)
        #expect(!WholeChangeThreads.hasUnreadAnswer([before, answering], seen: seen))
        #expect(WholeChangeThreads.hasUnreadAnswer([before, after], seen: seen))
    }

    @Test func openingOrPuttingAwayTheCardMarksAnswersSeen() throws {
        let memory = ChangesNavigationMemory()
        #expect(!memory.askingWholeChange)
        let start = memory.wholeChangeSeen
        memory.setAskingWholeChange(true)
        #expect(memory.askingWholeChange)
        #expect(memory.wholeChangeSeen >= start)

        memory.askFollowing = UUID()
        let opened = memory.wholeChangeSeen
        memory.setAskingWholeChange(false)
        #expect(!memory.askingWholeChange)
        #expect(memory.wholeChangeSeen >= opened)
        // A follow-up started in the card does not carry over to the next time it opens.
        #expect(memory.askFollowing == nil)
    }

    @Test func theCardDoesNotDependOnTheListMode() {
        let memory = ChangesNavigationMemory()
        memory.setAskingWholeChange(true)
        memory.showingHistory = true
        #expect(memory.askingWholeChange)
    }

    // MARK: References in an answer

    private let roots = ["/work/app", "/work/settings"]
    private let changed: Set<String> = ["/work/app|Sources/View.swift", "/work/settings|keys.json"]

    private func resolve(_ link: String) -> ChangeCitation? {
        let url = link.hasPrefix("/") ? URL(fileURLWithPath: link) : URL(string: link)!
        return ChangeCitation.resolve(url, roots: roots) { changed.contains("\($0)|\($1)") }
    }

    @Test func anAbsoluteLinkFindsItsRepositoryAndLines() {
        let citation = resolve("/work/app/Sources/View.swift:606-616")
        #expect(citation?.root == "/work/app")
        #expect(citation?.path == "Sources/View.swift")
        #expect(citation?.anchor == DiffAnchor(side: .new, line: 606, lastLine: 616))
    }

    @Test func aLinkWithAColumnPointsAtOneLine() {
        #expect(resolve("/work/app/Sources/View.swift:12:4")?.anchor == DiffAnchor(side: .new, line: 12))
    }

    @Test func aRelativeLinkFindsTheRepositoryThatChangedIt() {
        let citation = resolve("keys.json:3")
        #expect(citation?.root == "/work/settings")
        #expect(citation?.path == "keys.json")
        #expect(citation?.anchor == DiffAnchor(side: .new, line: 3))
        #expect(resolve("Sources/View.swift")?.anchor == nil)
        #expect(resolve("./Sources/View.swift")?.root == "/work/app")
    }

    @Test func filesOutsideTheChangeAndWebLinksOpenAsUsual() {
        #expect(resolve("/work/app/Sources/Other.swift:3") == nil)
        #expect(resolve("/elsewhere/View.swift") == nil)
        #expect(resolve("https://example.com/Sources/View.swift") == nil)
    }
}
