import Foundation
import Testing
@testable import MenuBarApp

@MainActor
struct ChangesFileNotesTests {
    private let root = "/repo"
    private let path = "Sources/App.swift"

    private func comment(_ line: Int, _ body: String = "Note", status: ReviewComment.Status = .kept,
                         severity: ReviewComment.Severity? = nil) -> ReviewComment {
        ReviewComment(root: root, path: path, anchor: DiffAnchor(side: .new, line: line), excerpt: "x",
                      body: body, status: status, severity: severity)
    }

    private func question(_ line: Int, answered: Bool = true, resolved: Bool = false) -> ReviewQuestion {
        var question = ReviewQuestion(root: root, path: path, anchor: DiffAnchor(side: .new, line: line),
                                      excerpt: "x", agent: .claudeCode, question: "Why?")
        if answered { question.exchanges[0].answer = "Because." }
        question.resolved = resolved
        return question
    }

    @Test func everyKindOfCommentSitsUnderItsFileInLineOrder() {
        let unsent = comment(30)
        let sentComment = comment(5)
        let round = ReviewRound(prompt: "p", note: "", comments: [sentComment])
        let asked = question(12)

        let notes = FileNotes(unsent: [unsent], sent: [(round, sentComment)], questions: [(asked, .none)])

        #expect(notes.notes.map(\.id) == [sentComment.id, asked.id, unsent.id])
        #expect(notes.notes.map(\.tag) == [.status(.waiting), .answered, .notSent])
    }

    @Test func resolvedCommentsHideUntilAskedForAndTheBadgeCountsWhatIsOpen() {
        let open = comment(1)
        let done = comment(2)
        var round = ReviewRound(prompt: "p", note: "", comments: [done])
        round.resolved = [done.id]

        let notes = FileNotes(unsent: [open], sent: [(round, done)], questions: [(question(3, resolved: true), .none)])

        #expect(notes.resolvedCount == 2)
        #expect(notes.badgeCount == 1)
        #expect(notes.shown(includingResolved: false).map(\.id) == [open.id])
        #expect(notes.shown(includingResolved: true).count == 3)
    }

    @Test func aFileWithEveryCommentResolvedStillShowsItHadSome() {
        let done = comment(2)
        var round = ReviewRound(prompt: "p", note: "", comments: [done])
        round.resolved = [done.id]

        let notes = FileNotes(unsent: [], sent: [(round, done)], questions: [])

        #expect(notes.badgeCount == 1)
        #expect(notes.tone == .plain)
    }

    @Test func theBadgeTakesTheToneOfTheMostPressingOpenComment() {
        let sent = comment(1)
        let quiet = FileNotes(unsent: [], sent: [(ReviewRound(prompt: "p", note: "", comments: [sent]), sent)],
                              questions: [])
        #expect(quiet.tone == .plain)

        #expect(FileNotes(unsent: [comment(1)], sent: [], questions: []).tone == .attention)
        #expect(FileNotes(unsent: [comment(1, severity: .must)], sent: [], questions: []).tone == .must)
        #expect(FileNotes(unsent: [], sent: [], questions: [(question(1), .none)]).tone == .attention)
        #expect(FileNotes(unsent: [], sent: [], questions: [(question(1, answered: false), .none)]).tone == .plain)
    }

    @Test func aChangeMadeFromAQuestionIsNotListedTwice() {
        let asked = question(4)
        var change = comment(4)
        change.questionID = asked.id

        let notes = FileNotes(unsent: [change], sent: [], questions: [(asked, .waiting)])

        #expect(notes.notes.map(\.id) == [asked.id])
        #expect(notes.notes.first?.tag == .changeWaiting)
        #expect(notes.notes.first?.needsYou == false)
    }

    @Test func findingsSayHowMuchTheyMatterAndUnsortedOnesWaitForALook() {
        let notes = FileNotes(unsent: [comment(1, status: .pending), comment(2, severity: .should)],
                              sent: [], questions: [])
        #expect(notes.notes.map(\.tag) == [.toLookAt, .severity(.should)])
    }

    @Test func anUnreadReplyNeedsYou() {
        let sent = comment(1)
        var round = ReviewRound(prompt: "p", note: "", comments: [sent])
        round.unread = [sent.id]

        let note = FileNotes(unsent: [], sent: [(round, sent)], questions: []).notes[0]

        #expect(note.unread)
        #expect(note.needsYou)
    }

    @Test func theStoreGathersOneFileOnly() {
        let store = ReviewCommentStore(url: nil)
        let session = UUID()
        store.add(comment(1), to: session)
        store.add(ReviewComment(root: root, path: "Other.swift", anchor: DiffAnchor(side: .new, line: 1),
                                excerpt: "x", body: "Elsewhere"), to: session)

        let notes = FileNotes.on(root: root, path: path, in: store, session: session)

        #expect(notes.notes.count == 1)
        #expect(FileNotes.on(root: "/other", path: path, in: store, session: session).isEmpty)
    }
}
