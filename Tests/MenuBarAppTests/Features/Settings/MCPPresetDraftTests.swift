import Foundation
import Testing
@testable import MenuBarApp

// The presets editor works on drafts and writes presets, so what a draft reads from a
// preset and what it writes back are pinned down here, along with the checks that keep
// Save off.
struct MCPPresetDraftTests {

    private let grafana = SiteDefaults.MCP.Preset(
        name: "grafana-platform-dev",
        title: "Grafana platform dev",
        serverType: "Grafana",
        environment: "dev",
        command: "mcp-grafana",
        args: ["--enabled-tools", "search"],
        env: [.init(key: "GRAFANA_URL", value: "https://grafana.dev"),
              .init(key: "GRAFANA_TOKEN", value: "")])

    @Test func autoNameJoinsTypeAndLabelWithoutRepeatingTheType() {
        #expect(MCPPresetDraft.autoName(serverType: "Grafana", title: "Grafana platform dev")
                == "grafana-platform-dev")
        #expect(MCPPresetDraft.autoName(serverType: "Teya developer", title: "Platform")
                == "teya-developer-platform")
        #expect(MCPPresetDraft.autoName(serverType: "", title: "Glean search!") == "glean-search")
        #expect(MCPPresetDraft.autoName(serverType: "", title: "  ") == "")
    }

    @Test func readsAPresetAndWritesItBackUnchanged() {
        let draft = MCPPresetDraft(grafana)

        #expect(draft.usesAutoName)
        #expect(draft.transport == .local)
        #expect(draft.env.map(\.asks) == [false, true])
        #expect(draft.preset == grafana)
    }

    @Test func aNameThatDoesNotFollowTheLabelStaysCustom() {
        var preset = grafana
        preset.name = "grafana-dev"
        let draft = MCPPresetDraft(preset)

        #expect(!draft.usesAutoName)
        #expect(draft.name == "grafana-dev")
    }

    @Test func switchingTransportKeepsBothConnectionsButWritesOnlyTheActiveOne() {
        var draft = MCPPresetDraft(grafana)
        draft.transport = .remote
        draft.url = "https://mcp.example/mcp"
        draft.headers = [.init(key: "Authorization", asks: true)]

        let remote = draft.preset
        #expect(remote.command == nil && remote.args == nil && remote.env == nil)
        #expect(remote.url == "https://mcp.example/mcp")
        #expect(remote.type == "http")
        #expect(remote.headers == [.init(key: "Authorization", value: "")])

        draft.transport = .local
        #expect(draft.command == "mcp-grafana")
        #expect(draft.preset.url == nil)
        #expect(draft.preset.env?.count == 2)
    }

    @Test func anAskedValueIsWrittenEmptyEvenIfOneWasTyped() {
        var draft = MCPPresetDraft(grafana)
        draft.env[0].asks = true

        #expect(draft.preset.env?.first?.value == "")
        #expect(draft.askedCount == 2)
    }

    @Test func flagsEachFieldThatBlocksSaving() {
        let empty = MCPPresetDraft()
        let problems = empty.problems(among: [empty])
        #expect(problems.title != nil)
        #expect(problems.name != nil)
        #expect(problems.command != nil)

        var remote = MCPPresetDraft(title: "Remote", transport: .remote, url: "mcp.example")
        #expect(remote.problems(among: [remote]).url != nil)
        remote.url = "https://mcp.example"
        #expect(remote.problems(among: [remote]).isEmpty)
    }

    @Test func aFixedValueLeftEmptyIsAProblemButAnAskedOneIsNot() {
        var draft = MCPPresetDraft(grafana)
        draft.env.append(.init(key: "REGION"))
        #expect(draft.problems(among: [draft]).values != nil)

        draft.env[2].asks = true
        #expect(draft.problems(among: [draft]).isEmpty)
    }

    @Test func duplicateNamesAndKeysAreProblems() {
        let first = MCPPresetDraft(grafana)
        let second = MCPPresetDraft(grafana)
        #expect(first.problems(among: [first, second]).name != nil)

        var draft = first
        draft.env.append(.init(key: "GRAFANA_URL", value: "x"))
        #expect(draft.problems(among: [draft]).values != nil)
    }

    @Test func runsAsShowsTheCommandWithItsVariables() {
        let lines = MCPPresetDraft(grafana).runsAs

        #expect(lines.count == 3)
        #expect(lines[0].parts.first == .plain("GRAFANA_URL="))
        #expect(lines[1].parts.contains(.asked))
        #expect(lines[2].parts == [.plain("mcp-grafana"), .plain(" --enabled-tools search")])
    }

    @Test func runsAsShowsTheAddressAndHeadersForARemoteServer() {
        let draft = MCPPresetDraft(title: "Glean", transport: .remote, url: "https://glean.example",
                                   type: "sse",
                                   headers: [.init(key: "Authorization", asks: true)])

        #expect(draft.runsAs == [
            .init(parts: [.plain("SSE "), .plain("https://glean.example")]),
            .init(parts: [.dim("Authorization: "), .asked]),
        ])
    }

    @Test func groupsLikeTheAddMenuAndSearchesTheVisibleFields() {
        let drafts = [MCPPresetDraft(grafana),
                      MCPPresetDraft(title: "Glean"),
                      MCPPresetDraft(title: "Grafana edge", serverType: " Grafana ", environment: "prd")]

        let groups = MCPPresetDraft.groups(drafts)
        #expect(groups.map(\.serverType) == ["Grafana", nil])
        #expect(groups[0].drafts.count == 2)

        #expect(drafts.filter { $0.matches("prd") }.count == 1)
        #expect(drafts.filter { $0.matches("platform-dev") }.count == 1)
        #expect(drafts.filter { $0.matches("") }.count == 3)
    }
}
