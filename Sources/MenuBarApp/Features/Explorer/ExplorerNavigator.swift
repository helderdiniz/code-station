import SwiftUI

enum ExplorerFileFilter: String, CaseIterable {
    case all = "All files", changed = "Changed", pinned = "Pinned"
}

enum ExplorerSearchMode: String, CaseIterable {
    case names = "File names", contents = "Contents"
}

struct ExplorerSearchHit: Identifiable {
    let file: FileNode
    var line: FileTextLine?
    var id: String { file.path + ":" + String(line?.number ?? 0) }
}

@MainActor
@Observable
final class ExplorerNavigator {
    var query = ""
    var mode = ExplorerSearchMode.names
    var filter = ExplorerFileFilter.all
    private(set) var hits: [ExplorerSearchHit] = []
    private(set) var loading = false
    private(set) var loadingMore = false
    private(set) var limited = false
    private(set) var hasMore = false
    private(set) var statuses: [String: GitStatusKind] = [:]
    private(set) var statusNote: String?
    var cursor: String?
    var revision = 0

    @ObservationIgnored private var indexedRoot: String?
    @ObservationIgnored private var files: [FileNode] = []
    @ObservationIgnored private var documents: [FileTextDocument]?
    @ObservationIgnored private var documentLimitReached = false
    @ObservationIgnored private var page = FileTextSearchResult()
    @ObservationIgnored private var searchedDocuments: [FileTextDocument] = []
    @ObservationIgnored private var searchedQuery = ""
    @ObservationIgnored private var searchGeneration = 0

    var isFiltering: Bool { !query.isBlank || filter != .all }

    func invalidate() {
        indexedRoot = nil
        revision += 1
    }

    func refreshStatus(roots: [String]) async {
        var statuses: [String: GitStatusKind] = [:]
        var unavailable = false
        for root in roots {
            let snapshot = await GitInspector.snapshot(at: root, lane: .interactive)
            guard !Task.isCancelled else { return }
            switch snapshot.state {
            case .ready:
                for file in snapshot.files {
                    let path = URL(fileURLWithPath: snapshot.root).standardizedFileURL.appendingPathComponent(file.path).path
                    if let relative = path.pathRelative(to: URL(fileURLWithPath: root).resolvingSymlinksInPath().path) {
                        statuses[URL(fileURLWithPath: root).appendingPathComponent(relative).path] = file.kind
                    }
                }
            case .notARepo: break
            default: unavailable = true
            }
        }
        self.statuses = statuses
        statusNote = unavailable ? "Some file statuses are unavailable. Refresh to try again." : nil
    }

    static func filtered(_ files: [FileNode], by filter: ExplorerFileFilter,
                         pinned: Set<String>, statuses: [String: GitStatusKind]) -> [FileNode] {
        files.filter { file in
            switch filter {
            case .all: true
            case .changed: statuses[file.path] != nil
            case .pinned: pinned.contains(file.path)
            }
        }
    }

    func search(root: String, includeHidden: Bool, pinned: [FileNode]) async {
        searchGeneration += 1
        loadingMore = false
        guard isFiltering else { hits = []; cursor = nil; loading = false; return }
        loading = true
        defer { if !Task.isCancelled { loading = false } }
        do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
        let key = root + (includeHidden ? ":hidden" : ":visible")
        if indexedRoot != key {
            let files = await FileTree.files(beneath: URL(fileURLWithPath: root), includeHidden: includeHidden)
            guard !Task.isCancelled else { return }
            self.files = files
            documents = nil
            indexedRoot = key
        }
        var candidates = files
        let paths = Set(candidates.map(\.path))
        for (path, status) in statuses where status == .deleted && path.pathRelative(to: root) != nil && !paths.contains(path) {
            let url = URL(fileURLWithPath: path)
            if includeHidden || !path.dropFirst(root.count).split(separator: "/").contains(where: { $0.hasPrefix(".") }) {
                candidates.append(FileNode(url: url, name: url.lastPathComponent, isDirectory: false, size: 0))
            }
        }
        candidates = Self.filtered(candidates, by: filter, pinned: Set(pinned.map(\.path)), statuses: statuses)
        limited = false
        hasMore = false
        if query.isBlank {
            hits = candidates.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                .map { ExplorerSearchHit(file: $0) }
        } else if mode == .names {
            hits = FileNameSearch.matches(query, in: candidates, beneath: root).map { ExplorerSearchHit(file: $0) }
            limited = hits.count == FileNameSearch.resultLimit
        } else {
            if documents == nil {
                var paths: Set<String>?
                if let tool = GitInspector.tool() { paths = await FileTextSearch.unignoredPaths(beneath: root, tool: tool) }
                let loaded = await FileTextSearch.documents(for: FileTextSearch.unignored(files, root: root, paths: paths))
                guard !Task.isCancelled else { return }
                documents = loaded.documents
                documentLimitReached = loaded.limited
            }
            let allowed = Set(candidates.map(\.path))
            let searchedDocuments = (documents ?? []).filter { allowed.contains($0.file.path) }
            let query = query
            let page = await FileTextSearch.matches(query, in: searchedDocuments,
                                                   from: FileTextSearchCursor(document: 0, location: 0))
            guard !Task.isCancelled else { return }
            self.page = page
            self.searchedDocuments = searchedDocuments
            searchedQuery = query
            limited = documentLimitReached
            applyPage()
        }
        cursor = hits.first?.id
    }

    func loadMore() async {
        guard let next = page.next, searchedQuery == query, !loading, !loadingMore else { return }
        let generation = searchGeneration
        loadingMore = true
        defer { if generation == searchGeneration { loadingMore = false } }
        let query = searchedQuery
        let more = await FileTextSearch.matches(query, in: searchedDocuments, from: next)
        guard !Task.isCancelled, generation == searchGeneration, query == self.query else { return }
        page.append(more)
        applyPage()
    }

    private func applyPage() {
        hits = page.files.flatMap { group in group.lines.map { ExplorerSearchHit(file: group.file, line: $0) } }
        hasMore = page.hasMore
    }

    func moveCursor(by step: Int) {
        guard let next = RowStep.destination(from: cursor.flatMap { id in hits.firstIndex { $0.id == id } },
                                             step: step, count: hits.count) else { return }
        cursor = hits[next].id
    }
}

struct ExplorerStatusMark: View {
    let status: GitStatusKind
    var spelledOut = false

    var body: some View {
        Text(spelledOut ? status.label.capitalized : status.letter)
            .font(.system(size: spelledOut ? 10 : 11, weight: .semibold))
            .foregroundStyle(colour)
            .accessibilityLabel(status.label)
            .appTooltip(status.label.capitalized)
    }

    private var colour: Color {
        switch status {
        case .added, .untracked: Theme.addition
        case .deleted, .conflicted: Theme.deletion
        case .modified, .renamed: Theme.attention
        }
    }
}

struct ExplorerIcon: View {
    let symbol: String
    let label: String
    var selected = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? Theme.accent : Theme.secondaryText)
                .frame(width: 28, height: 28)
                .background(selected ? Theme.field : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverFill(cornerRadius: 6)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .appTooltip(label)
    }
}
