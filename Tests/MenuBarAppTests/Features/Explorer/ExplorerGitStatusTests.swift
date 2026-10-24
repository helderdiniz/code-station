import Foundation
import Testing
@testable import MenuBarApp

@MainActor
struct ExplorerGitStatusTests {
    @Test func statusesIncludeDeletedFilesAndRealGitStatus() async throws {
        let repo = try GitRepo()
        try repo.write("removed.swift", "old")
        try repo.commit("Add fixture")
        try repo.write("README.md", "edited")
        try repo.write("added.swift", "new")
        try FileManager.default.removeItem(at: repo.url.appendingPathComponent("removed.swift"))
        let model = ExplorerGitStatus()
        await model.refresh(roots: [repo.path])
        let path = { (name: String) in repo.url.appendingPathComponent(name).resolvingSymlinksInPath().path }
        #expect(model.statuses[path("removed.swift")] == .deleted)
        #expect(model.statuses[path("README.md")] == .modified)
        #expect(model.statuses[path("added.swift")] != nil)
    }
}

@MainActor
struct ExplorerDocumentsTests {
    @Test func openingAndClosingTabsKeepsOtherDraftsAndPins() {
        let first = node("/project/one.swift")
        let second = node("/project/two.swift")
        var documents = ExplorerDocuments()
        documents.open(first)
        documents.open(second)
        documents.open(first)
        documents.edits[first.path] = edit(first.path)
        documents.togglePin(first)
        documents.close(second.path)
        #expect(documents.tabs == [first])
        #expect(documents.edits[first.path]?.draft == "draft")
        #expect(documents.pinned == [first])
        documents.close(first.path)
        #expect(documents.edits.isEmpty)
        #expect(documents.pinned == [first])
    }

    @Test func memoryKeepsAllDraftsAndMovesOrRemovesOnlyTheTargetFolder() {
        let nested = node("/project/Sources/one.swift")
        let beside = node("/project/SourcesExtra/two.swift")
        var documents = ExplorerDocuments(tabs: [nested, beside],
                                          edits: [nested.path: edit(nested.path), beside.path: edit(beside.path)],
                                          pinned: [nested, beside])
        let memory = ExplorerMemory()
        memory.remember(.init(documents: documents), for: "/project")
        memory.remember(.init(), for: "/other")
        memory.moved(from: "/project/Sources", to: "/project/Code")
        documents = memory.place(for: "/project")!.documents
        #expect(documents.tabs.map(\.path) == ["/project/Code/one.swift", beside.path])
        #expect(documents.pinned.map(\.path) == documents.tabs.map(\.path))
        #expect(memory.unsavedEdit(inside: "/project/Code")?.draft == "draft")
        #expect(memory.place(for: "/other")?.documents.pinned.isEmpty == true)
        memory.removed("/project/Code")
        #expect(memory.place(for: "/project")?.documents.tabs == [beside])
        #expect(memory.place(for: "/project")?.documents.pinned == [beside])
        #expect(memory.unsavedEdit(inside: "/project/Code") == nil)
        #expect(memory.unsavedEdit(inside: "/project/SourcesExtra")?.loadedAt == Date(timeIntervalSince1970: 100))
    }

    @Test func singleChildFoldersCompactButFilesAndLinksDoNot() {
        let sources = node("/project/Sources", directory: true)
        let app = node("/project/Sources/App", directory: true)
        let file = node("/project/Sources/App/file.swift")
        let children = ["/project": [sources], sources.path: [app], app.path: [file]]
        let closed = ExplorerTreeRow.rows(in: "/project", children: children, expanded: [])
        #expect(closed.map(\.name) == ["Sources / App"])
        #expect(closed.map(\.id) == [app.path])
        let opened = ExplorerTreeRow.rows(in: "/project", children: children, expanded: [app.path])
        #expect(opened.map(\.depth) == [0, 1])
        #expect(opened.map(\.node.path) == [app.path, file.path])
        var link = app
        link.linkDestination = "../Sources"
        let linked = ExplorerTreeRow.rows(in: "/project", children: ["/project": [sources], sources.path: [link]], expanded: [])
        #expect(linked.map(\.name) == ["Sources"])
    }

    private func node(_ path: String, directory: Bool = false) -> FileNode {
        let url = URL(fileURLWithPath: path)
        return FileNode(url: url, name: url.lastPathComponent, isDirectory: directory, size: 0)
    }

    private func edit(_ path: String) -> ExplorerMemory.UnsavedEdit {
        .init(path: path, preview: .text("saved"), draft: "draft", original: "saved", loadedAt: Date(timeIntervalSince1970: 100))
    }
}
