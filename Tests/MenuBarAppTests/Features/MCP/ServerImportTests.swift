import Foundation
import Testing
@testable import MenuBarApp

// Setup guides hand out the same server in each tool's own wrapping, so a paste from any
// of them should land as the same server.
@MainActor
struct ServerImportTests {
    private let scratch = ScratchDirectory(prefix: "server-import")

    private func emptyStore() throws -> ConfigStore {
        let file = scratch.path("config.json")
        try Data(#"{ "mcpServers": {} }"#.utf8).write(to: file)
        return ConfigStore(configURL: file)
    }

    private func importedNames(_ json: String) throws -> [String] {
        let configs = try emptyStore()
        try configs.importJSON(json)
        return configs.servers.map(\.name)
    }

    @Test func aVSCodeCopilotSettingsBlockIsUnwrapped() throws {
        let configs = try emptyStore()

        try configs.importJSON("""
        {
          "editor.fontSize": 13,
          "github.copilot.chat.mcp.servers": {
            "glean_default": {
              "type": "http",
              "url": "https://example.glean.com/mcp/default"
            }
          }
        }
        """)

        let server = try #require(configs.servers.first)
        #expect(configs.servers.count == 1)
        #expect(server.name == "glean_default")
        #expect(server.url == "https://example.glean.com/mcp/default")
        #expect(server.transport == "http")
    }

    @Test func aVSCodeMcpJsonFileIsUnwrappedAndItsInputsLeftBehind() throws {
        let names = try importedNames("""
        {
          "inputs": [{ "id": "token", "type": "promptString" }],
          "servers": { "docs": { "type": "stdio", "command": "docs-server" } }
        }
        """)

        #expect(names == ["docs"])
    }

    @Test func aVSCodeSettingsMcpBlockIsUnwrapped() throws {
        let names = try importedNames(#"{ "mcp": { "servers": { "docs": { "command": "docs-server" } } } }"#)

        #expect(names == ["docs"])
    }

    @Test func aClaudeOrCursorBlockIsUnwrapped() throws {
        let names = try importedNames(#"{ "mcpServers": { "docs": { "command": "docs-server" } } }"#)

        #expect(names == ["docs"])
    }

    @Test func aServerNamedLikeAWrapperIsKeptAsAServer() throws {
        let names = try importedNames("""
        {
          "servers": { "command": "servers-cli" },
          "docs": { "command": "docs-server" }
        }
        """)

        #expect(names == ["docs", "servers"])
    }
}
