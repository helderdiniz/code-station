import Foundation
import Testing
@testable import MenuBarApp

@MainActor
struct ExplorerFindTests {
    @Test func switchingModesKeepsTheQueryAndReadsEachModeOnce() async throws {
        let scratch = ScratchDirectory(prefix: "explorer-find-modes")
        try "let needle = 1".write(to: scratch.path("needle.swift"), atomically: true, encoding: .utf8)
        try "no match".write(to: scratch.path("other.swift"), atomically: true, encoding: .utf8)
        let model = ExplorerFindModel(root: scratch.url.path, includeHidden: false, mode: .names, query: "needle")
        #expect(model.resultsState == .loading)
        model.prepare()
        #expect(await waitUntil { model.resultsState == .matches })
        #expect(model.names.matches.map(\.name) == ["needle.swift"])
        #expect(model.summary == "1 file")

        model.show(.contents)
        #expect(model.query == "needle")
        #expect(model.resultsState == .loading)
        #expect(await waitUntil { model.resultsState == .matches })
        #expect(model.contents.query == "needle")
        #expect(model.summary == "1 match in 1 file")
        guard case .line(let match) = model.selected else {
            Issue.record("Expected a line to be selected")
            return
        }
        #expect(match.line.number == 1)

        model.query = "nothing here"
        model.show(.names)
        #expect(model.names.query == "nothing here")
        #expect(model.resultsState == .empty)
        #expect(model.summary == "No files")
    }

    @Test func aBlankQueryAsksForTypingInBothModes() {
        let model = ExplorerFindModel(root: "/nowhere", includeHidden: true, mode: .contents, query: "  ")
        #expect(model.resultsState == .prompt)
        #expect(model.summary == nil)
        model.show(.names)
        #expect(model.resultsState == .prompt)
        model.cancel()
    }

    @Test func movingTheSelectionWrapsAtBothEnds() async throws {
        let scratch = ScratchDirectory(prefix: "explorer-find-wrap")
        for name in ["a-item.txt", "b-item.txt", "c-item.txt"] {
            try "item".write(to: scratch.path(name), atomically: true, encoding: .utf8)
        }
        let model = ExplorerFindModel(root: scratch.url.path, includeHidden: false, mode: .names, query: "item")
        model.prepare()
        #expect(await waitUntil { model.names.matches.count == 3 })
        #expect(model.names.selectedIndex == 0)
        model.moveSelection(by: -1)
        #expect(model.names.selectedIndex == 2)
        model.moveSelection(by: 1)
        #expect(model.names.selectedIndex == 0)

        model.show(.contents)
        #expect(await waitUntil { model.contents.matches.count == 3 })
        model.moveSelection(by: -1)
        #expect(model.contents.selectedIndex == 2)
        model.moveSelection(by: 1)
        #expect(model.contents.selectedIndex == 0)
    }
}
