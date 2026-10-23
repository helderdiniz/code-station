import AppKit
import SwiftUI

// Every file in a session's folder, as a tree with the file itself beside it. Changes only
// covers what git has something to say about; this is the whole working tree, which is
// what you want when the agent names a file you have never opened.
//
// A text file opens straight into an editor: there is no read mode to leave first, and
// nothing is written until Save. The tree itself can create, copy, paste, rename, drag to
// move and move items to the Trash.
// Says that a pane with a find of its own, a file or the chat, has taken Cmd+F. It travels
// up to the window so the sidebar can stop naming that stroke as the way into its own
// filter while the pane answers for it.
struct PaneFindShortcutKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

// A file another pane wants shown, with the line to land on when it names one.
struct ExplorerReveal: Equatable {
    let path: String
    let line: Int?
}

// One of the header's actions, asked for by a header that lives outside the pane.
enum ExplorerCommand {
    case findFile
    case findInFiles
    case newFile
    case newFolder
    case refresh
}

struct ExplorerView: View {
    let root: String
    // Taken and cleared once the file is shown, so coming back to the pane later
    // finds it where it was left rather than back on this file.
    var reveal: Binding<ExplorerReveal?> = .constant(nil)

    // Commands from the session header are taken and cleared once done, like `reveal`.
    var command: Binding<ExplorerCommand?>?
    private let sharedShowHidden: Binding<Bool>?

    var repositories: [ChangesRepository] = []
    var designFilesRoot: String?
    @Binding var collapsedProjects: Set<String>
    var selectRoot: (String) -> Void = { _ in }
    // The project row the keyboard is on. The keyboard lands on a file by selecting it,
    // so with this nil the cursor sits on the selected file.
    @State private var projectCursor: String?
    // A click already highlights the row it picks, so the cursor ring only shows while
    // the keyboard is driving the tree.
    @State private var treeCursorVisible = false

    init(root: String, reveal: Binding<ExplorerReveal?> = .constant(nil),
         command: Binding<ExplorerCommand?>? = nil, showHidden: Binding<Bool>? = nil,
         repositories: [ChangesRepository] = [], designFilesRoot: String? = nil,
         collapsedProjects: Binding<Set<String>> = .constant([]),
         selectRoot: @escaping (String) -> Void = { _ in }) {
        self.root = root
        self.reveal = reveal
        self.command = command
        self.sharedShowHidden = showHidden
        self.repositories = repositories
        self.designFilesRoot = designFilesRoot
        self._collapsedProjects = collapsedProjects
        self.selectRoot = selectRoot
    }

    private var projectRoots: [ChangesRepository] {
        repositories.isEmpty ? [ChangesRepository(root: root, name: rootURL.lastPathComponent)] : repositories
    }

    @Environment(DialogPresenter.self) private var dialogs
    @Environment(ExplorerMemory.self) private var memory

    // Children are kept per folder rather than as a nested tree, so a folder can be read
    // the moment it is opened and the rows on screen stay a flat list.
    @State private var children: [String: [FileNode]] = [:]
    @State private var expanded: Set<String> = []
    @State private var loadingFolders: Set<String> = []
    @State private var selected: FileNode?
    // The line the open file should scroll to, when it was opened from a link to one.
    @State private var lineToReveal: Int?
    @State private var preview: FilePreview?
    @State private var loadingPreview = false
    @State private var previewGeneration = 0
    @State private var renderingMarkdown = false
    @State private var ownShowHidden = true
    @State private var language: CodeLanguage?
    @State private var pastingFiles = false
    @State private var treeWidth = ExplorerSplitLayout.defaultTreeWidth
    @State private var documents = ExplorerDocuments()
    @State private var navigator = ExplorerNavigator()
    @State private var statusRevision = 0
    @State private var folderErrors: [String: String] = [:]
    @State private var focusEditor = false
    @State private var narrowNavigator = false
    @State private var detailsPresented = false
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var treeFocused: Bool
    // The row being renamed, by path. The name is edited in place, the way Finder does it.
    @State private var renaming: String?
    @State private var renameDraft = ""
    @State private var renameSelection: TextSelection?
    @State private var renameCancelled = false
    @FocusState private var renameFocused: Bool
    // What a drag is over, and the folder a drop there would land in. A file row hands the
    // drop to the folder it sits in, so that folder is what lights up.
    @State private var dropHover: DropHover?
    // The folder the pane holds now. It trails `root` for a moment when the session
    // changes, which is what lets the old folder be remembered before the new one opens.
    @State private var openedRoot: String?

    // The text as loaded sits next to the draft, so "anything to save" and "anything to
    // lose" are both one comparison.
    @State private var draft = ""
    @State private var original = ""
    @State private var saving = false
    // When the file was last written at the moment it was read. An agent works in the same
    // folder, so a pane left open on a file it has since rewritten would save over it.
    @State private var loadedAt: Date?

    @State private var findPresented = false
    // Both of the strokes a person tries for find. Cmd+F searches whatever is being read
    // on a Mac, and with a file open that is the file rather than the sidebar's filter.
    // They are caught with monitors because a SwiftUI shortcut is only offered the stroke
    // after the window's own shortcuts have had it, and the sidebar's filter takes Cmd+F.
    @State private var findMonitor = WindowKeyMonitor(.control, "f")
    @State private var commandFindMonitor = WindowKeyMonitor(.command, "f")
    @State private var findQuery = ""
    @State private var findResult = FileFindResult()
    @State private var findSelection = 0
    @FocusState private var findFocused: Bool
    // Cmd+H hides the app on a Mac, so find in files takes Ctrl+H, next to Ctrl+F.
    @State private var findInFilesMonitor = WindowKeyMonitor(.control, "h")
    @State private var escapeMonitor = WindowKeyMonitor([], "\u{1b}")
    // The query marked on the line a find in files result opened at. It goes once the
    // text is edited, since the marks would no longer sit on the words they were for.
    @State private var revealedMatches: [NSRange] = []

    private var rootURL: URL { URL(fileURLWithPath: root) }

    private var showHiddenBinding: Binding<Bool> { sharedShowHidden ?? $ownShowHidden }

    private var showHidden: Bool {
        get { showHiddenBinding.wrappedValue }
        nonmutating set { showHiddenBinding.wrappedValue = newValue }
    }

