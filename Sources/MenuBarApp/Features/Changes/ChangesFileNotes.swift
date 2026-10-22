import Foundation

// One line under a file in the Changes list. Every kind of note is a comment there:
// one not sent yet, one sent to the agent, or a question answered on the screen. What
// it is and where it stands is said by its tag, not by the place it sits in.
struct FileNote: Identifiable {
    enum Source {
        case unsent(ReviewComment)
        case sent(ReviewComment, ReviewRound)
        case question(ReviewQuestion)
    }

    enum Tag: Equatable {
        case notSent, toLookAt
        case severity(ReviewComment.Severity)
        case status(ReviewRound.Status)
        case answering, couldNotAnswer, stopped, answered, changeWaiting, becameChange, resolved
    }

    // What came of a question's suggested change, which only the store can tell.
    enum QuestionChange {
        case none, waiting, sent
    }

    let source: Source
    let tag: Tag
    let isResolved: Bool
    // Something only the person can move on: a comment to send or look at, an answer
    // not yet read, a question answered and not settled.
    let needsYou: Bool
    let mustFix: Bool
    let unread: Bool

    var id: UUID {
        switch source {
        case .unsent(let comment), .sent(let comment, _): comment.id
        case .question(let question): question.id
        }
    }

    var line: Int {
        switch source {
        case .unsent(let comment), .sent(let comment, _): comment.onFile ? 0 : comment.line
        case .question(let question): question.line
        }
    }

    var created: Date {
        switch source {
        case .unsent(let comment), .sent(let comment, _): comment.created
        case .question(let question): question.created
        }
    }

    init(unsent comment: ReviewComment) {
        source = .unsent(comment)
        tag = comment.severity.map(Tag.severity) ?? (comment.isPending ? .toLookAt : .notSent)
        isResolved = false
        needsYou = true
        mustFix = comment.severity == .must
        unread = false
    }

    init(sent comment: ReviewComment, round: ReviewRound) {
        let status = round.status(comment.id)
        source = .sent(comment, round)
        tag = .status(status)
        isResolved = status == .resolved
        unread = round.unread.contains(comment.id)
        needsYou = unread || status == .unchanged
        mustFix = comment.severity == .must && !isResolved
    }

    init(question: ReviewQuestion, change: QuestionChange) {
        source = .question(question)
        isResolved = question.resolved
        mustFix = false
        unread = false
        switch question.status {
        case .answering: tag = .answering
        case .failed: tag = .couldNotAnswer
        case .stopped: tag = .stopped
        case .answered:
            tag = switch change {
            case .sent: .becameChange
            case .waiting: .changeWaiting
            case .none: question.resolved ? .resolved : .answered
            }
        }
        needsYou = !question.resolved && change == .none
            && (question.status == .answered || question.status == .failed)
    }
}

// Every note on one file, in line order, so the file row can say how many are open and
// fold them under it.
struct FileNotes {
    let notes: [FileNote]

    init(unsent: [ReviewComment], sent: [(round: ReviewRound, comment: ReviewComment)],
         questions: [(question: ReviewQuestion, change: FileNote.QuestionChange)]) {
        // A change made from a question's answer is drawn inside the question, so it is
        // not listed twice while the question is still there.
        let asked = Set(questions.map(\.question.id))
        let notes = unsent.filter { $0.questionID.map { !asked.contains($0) } ?? true }.map(FileNote.init(unsent:))
            + sent.map { FileNote(sent: $0.comment, round: $0.round) }
            + questions.map { FileNote(question: $0.question, change: $0.change) }
        self.notes = notes.sorted { ($0.line, $0.created) < ($1.line, $1.created) }
    }

    @MainActor
    static func on(root: String, path: String, in store: ReviewCommentStore, session: UUID) -> FileNotes {
        FileNotes(unsent: store.comments(session, root: root, path: path),
                  sent: store.threads(session, root: root, path: path),
                  questions: store.questions(session, root: root, path: path).map { question in
                      (question, change(of: question, in: store, session: session))
                  })
    }

    @MainActor
    static func change(of question: ReviewQuestion, in store: ReviewCommentStore,
                       session: UUID) -> FileNote.QuestionChange {
        guard let id = question.changeID else { return .none }
        if store.comment(id, in: session) != nil { return .waiting }
        return store.round(sending: id, in: session) != nil ? .sent : .none
    }

    var isEmpty: Bool { notes.isEmpty }
    var open: [FileNote] { notes.filter { !$0.isResolved } }
    var resolvedCount: Int { notes.count { $0.isResolved } }

    // The badge counts what is still open, and falls back to every note once all of them
    // are resolved, so a file that had comments still shows it.
    var badgeCount: Int {
        let open = open.count
        return open > 0 ? open : notes.count
    }

    enum Tone { case plain, attention, must }

    var tone: Tone {
        let open = open
        if open.contains(where: \.mustFix) { return .must }
        return open.contains(where: \.needsYou) ? .attention : .plain
    }

    // The notes the list shows: the open ones, and the resolved ones once asked for.
    func shown(includingResolved: Bool) -> [FileNote] {
        includingResolved ? notes : open
    }
}
