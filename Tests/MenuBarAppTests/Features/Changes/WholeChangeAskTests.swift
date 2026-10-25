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

    @Test func referencesInAnAnswerAreTheChangedFilesItLinksOrNamesEachOnce() {
        let answer = """
        The view starts in [View.swift:12](/work/app/Sources/View.swift:12), and reads `keys.json:3`. \
        See [View.swift:12](/work/app/Sources/View.swift:12) again, [elsewhere](/work/app/Other.swift) \
        and [the docs](https://example.com). `let x = 1` is code, not a file.
        """
        let found = ChangeCitation.references(in: answer, roots: roots) { changed.contains("\($0)|\($1)") }
        #expect(found.map(\.path) == ["Sources/View.swift", "keys.json"])
        #expect(found.map(\.root) == ["/work/app", "/work/settings"])
        #expect(found.first?.linesSuffix == ":12")
        #expect(found.first?.spokenName == "Show View.swift line 12")
    }

    @Test func aReferenceToARangeSaysBothEnds() {
        let citation = resolve("/work/app/Sources/View.swift:606-616")
        #expect(citation?.linesSuffix == ":606-616")
        #expect(citation?.spokenName == "Show View.swift lines 606 to 616")
        #expect(resolve("keys.json")?.spokenName == "Show keys.json")
    }

    @Test func startersAskAboutHowProjectsFitOnlyWhenThereAreSeveral() {
        #expect(WholeChangeThreads.starters(projects: 2).count == 4)
        #expect(WholeChangeThreads.starters(projects: 2).last == "How do the two projects fit together?")
        #expect(WholeChangeThreads.starters(projects: 3).last == "How do the 3 projects fit together?")
        #expect(!WholeChangeThreads.starters(projects: 1).contains { $0.contains("projects") })
    }

    @Test func aFinishedStepIsToldAsDone() {
        #expect(WholeChangeThreads.finishedStep("Opening a side copy of this session") == "Opened a side copy of this session")
        #expect(WholeChangeThreads.finishedStep("Reading the chat so far") == "Read the chat so far")
        #expect(WholeChangeThreads.finishedStep("Going on in the side copy") == "Went on in the side copy")
        // A word that only starts the same way is left alone.
        #expect(WholeChangeThreads.finishedStep("Readme checked") == "Readme checked")
    }

    @Test func aWholeChangeQuestionAsksForFileLinksAndALineQuestionDoesNot() {
        let whole = ReviewQuestion.whole(root: "/repo", agent: .claudeCode, question: "Why?")
        let lines = ReviewQuestion(root: "/repo", path: "App.swift", anchor: DiffAnchor(side: .new, line: 3),
                                   excerpt: "", agent: .claudeCode, question: "Why?")
        #expect(SideQuestion.forkPrompt(whole).contains(SideQuestion.referenceInstructions))
        #expect(SideQuestion.readOnlyPrompt(whole, patches: [], recentChat: "").contains(SideQuestion.referenceInstructions))
        #expect(!SideQuestion.forkPrompt(lines).contains(SideQuestion.referenceInstructions))
    }

    // MARK: Removing and editing

    private let context = QuestionContext(agent: .claudeCode, executable: nil, directory: "/repo",
                                          repositories: [], conversationID: nil, recentChat: "")

    @Test func aRemovedQuestionComesBackWhereItWas() {
        let store = ReviewCommentStore(url: nil)
        let session = UUID()
        let first = whole("First", created: Date())
        let second = whole("Second", created: Date())
        store.ask(first, context: context, in: session)
        store.ask(second, context: context, in: session)

        store.deleteQuestion(first.id, in: session)
        #expect(store.questions(session).map(\.text) == ["Second"])
        store.restoreQuestion(first, at: 0, in: session)
        #expect(store.questions(session).map(\.text) == ["First", "Second"])
        // Undoing twice does not make two of it.
        store.restoreQuestion(first, at: 0, in: session)
        #expect(store.questions(session).count == 2)
    }

    @Test func editingTakesBackOnlyAFollowUp() {
        let store = ReviewCommentStore(url: nil)
        let session = UUID()
        let question = whole("First", created: Date())
        store.ask(question, context: context, in: session)
        #expect(store.withdrawFollowUp(question.id, in: session) == nil)

        store.followUp("And then?", to: question.id, context: context, in: session)
        #expect(store.question(question.id, in: session)?.exchanges.count == 2)
        #expect(store.withdrawFollowUp(question.id, in: session) == "And then?")
        #expect(store.question(question.id, in: session)?.exchanges.map(\.question) == ["First"])
    }
}