    var body: some View {
        GeometryReader { geometry in
            let sideBySide = geometry.size.width >= ExplorerSplitLayout.minimumSplitWidth
            let showsTree = !focusEditor && (sideBySide || selected == nil || narrowNavigator)
            let width = sideBySide
                ? ExplorerSplitLayout.treeWidth(treeWidth, availableWidth: geometry.size.width, keepsDetailMinimum: true)
                : min(ExplorerSplitLayout.defaultTreeWidth, geometry.size.width)

            HStack(spacing: 0) {
                if showsTree && sideBySide {
                    tree.frame(width: width).clipped()
                    Rectangle().fill(Theme.hairline).frame(width: ExplorerSplitLayout.dividerWidth)
                }
                detail(navigatorVisible: showsTree)
                    .frame(width: max(0, geometry.size.width - (showsTree && sideBySide ? width + ExplorerSplitLayout.dividerWidth : 0)))
                    .clipped()
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .overlay(alignment: .leading) {
                if showsTree && sideBySide {
                    splitHandle(treeWidth: width, availableWidth: geometry.size.width)
                        .offset(x: width + (ExplorerSplitLayout.dividerWidth - ExplorerSplitLayout.handleWidth) / 2)
                }
                if showsTree && !sideBySide {
                    ZStack(alignment: .leading) {
                        Theme.background.opacity(0.6).onTapGesture { narrowNavigator = false; focusEditor = true }
                        tree.frame(width: width).background(Theme.background)
                            .overlay(alignment: .trailing) { Rectangle().fill(Theme.border).frame(width: 1) }
                    }
                }
            }
        }
        .background(Theme.background)
        .background(ExplorerSearchShortcut { showFileSearch() })
        .background(ExplorerFileShortcuts(
            enabled: treeFocused && !searchFocused && !navigator.isFiltering && projectCursor == nil && dialogs.current == nil && !pastingFiles,
            onCopy: copySelected,
            onPaste: { pasteFiles(at: selected) },
            onTrash: trashSelected,
            onRename: renameSelected))
        .background(WindowAnchor(monitor: findMonitor))
        .background(WindowAnchor(monitor: commandFindMonitor))
        .background(WindowAnchor(monitor: findInFilesMonitor))
        .background(WindowAnchor(monitor: escapeMonitor))
        .onAppear {
            escapeMonitor.start {
                guard dialogs.current == nil, renaming == nil else { return false }
                if detailsPresented { detailsPresented = false; return true }
                if findPresented { closeFind(); return true }
                if searchFocused { navigator.query = ""; searchFocused = false; treeFocused = true; return true }
                if focusEditor || narrowNavigator { focusEditor = false; narrowNavigator = false; return true }
                return false
            }
        }
        .preference(key: PaneFindShortcutKey.self, value: canFind)
        .onChange(of: canFind, initial: true) { _, canFind in
            for monitor in findMonitors {
                guard canFind else { monitor.stop(); continue }
                monitor.start {
                    showFind()
                    return true
                }
            }
        }
        .onChange(of: dialogs.current == nil, initial: true) { _, free in
            guard free else { findInFilesMonitor.stop(); return }
            findInFilesMonitor.start {
                showFindInFiles()
                return true
            }
        }
        .onDisappear {
            findMonitors.forEach { $0.stop() }
            findInFilesMonitor.stop()
            escapeMonitor.stop()
            rememberPlace()
        }
        .onChange(of: findQuery) {
            findSelection = 0
            refreshFind()
        }
        // Typing moves every match after the caret, so the results are only right for the
        // text as it stands now.
        .onChange(of: draft) {
            if findPresented { refreshFind() }
            if draft != original { revealedMatches = [] }
        }
        .onChange(of: showHidden) { Task { await reopenFolders() } }
        .task(id: searchRequest) {
            await navigator.search(root: root, includeHidden: showHidden, pinned: documents.pinned)
        }
        .task(id: projectRoots.map(\.root) + [String(statusRevision)]) {
            await navigator.refreshStatus(roots: projectRoots.map(\.root))
        }
        .onChange(of: command?.wrappedValue) { _, requested in
            guard let requested else { return }
            command?.wrappedValue = nil
            perform(requested)
        }
        .task(id: root) { await openRoot() }
        .onChange(of: reveal.wrappedValue) {
            if openedRoot == root { Task { await showRequestedFile() } }
        }
    }

    private func splitHandle(treeWidth: CGFloat, availableWidth: CGFloat) -> some View {
        WorkspaceSplitHandle(width: $treeWidth, displayedWidth: treeWidth, availableWidth: availableWidth,
                             label: "Resize file navigator", keyboardResizing: true, keepsDetailMinimum: true)
    }

    private struct SearchRequest: Equatable {
        let root: String
        let query: String
        let mode: ExplorerSearchMode
        let filter: ExplorerFileFilter
        let hidden: Bool
        let pins: [String]
        let statuses: [String: GitStatusKind]
        let revision: Int
    }

    private var searchRequest: SearchRequest {
        SearchRequest(root: root, query: navigator.query, mode: navigator.mode,
                      filter: navigator.filter, hidden: showHidden, pins: documents.pinned.map(\.path),
                      statuses: navigator.statuses, revision: navigator.revision)
    }

    private func perform(_ command: ExplorerCommand) {
        switch command {
        case .findFile: showFileSearch()
        case .findInFiles: showFindInFiles()
        case .newFile: create(folder: false, in: newItemDestination())
        case .newFolder: create(folder: true, in: newItemDestination())
        case .refresh: Task { await reopenFolders() }
        }
    }

    private var navigatorHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Files").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 4)
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                    Text("New")
                }
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 11).frame(height: 29)
                .background(Theme.card, in: Capsule())
                .overlay(Capsule().stroke(Theme.border))
                .contentShape(Capsule())
                .appMenu {
                    [.item("New file", icon: "doc.badge.plus") { perform(.newFile) },
                     .item("New folder", icon: "folder.badge.plus") { perform(.newFolder) }]
                }
                .accessibilityLabel("New file or folder")
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28).contentShape(Rectangle())
                    .appMenu { navigatorOptions }
                    .accessibilityLabel("Explorer options")
                    .appTooltip("Explorer options")
            }
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField(navigator.mode == .names ? "Find a file…" : "Find in file contents…", text: $navigator.query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { openSearchHit() }
                    .onMoveCommand { direction in
                        if direction == .up { navigator.moveCursor(by: -1) }
                        if direction == .down { navigator.moveCursor(by: 1) }
                    }
                    .onExitCommand { navigator.query = ""; searchFocused = false; treeFocused = true }
                    .accessibilityLabel(navigator.mode == .names ? "Find a file" : "Find in file contents")
                if !navigator.query.isEmpty {
                    ExplorerIcon(symbol: "xmark", label: "Clear search") { navigator.query = "" }
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 9).frame(height: 34)
            .fieldSurface(cornerRadius: 8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(searchFocused ? Theme.accent : .clear))
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(ExplorerSearchMode.allCases, id: \.self) { mode in
                        ChoicePill(title: mode.rawValue, selected: navigator.mode == mode) { navigator.mode = mode }
                            .accessibilityAddTraits(navigator.mode == mode ? .isSelected : [])
                    }
                }
            }.scrollIndicators(.hidden)
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(ExplorerFileFilter.allCases, id: \.self) { filter in
                        ChoicePill(title: filter == .changed ? "Changed \(changedFileCount)" : filter.rawValue,
                                   selected: navigator.filter == filter) { navigator.filter = filter }
                            .accessibilityAddTraits(navigator.filter == filter ? .isSelected : [])
                    }
                }
            }.scrollIndicators(.hidden)
        }
        .padding(12)
    }

    private var navigatorOptions: [MenuEntry] {
        [.item(showHidden ? "Hide hidden files" : "Show hidden files", icon: "eye", checked: showHidden) { showHidden.toggle() },
         .item("Collapse folders", icon: "rectangle.compress.vertical") { expanded = [] },
         .item("Refresh files", icon: "arrow.clockwise") { perform(.refresh) },
         .separator,
         .item("Find in file contents", detail: "Ctrl+H") { showFindInFiles() }]
    }

    private var changedFileCount: Int {
        navigator.statuses.keys.filter { $0.pathRelative(to: root) != nil }.count
    }

    private var navigatorFooter: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder").accessibilityHidden(true)
            Text("In \(rootURL.lastPathComponent)").lineLimit(1).truncationMode(.middle)
                .appTooltip("Search and filters use \(root)")
            Spacer(minLength: 0)
        }
        .font(.system(size: 10)).foregroundStyle(.secondary)
        .padding(12)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 7).padding(.vertical, 9)
    }

    private func openSearchHit() {
        guard let hit = navigator.hits.first(where: { $0.id == navigator.cursor }) else { return }
        revealAndSelect(hit.file, line: hit.line?.number, marking: hit.line == nil ? nil : navigator.query)
    }

    private var searchResults: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    if navigator.loading {
                        HStack { ProgressView().controlSize(.small); Text("Reading files…").font(.system(size: 12)) }.padding(12)
                    } else if navigator.hits.isEmpty {
                        VStack(spacing: 10) {
                            Text(navigator.filter == .pinned && navigator.query.isBlank ? "No pinned files" : "No matching files")
                                .font(.system(size: 13, weight: .semibold))
                            Text(navigator.filter == .pinned ? "Pin a file from its action row or menu." : "Try a shorter search or show all files.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                            InlineLink(title: "Show all files") { navigator.query = ""; navigator.filter = .all }
                        }.padding(18).frame(maxWidth: .infinity)
                    } else {
                        sectionLabel(counted(navigator.hits.count, "result"))
                        ForEach(navigator.hits) { hit in
                            Button {
                                navigator.cursor = hit.id
                                openSearchHit()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Image(systemName: icon(hit.file)).foregroundStyle(Theme.accent)
                                        Text(hit.file.name).lineLimit(1).truncationMode(.middle)
                                        Spacer(minLength: 0)
                                        if let status = navigator.statuses[hit.file.path] { ExplorerStatusMark(status: status) }
                                    }.font(.system(size: 12))
                                    Text(relativePath(hit.file)).font(.mono(10)).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.head)
                                    if let line = hit.line {
                                        (Text("\(line.number): ") + Text(line.highlighted))
                                            .font(.mono(10)).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }
                                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                .background(selected?.path == hit.file.path ? Theme.accent.opacity(0.1) : .clear,
                                            in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6)
                                    .stroke(navigator.cursor == hit.id ? Theme.accent : .clear))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).hoverFill(cornerRadius: 6)
                            .accessibilityAddTraits(selected?.path == hit.file.path ? .isSelected : [])
                            .id(hit.id)
                        }
                        if navigator.hasMore {
                            InlineLink(title: navigator.loadingMore ? "Finding more…" : "Show more matches") {
                                Task { await navigator.loadMore() }
                            }.disabled(navigator.loadingMore).padding(8)
                        }
                    }
                    if navigator.limited {
                        Text(navigator.mode == .names ? "Showing the first 200 files. Refine your search." : "Some files exceed the search size limit.")
                            .font(.system(size: 11)).foregroundStyle(.secondary).padding(8)
                    }
                    if let note = navigator.statusNote, navigator.filter == .changed {
                        Text(note).font(.system(size: 11)).foregroundStyle(Theme.attention).padding(8)
                    }
                }.padding(8)
            }
            .onChange(of: navigator.cursor) { _, cursor in if let cursor { proxy.scrollTo(cursor) } }
        }
    }

    // MARK: - Tree

    // One visible row: the entry and how deep it sits. Folders that are shut contribute
    // nothing, so this is only ever as long as what is actually open.
    private struct DropHover: Equatable {
        let key: String
        let folder: String
    }

    private typealias Row = ExplorerTreeRow

    private func rows(in directory: String) -> [Row] {
        Row.rows(in: directory, children: children, expanded: expanded, depth: repositories.isEmpty ? 0 : 1)
    }

    private var rows: [Row] {
        projectRoots.filter { !collapsedProjects.contains($0.root) }.flatMap { rows(in: $0.root) }
    }

    private func projectRow(_ project: ChangesRepository) -> some View {
        WorkspaceProjectRow(name: project.name,
                            detail: children[project.root].map { counted($0.count, "item") },
                            selected: project.root == root,
                            showsCursor: treeFocused && treeCursorVisible && projectCursor == project.root,
                            hasChildren: children[project.root]?.isEmpty == false,
                            collapsed: collapsedProjects.contains(project.root)) {
            if !collapsedProjects.insert(project.root).inserted { collapsedProjects.remove(project.root) }
        } select: {
            projectCursor = project.root
            treeCursorVisible = false
            treeFocused = true
            selectRoot(project.root)
        }
    }

    @ViewBuilder private var tree: some View {
        VStack(spacing: 0) {
            navigatorHeader
            if !repositories.isEmpty && !navigator.isFiltering {
                HStack {
                    Text("Workspace").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(counted(projectRoots.filter { $0.root != designFilesRoot }.count, "project"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .headerBand(height: Theme.headerHeight)
            }
            if let error = folderErrors[root] {
                VStack(spacing: 10) {
                    PaneMessage(icon: "exclamationmark.triangle", title: "Folder unavailable", detail: error)
                    ActionButton(title: "Try again", tone: .outlined, height: 28, size: 12) { Task { await reopenFolders() } }
                }.padding(12)
            } else if navigator.isFiltering {
                searchResults
            } else if loadingFolders.contains(root) && children[root] == nil {
                ProgressView("Reading files…").controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if repositories.isEmpty && children[root]?.isEmpty == true {
                PaneMessage(icon: "folder", title: "Empty folder", detail: showHidden ? "" : "Hidden files are off.")
            }
            if !navigator.isFiltering && folderErrors[root] == nil && (!repositories.isEmpty || children[root]?.isEmpty != true) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: repositories.isEmpty ? 1 : 3) {
                            if !documents.pinned.isEmpty {
                                sectionLabel("Pinned")
                                ForEach(documents.pinned) { node in
                                    treeRow(Row(node: node, depth: 0)).id("pinned:" + node.path)
                                }
                            }
                            sectionLabel("Project files")
                            ForEach(projectRoots) { project in
                                if !repositories.isEmpty { projectRow(project).id(project.root) }
                                if !collapsedProjects.contains(project.root) {
                                    ForEach(rows(in: project.root)) { row in
                                        treeRow(row).id(row.id)
                                        if let error = folderErrors[row.node.path], expanded.contains(row.node.path) {
                                            Text(error).font(.system(size: 11)).foregroundStyle(Theme.attention).padding(8)
                                            InlineLink(title: "Try again") { Task { await load(row.node.path) } }
                                        }
                                    }
                                }
                            }
                        }.padding(repositories.isEmpty ? 8 : 10)
                    }
                    .onChange(of: selected?.path) {
                        if let path = selected?.path {
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { proxy.scrollTo(rows.contains(where: { $0.id == path }) ? path : "pinned:" + path, anchor: .center) }
                        }
                    }
                    .onChange(of: projectCursor) { _, path in
                        if let path { proxy.scrollTo(path) }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { navigatorFooter }
        .background(Theme.background)
        .overlay {
            if dropHover?.folder == root {
                RoundedRectangle(cornerRadius: 6).stroke(Theme.accent.opacity(0.65), lineWidth: 1.5)
                    .padding(2)
            }
        }
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            drop(urls, into: rootURL)
        } isTargeted: { hoverDrop(key: root, folder: root, $0) }
        .focusable()
        .focused($treeFocused)
        .onChange(of: treeFocused) { _, focused in
            if focused && !repositories.isEmpty && selected == nil && projectCursor == nil {
                projectCursor = root
            }
        }
        .focusEffectDisabled()
        .onMoveCommand(perform: moveTreeSelection)
        .onKeyPress(.return) {
            if navigator.isFiltering { openSearchHit(); return .handled }
            if let projectCursor { selectRoot(projectCursor); return .handled }
            if let selected, selected.isDirectory { toggle(selected); return .handled }
            return .ignored
        }
    }

    @ViewBuilder private func treeRow(_ row: Row) -> some View {
        if renaming == row.node.path {
            renameRow(row)
        } else {
            plainRow(row)
        }
    }

    private func plainRow(_ row: Row) -> some View {
        let node = row.node
        let isOpen = expanded.contains(node.path)
        let isSelected = selected?.path == node.path
        let isDropTarget = dropHover?.folder == node.path
        let folder = node.isDirectory ? node.url : node.url.deletingLastPathComponent()

        return Button {
            treeFocused = true
            projectCursor = nil
            treeCursorVisible = false
            requestSelect(node)
            if node.isDirectory { toggle(node) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .frame(width: 10)
                    .opacity(node.isDirectory ? 1 : 0)

                if loadingFolders.contains(node.path) {
                    ProgressView().controlSize(.mini).scaleEffect(0.6).frame(width: 14)
                } else {
                    Image(systemName: icon(node))
                        .font(.system(size: 11))
                        .foregroundStyle(node.isDirectory ? Theme.accent : .secondary)
                        .frame(width: 14)
                }

                Text(row.name)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 6)

                if !node.isDirectory {
                    if hasUnsavedEdit(node) {
                        Text("●").font(.system(size: 9)).foregroundStyle(Theme.attention).accessibilityLabel("Unsaved edits")
                    }
                    if isPinned(node) {
                        Image(systemName: "pin").font(.system(size: 10)).foregroundStyle(.secondary).accessibilityLabel("Pinned")
                    }
                    if let status = navigator.statuses[node.path] { ExplorerStatusMark(status: status) }
                }
            }
            .padding(.vertical, 6)
            .padding(.trailing, 8)
            .padding(.leading, CGFloat(row.depth) * 13 + 6)
            .surface(isDropTarget ? Theme.accent.opacity(0.12) : (isSelected ? Theme.accent.opacity(0.1) : .clear),
                     cornerRadius: 6,
                     border: isDropTarget ? Theme.accent.opacity(0.65) : (isSelected ? Theme.border : .clear))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected && treeFocused && treeCursorVisible && projectCursor == nil ? Theme.accent : .clear,
                            lineWidth: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverFill(cornerRadius: 6)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel(row.name)
        .accessibilityValue(node.isDirectory ? (isOpen ? "Expanded" : "Collapsed") : (navigator.statuses[node.path]?.label ?? "Unchanged"))
        .appTooltip(node.path)
        .draggable(node.url)
        .dropDestination(for: URL.self) { urls, _ in
            drop(urls, into: folder)
        } isTargeted: { hoverDrop(key: node.path, folder: folder.path, $0) }
        .appContextMenu {
            // Paste is only offered when the clipboard holds files, since the menu has no
            // way to show an item that is there but cannot be used.
            let paste: [MenuEntry] = Pasteboard.fileURLs().isEmpty || pastingFiles
                ? []
                : [.item("Paste", detail: "⌘V", action: { _ = pasteFiles(at: node) })]
            return [.item("New File") { create(folder: false, in: folder) },
                    .item("New Folder") { create(folder: true, in: folder) },
                    .separator,
                    .item("Copy", detail: "⌘C", action: { copy(node) })]
                + paste
                + (node.isDirectory ? [] : [.item(isPinned(node) ? "Unpin file" : "Pin file", icon: "pin") { togglePin(node) }])
                + [.item("Copy Path") { Pasteboard.copy(node.path) },
                   .separator,
                   .item("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) },
                   .item("Open with default app") { NSWorkspace.shared.open(node.url) },
                   .separator,
                   .item("Rename…", detail: "↩", action: { startRename(node) }),
                   .item("Move to Trash", kind: .destructive, detail: "⌘⌫",
                         action: { confirmTrash(node) })]
        }
    }

    // The same row with a field where the name was. Clicking away keeps the new name, the
    // way Finder does, and Escape is the only way to throw it away.
    private func renameRow(_ row: Row) -> some View {
        let node = row.node
        return HStack(spacing: 5) {
            Color.clear.frame(width: 10)
            Image(systemName: icon(node))
                .font(.system(size: 11))
                .foregroundStyle(node.isDirectory ? Theme.accent : .secondary)
                .frame(width: 14)
            TextField("Name", text: $renameDraft, selection: $renameSelection)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .fieldSurface(cornerRadius: 4)
                .focused($renameFocused)
                .onSubmit { commitRename(node) }
                .onExitCommand {
                    renameCancelled = true
                    endRename()
                }
                .onAppear { focusRenameField(node) }
                .onChange(of: renameFocused) { _, focused in
                    guard !focused, renaming == node.path, !renameCancelled else { return }
                    commitRename(node)
                }
        }
        .padding(.vertical, 2)
        .padding(.trailing, 8)
        .padding(.leading, CGFloat(row.depth) * 13 + 6)
    }

    private func icon(_ node: FileNode) -> String {
        // A link is drawn as a link whatever sits on the other end. What it points at is
        // spelled out in the header once it is picked, which is where there is room for it.
        if node.isLink { return "arrow.turn.down.right" }
        if node.isDirectory { return expanded.contains(node.path) ? "folder.fill" : "folder" }
        if FileTree.imageKinds.contains(node.kind) { return "photo" }
        return switch node.kind {
        case "swift", "kt", "java", "rs", "go", "py", "rb", "js", "ts", "c", "h", "cpp": "chevron.left.forwardslash.chevron.right"
        case "json", "yml", "yaml", "toml", "xml", "plist", "lock": "curlybraces"
        case "md", "markdown", "txt", "rtf": "doc.text"
        case "sh", "zsh", "bash", "fish": "terminal"
        case "pdf": "doc.richtext"
        case "zip", "gz", "tar", "jar": "shippingbox"
        default: "doc"
        }
    }

    // MARK: - The file

    private func detail(navigatorVisible: Bool) -> some View {
        GeometryReader { geometry in
            let inlineDetails = ExplorerSplitLayout.showsInlineDetails(availableWidth: geometry.size.width)
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    editorTabs(navigatorVisible: navigatorVisible)
                    if let node = selected {
                        breadcrumbs(node)
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) { fileTitle(node); Spacer(minLength: 8); fileActions(node) }
                            VStack(alignment: .leading, spacing: 8) {
                                fileTitle(node)
                                HStack { Spacer(minLength: 0); fileActions(node) }
                            }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        if findPresented { findBar }
                        fileBody(node)
                        if isEditable { editStatus }
                    } else {
                        PaneMessage(icon: "sidebar.left", title: "Pick a file",
                                    detail: "Find a file above, or tap Shift twice to search.")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if detailsPresented, let node = selected, inlineDetails {
                    fileDetails(node).frame(width: ExplorerSplitLayout.detailsWidth)
                }
            }
            .overlay(alignment: .trailing) {
                if detailsPresented, let node = selected, !inlineDetails {
                    ZStack(alignment: .trailing) {
                        Color.black.opacity(0.12).onTapGesture { detailsPresented = false }
                        fileDetails(node).frame(width: min(ExplorerSplitLayout.detailsWidth, geometry.size.width))
                            .shadow(color: .black.opacity(0.08), radius: 12, x: -4)
                    }
                }
            }
        }
        .background(Theme.card)
    }

    private func editorTabs(navigatorVisible: Bool) -> some View {
        HStack(spacing: 4) {
            ExplorerIcon(symbol: "sidebar.left", label: "Toggle file navigator") {
                focusEditor = navigatorVisible
                narrowNavigator = !navigatorVisible
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 2) {
                        ForEach(documents.tabs) { node in
                            HStack(spacing: 5) {
                                Button { requestSelect(node) } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: icon(node)).foregroundStyle(Theme.accent)
                                        Text(node.name).lineLimit(1).truncationMode(.middle)
                                        if hasUnsavedEdit(node) {
                                            Text("●").foregroundStyle(Theme.attention).accessibilityLabel("Unsaved edits")
                                        } else if isPinned(node) {
                                            Image(systemName: "pin").foregroundStyle(.secondary).accessibilityLabel("Pinned")
                                        }
                                    }
                                    .font(.system(size: 11, weight: node.path == selected?.path ? .semibold : .regular))
                                    .padding(.leading, 10).frame(height: 40).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(node.path == selected?.path ? .isSelected : [])
                                ExplorerIcon(symbol: "xmark", label: "Close \(node.name)") { closeTab(node) }
                            }
                            .frame(maxWidth: 230)
                            .background(node.path == selected?.path ? Theme.card : .clear)
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(node.path == selected?.path ? Theme.accent : .clear).frame(height: 2)
                            }
                            .appTooltip(relativePath(node))
                            .id(node.path)
                        }
                    }
                }.scrollIndicators(.hidden)
                .onChange(of: selected?.path) { _, path in if let path { proxy.scrollTo(path) } }
            }
            ExplorerIcon(symbol: focusEditor ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                         label: focusEditor ? "Exit focus mode" : "Focus editor", selected: focusEditor) {
                focusEditor.toggle()
                narrowNavigator = false
            }
        }
        .padding(.horizontal, 6).frame(height: 42)
        .background(Theme.sidebar)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private func breadcrumbs(_ node: FileNode) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 7) {
                let parts = relativePath(node).split(separator: "/").map(String.init)
                ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                    if index > 0 { Image(systemName: "chevron.right").font(.system(size: 8)).accessibilityHidden(true) }
                    Text(part).foregroundStyle(index == parts.count - 1 ? Color.primary : .secondary)
                }
                if let target = node.linkDestination { Text("→ \(target)").foregroundStyle(.secondary) }
            }
            .font(.system(size: 11)).padding(.horizontal, 14).frame(height: 36)
        }
        .scrollIndicators(.hidden)
        .accessibilityElement(children: .combine)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private func fileTitle(_ node: FileNode) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon(node)).foregroundStyle(Theme.accent)
            Text(node.name).font(.serif(16, .semibold)).lineLimit(1).truncationMode(.middle)
            if let status = navigator.statuses[node.path] {
                ExplorerStatusMark(status: status, spelledOut: true)
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(Theme.field, in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func fileActions(_ node: FileNode) -> some View {
        HStack(spacing: 5) {
            if isEditable { saveButtons(node) }
            ExplorerIcon(symbol: "magnifyingglass", label: "Find in file (Cmd+F or Ctrl+F)", action: showFind)
                .disabled(!canFind)
            if !node.isDirectory {
                ExplorerIcon(symbol: "pin", label: isPinned(node) ? "Unpin file" : "Pin file", selected: isPinned(node)) { togglePin(node) }
            }
            ExplorerIcon(symbol: "info.circle", label: "File details", selected: detailsPresented) { detailsPresented.toggle() }
            Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28).contentShape(Rectangle())
                .appMenu {
                    var items: [MenuEntry] = []
                    if node.supportsMarkdownPreview {
                        items.append(.item(renderingMarkdown ? "Edit Markdown" : "Preview Markdown") {
                            resetFind(); renderingMarkdown.toggle()
                        })
                    }
                    return items + [.item("Copy path") { Pasteboard.copy(node.path) },
                                    .item("Open externally") { NSWorkspace.shared.open(node.url) },
                                    .item("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }]
                }
                .accessibilityLabel("File actions")
                .appTooltip("File actions")
        }.fixedSize()
    }

    private var editStatus: some View {
        HStack(spacing: 6) {
            Image(systemName: dirty ? "info.circle" : "checkmark.circle").accessibilityHidden(true)
            Text(dirty ? "Your edits are kept here until you save." : "Changes are written only when you save.")
                .lineLimit(2)
            Spacer(minLength: 0)
            if saving { ProgressView().controlSize(.mini) }
            Text("⌘ S").font(.mono(10))
        }
        .font(.system(size: 11)).foregroundStyle(Theme.accent)
        .padding(9).background(Theme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        .padding(12)
    }

    private func fileDetails(_ node: FileNode) -> some View {
        let current = children[node.url.deletingLastPathComponent().path]?.first { $0.path == node.path } ?? node
        return ExplorerFileDetails(node: current, path: relativePath(node), status: navigator.statuses[node.path],
                            text: isEditable ? draft : nil) { detailsPresented = false }
    }

    private func hasUnsavedEdit(_ node: FileNode) -> Bool {
        selected?.path == node.path ? dirty : documents.edits[node.path] != nil
    }

    private func isPinned(_ node: FileNode) -> Bool {
        let owner = projectRoots.filter { isInside(node.path, $0.root) }.max { $0.root.count < $1.root.count }?.root ?? root
        let pins = owner == root ? documents.pinned : memory.place(for: owner)?.documents.pinned ?? []
        return pins.contains { $0.path == node.path }
    }

    private func togglePin(_ node: FileNode) {
        let owner = projectRoots.filter { isInside(node.path, $0.root) }.max { $0.root.count < $1.root.count }?.root ?? root
        if owner == root {
            documents.togglePin(node)
            rememberPlace()
        } else {
            var place = memory.place(for: owner) ?? ExplorerMemory.Place()
            place.documents.togglePin(node)
            memory.remember(place, for: owner)
        }
    }

    private func closeTab(_ node: FileNode) {
        let close = {
            documents.close(node.path)
            if selected?.path == node.path {
                if let next = documents.tabs.last { select(next) }
                else { selected = nil; preview = nil; draft = ""; original = ""; resetFind() }
            }
            rememberPlace()
        }
        if hasUnsavedEdit(node) {
            var dialog = Dialog.confirm("Close unsaved file?", message: "Edits to \(node.name) have not been saved.",
                                        action: "Discard and close", cancel: "Keep editing", handler: close)
            dialog.isModal = true
            dialogs.show(dialog)
        } else { close() }
    }

    @ViewBuilder private func fileBody(_ node: FileNode) -> some View {
        switch preview {
        case .text, .empty:
            if renderingMarkdown, node.supportsMarkdownPreview {
                ScrollView {
                    MarkdownDocumentView(text: draft,
                                         basePath: node.url.deletingLastPathComponent().path,
                                         textScale: 1)
                        .padding(28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Theme.background)
            } else {
                CodeEditorView(documentID: node.path,
                               text: $draft,
                               language: language,
                               matches: findPresented ? findResult.matches : revealedMatches,
                               currentMatch: findPresented ? currentFindMatch : nil,
                               findQuery: findQuery,
                               revealLine: lineToReveal,
                               onFind: showFind)
            }
        case .image(let data):
            if let image = NSImage(data: data) {
                VStack(spacing: 10) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                    Text("\(Int(image.size.width)) × \(Int(image.size.height)) · \(node.size.formatted(.byteCount(style: .file)))")
                        .font(.mono(11))
                        .foregroundStyle(.secondary)
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PaneMessage(icon: "photo", title: "Cannot draw this image",
                            detail: node.size.formatted(.byteCount(style: .file)))
            }
        case .binary(let size):
            PaneMessage(icon: "doc.zipper", title: "Binary file",
                        detail: "\(size.formatted(.byteCount(style: .file))) of data this app cannot show as text.")
        case .tooLarge(let size):
            PaneMessage(icon: "doc.badge.ellipsis", title: "Too big to open",
                        detail: "\(size.formatted(.byteCount(style: .file))). Open it in an editor instead.")
        case .unreadable(let reason):
            VStack(spacing: 12) {
                PaneMessage(icon: "exclamationmark.triangle",
                            title: node.isLink ? "Could not follow this link" : "Could not read this file", detail: reason)
                ActionButton(title: "Try again", tone: .outlined, height: 28, size: 12) { select(node) }
            }.padding(20)
        case nil:
            if node.isDirectory {
                PaneMessage(icon: "folder", title: "Folder selected",
                            detail: "Use the left and right arrow keys to close and open folders.")
            } else {
                ProgressView("Reading file…").controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Editing

    // Only what reads as text can be typed into. Images, binaries and files past the size
    // limit stay look-but-do-not-touch, and an empty file counts as text.
    private var isEditable: Bool {
        switch preview {
        case .text, .empty: true
        default: false
        }
    }

    private var dirty: Bool { isEditable && draft != original }

    // MARK: - Find

    private var currentFindMatch: Int? {
        findResult.matches.indices.contains(findSelection) ? findSelection : nil
    }

    private var findBar: some View {
        FindBar(placeholder: "Find in file",
                query: $findQuery,
                summary: FindSummary.text(query: findQuery,
                                          matchCount: findResult.matches.count,
                                          hasMore: findResult.hasMore,
                                          selection: findSelection),
                hasMatches: !findResult.matches.isEmpty,
                focused: $findFocused,
                move: { moveFind(by: $0) },
                close: closeFind)
    }

    // A file worth searching is open and nothing is in front of it. While this is false
    // both strokes are left alone, so Cmd+F still opens the sidebar's filter.
    private var canFind: Bool {
        isEditable && !renderingMarkdown && dialogs.current == nil
    }

    private var findMonitors: [WindowKeyMonitor] { [findMonitor, commandFindMonitor] }

    private func showFind() {
        guard canFind else { return }
        findPresented = true
        refreshFind()
        $findFocused.request()
    }

    private func closeFind() {
        findPresented = false
        findFocused = false
    }

    private func refreshFind() {
        findResult = FileFind.search(findQuery, in: draft)
        // The selection is kept rather than reset: typing shifts the matches around it,
        // and being thrown back to the first one on every keystroke reads as a bug.
        findSelection = min(findSelection, max(0, findResult.matches.count - 1))
    }

    private func moveFind(by offset: Int) {
        let count = findResult.matches.count
        guard count > 0 else { return }
        findSelection = (findSelection + offset + count) % count
    }

    private func resetFind() {
        findPresented = false
        findFocused = false
        findQuery = ""
        findResult = FileFindResult()
        findSelection = 0
        revealedMatches = []
    }

    // MARK: - File search

    private func showFileSearch() {
        guard dialogs.current == nil else { return }
        focusEditor = false
        narrowNavigator = true
        navigator.mode = .names
        $searchFocused.request()
    }

    private func showFindInFiles() {
        guard dialogs.current == nil else { return }
        focusEditor = false
        narrowNavigator = true
        navigator.mode = .contents
        $searchFocused.request()
    }

    private func revealAndSelect(_ node: FileNode, line: Int? = nil, marking query: String? = nil) {
        Task {
            for path in FileTree.ancestorDirectories(of: node.url, beneath: rootURL) {
                expanded.insert(path)
                if children[path] == nil { await load(path) }
            }
            requestSelect(node, line: line, marking: query)
            narrowNavigator = false
            treeFocused = true
        }
    }

    private func saveButtons(_ node: FileNode) -> some View {
        HStack(spacing: 8) {
            ActionButton(title: "Revert", tone: .outlined, height: 26, size: 12) { revert() }
                .disabled(!dirty || saving)
            ActionButton(title: "Save", tone: .green, height: 26, size: 12,
                         keyboardShortcut: KeyboardShortcut("s", modifiers: .command)) {
                save(node)
            }
            .disabled(!dirty || saving)
        }
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
    }

    private func relativePath(_ node: FileNode) -> String {
        node.path.pathRelative(to: root) ?? node.path
    }

    private func copySelected() -> Bool {
        guard let selected else { return false }
        copy(selected)
        return true
    }

    private func copy(_ node: FileNode) {
        Pasteboard.copy(node.url)
    }

    // Into the given item when it is a folder, beside it when it is a file, and at the top
    // with nothing given.
    private func pasteFiles(at node: FileNode?) -> Bool {
        let sources = Pasteboard.fileURLs()
        guard !sources.isEmpty else { return false }

        let destination = pasteDestination(for: sources, at: node)
        let rootAtStart = root
        pastingFiles = true
        Task {
            let result = await FileTree.copy(sources, into: destination)
            pastingFiles = false
            guard root == rootAtStart else { return }

            if !result.copied.isEmpty {
                if destination.path != root { expanded.insert(destination.path) }
                await load(destination.path)
                statusRevision += 1
            }
            guard !result.failures.isEmpty else { return }
            dialogs.show(.notice(
                result.failures.count == 1 ? "Could not paste the item" : "Could not paste some items",
                message: result.failures.map { "\($0.name): \($0.message)" }.joined(separator: "\n")))
        }
        return true
    }

    private func trashSelected() -> Bool {
        guard let selected else { return false }
        confirmTrash(selected)
        return true
    }

    private func confirmTrash(_ node: FileNode) {
        let rememberedEdit = isInside(node.path, root) ? nil : memory.unsavedEdit(inside: node.path)
        let losesEdits = (dirty && selected.map { contains(node, $0.path) } == true)
            || documents.edits.keys.contains { contains(node, $0) } || rememberedEdit != nil
        var rows: [Dialog.Impact.Row] = [.init(title: node.name,
                                             detail: node.isDirectory ? "The folder and its contents move to the Trash." : "The file moves to the Trash.")]
        if losesEdits {
            rows.append(.init(title: "Unsaved edits",
                              detail: node.isDirectory ? "Unsaved edits in this folder are lost." : "Edits to \(node.name) are lost."))
        }
        rows.append(.init(title: node.isDirectory ? "Folder can be restored" : "File can be restored",
                          detail: "Put it back from the Trash in Finder.", kept: true))
        let owner = projectRoots.filter { isInside(node.path, $0.root) }.max { $0.root.count < $1.root.count }
        dialogs.show(.impact("Move \(node.name) to the Trash?", subject: .init(name: owner?.name ?? rootURL.lastPathComponent), rows: rows,
                             warning: losesEdits ? "Unsaved edits cannot be restored from the Trash." : nil,
                             action: "Move to Trash") { trash(node) })
    }

    private func trash(_ node: FileNode) {
        let rootAtStart = root
        Task {
            if let failure = await FileTree.trash(node.url) {
                dialogs.show(.notice("Could not move \(node.name) to the Trash", message: failure))
                return
            }
            guard root == rootAtStart else { return }

            memory.removed(node.path)
            documents.removed(node.path)
            expanded = expanded.filter { !contains(node, $0) }
            children = children.filter { !contains(node, $0.key) }
            if let selected, contains(node, selected.path) {
                resetFind()
                self.selected = nil
                preview = nil
                loadingPreview = false
                renderingMarkdown = false
                language = nil
                draft = ""
                original = ""
                loadedAt = nil
            }
            await load(node.url.deletingLastPathComponent().path)
            statusRevision += 1
        }
    }

    // Next to what is selected: inside it when it is a folder, beside it when it is a file.
    private func newItemDestination() -> URL {
        guard let selected else { return rootURL }
        return selected.isDirectory ? selected.url : selected.url.deletingLastPathComponent()
    }

    private func create(folder: Bool, in directory: URL) {
        let rootAtStart = root
        dialogs.show(Dialog(title: folder ? "New folder" : "New file",
                            content: AnyView(ExplorerCreateDialog(folder: folder, directory: directory) { url in
            Task {
                guard root == rootAtStart else { return }
                for path in FileTree.ancestorDirectories(of: url, beneath: rootURL) {
                    expanded.insert(path)
                    if children[path] == nil { await load(path) }
                }
                await load(directory.path)
                guard let node = children[directory.path]?.first(where: { $0.path == url.path }) else { return }
                navigator.query = ""
                navigator.filter = .all
                requestSelect(node)
                if folder { expanded.insert(node.path); await load(node.path) }
                await navigator.refreshStatus(roots: projectRoots.map(\.root))
            }
        }), actions: [], width: 460, isModal: true))
    }

    private func renameSelected() -> Bool {
        guard let selected else { return false }
        startRename(selected)
        return true
    }

    // The name is picked without its extension, so typing replaces just the part people
    // usually mean to change.
    private func startRename(_ node: FileNode) {
        renameDraft = node.name
        renameCancelled = false
        renaming = node.path
    }

    // Focus selects the whole field, so the shorter selection is set after it lands.
    private func focusRenameField(_ node: FileNode) {
        renameFocused = true
        let stem = node.isDirectory ? node.name : (node.name as NSString).deletingPathExtension
        let end = stem.isEmpty ? node.name.endIndex : node.name.index(
            node.name.startIndex, offsetBy: stem.count)
        DispatchQueue.main.async {
            renameSelection = TextSelection(range: node.name.startIndex..<end)
        }
    }

    private func endRename() {
        renaming = nil
        renameFocused = false
        treeFocused = true
    }

    private func commitRename(_ node: FileNode) {
        let name = renameDraft
        endRename()
        let rootAtStart = root
        Task {
            switch await FileTree.rename(node.url, to: name) {
            case .unchanged:
                return
            case .failed(let failure):
                dialogs.show(.notice("Could not rename \(node.name)", message: failure))
            case .renamed(let url):
                guard root == rootAtStart else { return }
                await moved(from: node.path, to: url)
            }
        }
    }

    // Everything the pane knows by path follows the item to its new name, so open folders
    // stay open and an open file keeps its unsaved edits.
    private func moved(from old: String, to url: URL) async {
        let new = url.path
        memory.moved(from: old, to: new)
        documents.moved(from: old, to: new)
        expanded = Set(expanded.map { FileTree.path($0, afterMoving: old, to: new) })
        children = children.filter { !isInside($0.key, old) }
        if var current = selected, isInside(current.path, old) {
            current.url = URL(fileURLWithPath: FileTree.path(current.path, afterMoving: old, to: new))
            current.name = current.url.lastPathComponent
            selected = current
            language = CodeLanguage(fileExtension: current.kind)
        }
        let oldParent = (old as NSString).deletingLastPathComponent
        let newParent = url.deletingLastPathComponent().path
        if oldParent != newParent, children[oldParent] != nil { await load(oldParent) }
        await load(newParent)
        for path in expanded.sorted(by: { $0.count < $1.count })
        where isInside(path, new) {
            await load(path)
        }
        statusRevision += 1
    }

    // Rows above and below can both report a drag at once as it crosses between them, so a
    // row only clears the highlight it set itself.
    private func hoverDrop(key: String, folder: String, _ targeted: Bool) {
        if targeted {
            dropHover = DropHover(key: key, folder: folder)
        } else if dropHover?.key == key {
            dropHover = nil
        }
    }

    // Items from inside this folder move. Anything from outside is copied in, the way a
    // paste is, so dragging a file in never takes it away from where it lives.
    private func drop(_ urls: [URL], into folder: URL) -> Bool {
        dropHover = nil
        guard !urls.isEmpty else { return false }
        let destinationRoot = projectRoots.filter { isInside(folder.path, $0.root) }
            .max { $0.root.count < $1.root.count }?.root ?? root
        let local = urls.filter { isInside($0.standardizedFileURL.path, destinationRoot) }
        let outside = urls.filter { !isInside($0.standardizedFileURL.path, destinationRoot) }

        let rootAtStart = root
        Task {
            var failures: [FileTree.CopyFailure] = []
            if !local.isEmpty {
                let result = await FileTree.move(local, into: folder)
                guard root == rootAtStart else { return }
                for move in result.moved {
                    await moved(from: move.from.path, to: move.to)
                }
                failures += result.failures
            }
            if !outside.isEmpty {
                let result = await FileTree.copy(outside, into: folder)
                guard root == rootAtStart else { return }
                if !result.copied.isEmpty { await load(folder.path) }
                failures += result.failures
            }
            if folder.path != root { expanded.insert(folder.path) }
            if children[folder.path] == nil { await load(folder.path) }
            statusRevision += 1

            guard !failures.isEmpty else { return }
            dialogs.show(.notice(
                failures.count == 1 ? "Could not move the item" : "Could not move some items",
                message: failures.map { "\($0.name): \($0.message)" }.joined(separator: "\n")))
        }
        return true
    }

    private func contains(_ node: FileNode, _ path: String) -> Bool {
        isInside(path, node.path)
    }

    private func isInside(_ path: String, _ item: String) -> Bool {
        path == item || path.hasPrefix(item + "/")
    }

    private func pasteDestination(for sources: [URL], at node: FileNode?) -> URL {
        guard let node else { return rootURL }
        guard node.isDirectory else { return node.url.deletingLastPathComponent() }
        let nodeURL = node.url.standardizedFileURL
        let copyingItself = sources.contains { $0.standardizedFileURL == nodeURL }
        return copyingItself ? node.url.deletingLastPathComponent() : node.url
    }

    // MARK: - Actions

    // Keep the workspace tree open while swapping the editor and its unsaved draft.
    private func openRoot() async {
        rememberPlace()
        openedRoot = root
        let place = memory.place(for: root) ?? ExplorerMemory.Place()
        documents = place.documents
        if let edit = place.unsaved { documents.edits[edit.path] = edit }
        navigator.invalidate()
        if children.isEmpty {
            for project in projectRoots {
                expanded.formUnion(memory.place(for: project.root)?.expanded ?? [])
            }
        }
        selected = nil
        previewGeneration += 1
        preview = nil
        loadingPreview = false
        renderingMarkdown = false
        language = nil
        draft = ""
        original = ""
        loadedAt = nil
        resetFind()
        showHidden = place.showHidden
        treeWidth = place.treeWidth
        for project in projectRoots { await load(project.root) }
        for path in expanded.sorted(by: { $0.count < $1.count }) { await load(path) }
        await restore(place)
        await showRequestedFile()
    }

    private func showRequestedFile() async {
        guard let request = reveal.wrappedValue,
              request.path.pathRelative(to: root) != nil else { return }
        reveal.wrappedValue = nil
        collapsedProjects.remove(root)

        let url = URL(fileURLWithPath: request.path)
        let ancestors = FileTree.ancestorDirectories(of: url, beneath: rootURL)
        for path in ancestors {
            expanded.insert(path)
            if children[path] == nil { await load(path) }
        }
        guard !Task.isCancelled,
              let node = children[ancestors.last ?? root]?.first(where: { $0.path == url.path })
        else { return }
        requestSelect(node, line: request.line)
        treeFocused = true
    }

    private func rememberPlace() {
        guard let openedRoot else { return }
        rememberDraft()
        let unsaved = selected.flatMap { documents.edits[$0.path] }
        for project in projectRoots where project.root != openedRoot {
            var place = memory.place(for: project.root) ?? ExplorerMemory.Place()
            place.expanded = Set(expanded.filter { isInside($0, project.root) })
            memory.remember(place, for: project.root)
        }
        memory.remember(.init(expanded: Set(expanded.filter { isInside($0, openedRoot) }),
                              selected: selected,
                              showHidden: showHidden,
                              treeWidth: treeWidth,
                              renderingMarkdown: renderingMarkdown,
                              unsaved: unsaved,
                              documents: documents),
                        for: openedRoot)
    }

    // Folders and files may have gone while the pane was away, so only what is still on
    // disk is opened again. Parents are read before their children.
    private func restore(_ place: ExplorerMemory.Place) async {
        let fileManager = FileManager.default
        for path in place.expanded.sorted(by: { $0.count < $1.count })
        where fileManager.fileExists(atPath: path) {
            guard !Task.isCancelled else { return }
            expanded.insert(path)
            await load(path)
        }
        documents.tabs.removeAll { !fileManager.fileExists(atPath: $0.path) && documents.edits[$0.path] == nil }
        guard !Task.isCancelled, let node = place.selected,
              fileManager.fileExists(atPath: node.path) || documents.edits[node.path] != nil else { return }
        select(node)
        renderingMarkdown = place.renderingMarkdown && node.supportsMarkdownPreview
    }

    private func load(_ path: String) async {
        loadingFolders.insert(path)
        let listing = await FileTree.listing(of: URL(fileURLWithPath: path), includeHidden: showHidden)
        loadingFolders.remove(path)
        guard !Task.isCancelled else { return }
        folderErrors[path] = listing.error
        guard listing.error == nil else { return }
        children[path] = listing.nodes
        for entry in listing.nodes where entry.isDirectory && !entry.isLink {
            var node = entry
            var chain: [String] = []
            // Follow only single-child folders. Links keep their own row and cannot form a cycle.
            for _ in 0..<32 {
                guard !Task.isCancelled else { return }
                chain.append(node.path)
                let nested = await FileTree.listing(of: node.url, includeHidden: showHidden)
                guard !Task.isCancelled else { return }
                folderErrors[node.path] = nested.error
                guard nested.error == nil else { break }
                children[node.path] = nested.nodes
                guard nested.nodes.count == 1, let child = nested.nodes.first,
                      child.isDirectory, !child.isLink else { break }
                node = child
            }
            if chain.contains(where: expanded.contains) { expanded.insert(node.path) }
        }
        navigator.invalidate()
    }

    private func reopenFolders() async {
        for path in (projectRoots.map(\.root) + expanded) {
            await load(path)
        }
        statusRevision += 1
    }

    private func toggle(_ node: FileNode) {
        if expanded.contains(node.path) {
            collapseFolder(node.path)
        } else {
            expanded.insert(node.path)
            Task { await load(node.path) }
        }
    }

    private func collapseFolder(_ path: String) {
        expanded.subtract(rows.first(where: { $0.id == path })?.compactPaths ?? [path])
    }

    private func moveTreeSelection(_ direction: MoveCommandDirection) {
        guard dialogs.current == nil else { return }
        treeCursorVisible = true
        if navigator.isFiltering {
            if direction == .up { navigator.moveCursor(by: -1) }
            if direction == .down { navigator.moveCursor(by: 1) }
            return
        }
        let pinnedPaths = documents.pinned.map(\.path)
        let items = pinnedPaths + projectRoots.flatMap { project in
            (repositories.isEmpty ? [] : [project.root])
                + (collapsedProjects.contains(project.root) ? [] : rows(in: project.root).map(\.id).filter { !pinnedPaths.contains($0) })
        }
        if direction == .up || direction == .down {
            let cursor = projectCursor ?? selected?.path
            guard let next = RowStep.destination(from: cursor.flatMap { items.firstIndex(of: $0) },
                                                 step: direction == .up ? -1 : 1, count: items.count) else { return }
            let path = items[next]
            if projectRoots.contains(where: { $0.root == path }) {
                projectCursor = path
            } else if let node = documents.pinned.first(where: { $0.path == path }) ?? rows.first(where: { $0.id == path })?.node {
                projectCursor = nil
                requestSelect(node)
            }
            return
        }
        if let projectCursor {
            if direction == .left { collapsedProjects.insert(projectCursor) }
            if direction == .right { collapsedProjects.remove(projectCursor) }
            return
        }
        let navigationDirection: FileTreeNavigation.Direction
        switch direction {
        case .up: navigationDirection = .up
        case .down: navigationDirection = .down
        case .left: navigationDirection = .left
        case .right: navigationDirection = .right
        @unknown default: return
        }
        let visibleRows = rows.map {
            FileTreeNavigation.Row(path: $0.node.path,
                                   isDirectory: $0.node.isDirectory,
                                   depth: $0.depth)
        }
        guard let action = FileTreeNavigation.action(
            for: navigationDirection,
            selectedPath: selected?.path,
            rows: visibleRows,
            expanded: expanded) else { return }

        switch action {
        case .select(let path):
            guard let node = rows.first(where: { $0.node.path == path })?.node else { return }
            requestSelect(node)
        case .expand(let path):
            guard let node = rows.first(where: { $0.node.path == path })?.node else { return }
            toggle(node)
        case .collapse(let path):
            collapseFolder(path)
        }
    }

    // Each open file keeps its own draft, so moving through the tree never discards edits.
    private func requestSelect(_ node: FileNode, line: Int? = nil, marking query: String? = nil) {
        if let owner = projectRoots.filter({ isInside(node.path, $0.root) }).max(by: { $0.root.count < $1.root.count }),
           owner.root != root {
            reveal.wrappedValue = ExplorerReveal(path: node.path, line: line)
            selectRoot(owner.root)
            return
        }
        if node.path == selected?.path {
            narrowNavigator = node.isDirectory
            if let line {
                lineToReveal = line
                if let query, !findPresented {
                    revealedMatches = FileTextSearch.hits(of: query, onLine: line, in: draft)
                }
            }
            return
        }
        rememberDraft()
        select(node, line: line, marking: query)
        narrowNavigator = node.isDirectory
    }

    private func rememberDraft() {
        guard let selected, !selected.isDirectory else { return }
        if dirty, let preview {
            documents.edits[selected.path] = .init(path: selected.path, preview: preview, draft: draft,
                                                   original: original, loadedAt: loadedAt)
        } else {
            documents.edits.removeValue(forKey: selected.path)
        }
    }

    private func revert() {
        confirmDiscard {
            draft = original
            if let selected { documents.edits.removeValue(forKey: selected.path) }
            rememberPlace()
        }
    }

    private func confirmDiscard(then discard: @escaping () -> Void) {
        dialogs.show(.confirm("Discard changes?",
                              message: "Edits to \(selected?.name ?? "this file") have not been saved.",
                              action: "Discard", cancel: "Keep editing", handler: discard))
    }

    private func save(_ node: FileNode) {
        let saved = draft
        let expectedModification = loadedAt
        Task {
            let modified = await FileTree.modified(of: node.url)
            guard selected?.path == node.path else { return }
            guard modified == expectedModification else {
                dialogs.show(.confirm(
                    "The file has changed",
                    message: "\(node.name) was written by something else since it was opened here. Saving replaces what is on disk now.",
                    action: "Save anyway") { write(node, text: saved) })
                return
            }
            write(node, text: saved)
        }
    }

    private func write(_ node: FileNode, text saved: String) {
        let writtenRoot = openedRoot ?? root
        Task {
            saving = true
            let failure = await FileTree.write(saved, to: node.url)
            saving = false
            if let failure {
                dialogs.show(.notice("Could not save", message: failure))
                return
            }
            let modified = await FileTree.modified(of: node.url)
            let fresh = await FileTree.children(of: node.url.deletingLastPathComponent(), includeHidden: true)
                .first(where: { $0.path == node.path })
            if openedRoot == writtenRoot {
                if selected?.path == node.path {
                    original = saved
                    loadedAt = modified
                    if let fresh { selected = fresh }
                    rememberDraft()
                } else if let edit = documents.edits[node.path] {
                    documents.edits[node.path] = edit.draft == saved ? nil
                        : .init(path: edit.path, preview: edit.preview, draft: edit.draft, original: saved, loadedAt: modified)
                }
                rememberPlace()
                await reopenFolders()
            } else if var place = memory.place(for: writtenRoot), let edit = place.documents.edits[node.path] {
                place.documents.edits[node.path] = edit.draft == saved ? nil
                    : .init(path: edit.path, preview: edit.preview, draft: edit.draft, original: saved, loadedAt: modified)
                place.unsaved = place.selected.flatMap { place.documents.edits[$0.path] }
                memory.remember(place, for: writtenRoot)
            }
        }
    }

    private func select(_ node: FileNode, line: Int? = nil, marking query: String? = nil) {
        previewGeneration += 1
        let generation = previewGeneration
        resetFind()
        selected = node
        documents.open(node)
        lineToReveal = line
        preview = nil
        renderingMarkdown = false
        language = nil
        draft = ""
        original = ""
        loadedAt = nil
        guard !node.isDirectory else {
            loadingPreview = false
            return
        }
        if let edit = documents.edits[node.path] {
            preview = edit.preview
            draft = edit.draft
            original = edit.original
            loadedAt = edit.loadedAt
            language = CodeLanguage(fileExtension: node.kind)
            loadingPreview = false
            if let query, let line { revealedMatches = FileTextSearch.hits(of: query, onLine: line, in: draft) }
            return
        }
        loadingPreview = true
        Task {
            let modified = await FileTree.modified(of: node.url)
            let loaded = await FileTree.preview(of: node.url)
            guard !Task.isCancelled, selected?.path == node.path, previewGeneration == generation else { return }
            loadingPreview = false
            preview = loaded
            loadedAt = modified
            language = CodeLanguage(fileExtension: node.kind)
            if case .text(let text) = loaded {
                draft = text
                original = text
                if let query, let line {
                    revealedMatches = FileTextSearch.hits(of: query, onLine: line, in: text)
                }
            }
        }
    }
}
