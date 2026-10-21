import SwiftUI

// Text picked out of the transcript and taken into the composer as a quote, so the next
// prompt can answer one part of what was said rather than all of it. It is plain
// Markdown, which the agent reads as a quote and the sent bubble draws as one.
enum ReplyQuote {
    static func appending(_ selection: String, to draft: String) -> String {
        let quoted = selection.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .map { line in
                // Only the end is trimmed, so quoted code keeps its indentation.
                let line = line.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
                return line.isEmpty ? ">" : "> \(line)"
            }
            .joined(separator: "\n")
        guard quoted != ">" else { return draft }
        let lead = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return (lead.isEmpty ? "" : lead + "\n\n") + quoted + "\n\n"
    }
}

// What Reply does with the text picked out of the transcript. Two are equal while they
// quote into the same session, so the fresh closure each update brings does not redraw
// every run of text in the transcript.
struct TranscriptReply: Equatable {
    let sessionID: UUID
    let action: (String) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.sessionID == rhs.sessionID }
}

extension EnvironmentValues {
    // Absent wherever there is no composer to take the quote, so the menu leaves Reply out there.
    @Entry var transcriptReply: TranscriptReply? = nil
}
