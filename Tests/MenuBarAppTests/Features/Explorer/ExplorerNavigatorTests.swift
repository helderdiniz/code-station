import Foundation
import Testing
@testable import MenuBarApp

@MainActor
struct ExplorerNavigatorTests {
    @Test func filtersAndSearchStayInsideTheActiveProject() async throws {
        let first = ScratchDirectory(prefix: "explorer-search")
        let second = ScratchDirectory(prefix: "explorer-search-other")
        try "first needle".write(to: first.path("same.swift"), atomically: true, encoding: .utf8)
        try "second needle".write(to: second.path("same.swift"), atomically: true, encoding: .utf8)
        let model = ExplorerNavigator()
        model.query = "same"
        await model.search(root: first.url.path, includeHidden: false, pinned: [])
        #expect(model.hits.map(\.file.path) == [first.path("same.swift").resolvingSymlinksInPath().path])
        model.mode = .contents
        model.query = "needle"
        await model.search(root: second.url.path, includeHidden: false, pinned: [])
        #expect(model.hits.map(\.file.path) == [second.path("same.swift").resolvingSymlinksInPath().path])
        #expect(model.hits.first?.line?.number == 1)
        #expect(model.hits.first?.line?.text == "second needle")
    }

    @Test func pinnedFilterAlsoAppliesToContentMatches() async throws {
        let scratch = ScratchDirectory(prefix: "explorer-pinned-search")
        for name in ["one.swift", "two.swift", ".hidden.swift"] {
            try "needle".write(to: scratch.path(name), atomically: true, encoding: .utf8)
        }
        let files = await FileTree.files(beneath: scratch.url, includeHidden: true)
        let pinned = files.filter { $0.name == "two.swift" || $0.name == ".hidden.swift" }
        let model = ExplorerNavigator()
        model.filter = .pinned
        model.mode = .contents
        model.query = "needle"
        await model.search(root: scratch.url.path, includeHidden: false, pinned: pinned)
        #expect(model.hits.map(\.file.name) == ["two.swift"])
        await model.search(root: scratch.url.path, includeHidden: true, pinned: pinned)
        #expect(Set(model.hits.map(\.file.name)) == ["two.swift", ".hidden.swift"])
    }

    @Test func changedFilterIncludesDeletedFilesAndRealGitStatus() async throws {
        let repo = try GitRepo()
        try repo.write("removed.swift", "old")
        try repo.commit("Add fixture")
        try repo.write("README.md", "edited")
        try repo.write("added.swift", "new")
        try FileManager.default.removeItem(at: repo.url.appendingPathComponent("removed.swift"))
        let model = ExplorerNavigator()
        await model.refreshStatus(roots: [repo.path])
        model.filter = .changed
        await model.search(root: repo.path, includeHidden: false, pinned: [])
        #expect(Set(model.hits.map(\.file.name)) == ["README.md", "added.swift", "removed.swift"])
        #expect(model.statuses[repo.url.appendingPathComponent("removed.swift").resolvingSymlinksInPath().path] == .deleted)
        #expect(model.statuses[repo.url.appendingPathComponent("README.md").resolvingSymlinksInPath().path] == .modified)
    }

    @Test func contentResultsCanLoadAnotherPage() async throws {
        let scratch = ScratchDirectory(prefix: "explorer-search-pages")
        let contents = Array(repeating: "needle", count: 205).joined(separator: "\n")
        try contents.write(to: scratch.path("many.txt"), atomically: true, encoding: .utf8)
        let model = ExplorerNavigator()
        model.mode = .contents
        model.query = "needle"
        await model.search(root: scratch.url.path, includeHidden: false, pinned: [])
        #expect(model.hits.count == 200)
        #expect(model.hasMore)
        await model.loadMore()
        #expect(model.hits.count == 205)
        #expect(!model.hasMore)
        #expect(Set(model.hits.map(\.id)).count == 205)
    }

    @Test func invalidatingSearchFindsNewFiles() async throws {
        let scratch = ScratchDirectory(prefix: "explorer-search-refresh")
        let model = ExplorerNavigator()
        model.query = "new"
        await model.search(root: scratch.url.path, includeHidden: false, pinned: [])
        #expect(model.hits.isEmpty)
        try "new".write(to: scratch.path("new.txt"), atomically: true, encoding: .utf8)
        model.invalidate()
        await model.search(root: scratch.url.path, includeHidden: false, pinned: [])
        #expect(model.hits.map(\.file.name) == ["new.txt"])
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
