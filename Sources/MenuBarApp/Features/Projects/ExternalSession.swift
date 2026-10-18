import Foundation

struct ImportedSessionOrigin: Codable, Equatable, Sendable {
    let sessionID: String
    let agent: AgentKind
    let configDirectory: String

    static func key(agent: AgentKind, sessionID: String) -> String {
        "\(agent.rawValue):\(sessionID)"
    }
}

struct ExternalSessionCandidate: Identifiable, Hashable, Sendable {
    let sessionID: String
    var agent: AgentKind = .claudeCode
    let file: URL
    let cwd: String
    let title: String?
    let firstPrompt: String?
    let startedAt: Date?
    let lastActivity: Date
    let gitBranch: String?
    let bytes: Int
    var configDirectory: URL? = nil

    var id: String { ImportedSessionOrigin.key(agent: agent, sessionID: sessionID) }

    var origin: ImportedSessionOrigin {
        ImportedSessionOrigin(sessionID: sessionID, agent: agent,
                              configDirectory: (configDirectory ?? file.deletingLastPathComponent()
                                .deletingLastPathComponent().deletingLastPathComponent()).path)
    }

    var displayTitle: String {
        if let title, !title.isBlank { return title }
        let words = (firstPrompt ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !words.isEmpty else { return "Untitled session" }
        return words.count > 48 ? String(words.prefix(48)) + "…" : words
    }
}

extension AgentKind {
    var historyEnvironmentVariable: String {
        switch self {
        case .claudeCode: "CLAUDE_CONFIG_DIR"
        case .codex: "CODEX_HOME"
        case .copilot: "COPILOT_HOME"
        }
    }
}
