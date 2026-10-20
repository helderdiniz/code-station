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

extension EnvironmentValues {
    // What Reply does with the text picked out of the transcript. Absent wherever there is
    // no composer to take it, so the menu leaves the entry out there.
    @Entry var transcriptReply: ((String) -> Void)? = nil
}
