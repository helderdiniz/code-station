import AppKit
import SwiftUI

struct ExplorerFileDetails: View {
    let node: FileNode
    let path: String
    let status: GitStatusKind?
    let text: String?
    let close: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("File details").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    ExplorerIcon(symbol: "xmark", label: "Close file details", action: close)
                }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
                    row("Type", node.isDirectory ? "Folder" : node.kind.isEmpty ? "File" : node.kind.uppercased())
                    row("Size", node.size.formatted(.byteCount(style: .file)))
                    if let text { row("Lines", String(LineIndex(text as NSString).count)) }
                    row("Status", status?.label.capitalized ?? "Unchanged")
                    if text != nil { row("Encoding", "UTF-8") }
                    if let modified = node.modified { row("Modified", modified.formatted(date: .abbreviated, time: .shortened)) }
                }
                Rectangle().fill(Theme.border).frame(height: 1)
                Text("Location").font(.system(size: 11, weight: .semibold))
                Text(path).font(.mono(11)).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                InlineLink(title: "Copy path") { Pasteboard.copy(node.path) }
                if let destination = node.linkDestination {
                    Text("Links to \(destination)").font(.mono(11)).foregroundStyle(.secondary)
                }
                Rectangle().fill(Theme.border).frame(height: 1)
                ActionButton(title: "Open externally", tone: .outlined, height: 30, size: 12) {
                    NSWorkspace.shared.open(node.url)
                }
                InlineLink(title: "Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
            }
            .padding(16)
        }
        .background(Theme.background)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.border).frame(width: 1) }
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow(alignment: .top) {
            Text(title).foregroundStyle(.secondary)
            Text(value).fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 11))
    }
}

struct ExplorerCreateDialog: View {
    private enum Focus: Hashable { case name, cancel, create }
    let folder: Bool
    let directory: URL
    let created: (URL) -> Void
    @Environment(DialogPresenter.self) private var dialogs
    @State private var name = ""
    @State private var failure: String?
    @State private var creating = false
    @FocusState private var focused: Focus?
    @State private var keys = WindowKeyHandler(handlesTyping: true)

    private var validation: String? { name.isEmpty ? nil : FileTree.nameError(name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create in \(directory.path)").font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(folder ? "Folder name" : "File name").font(.system(size: 12, weight: .semibold))
            TextField(folder ? "Folder name" : "Untitled.swift", text: $name)
                .textFieldStyle(.plain).padding(10).fieldSurface(cornerRadius: 8)
                .focused($focused, equals: .name).onSubmit(create)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(focused == .name ? Theme.accent : .clear))
                .disabled(creating)
                .onChange(of: name) { failure = nil }
            if let error = failure ?? validation {
                Text(error).font(.system(size: 12)).foregroundStyle(Theme.deletion)
                    .accessibilityLabel("Error: \(error)")
            }
            HStack {
                Spacer()
                ActionButton(title: "Cancel", tone: .outlined, height: 32, size: 12) { dialogs.dismiss() }
                    .disabled(creating)
                    .focused($focused, equals: .cancel)
                    .overlay(Capsule().stroke(focused == .cancel ? Theme.accent : .clear, lineWidth: 2))
                ActionButton(title: creating ? "Creating…" : folder ? "Create folder" : "Create file",
                             tone: .green, height: 32, size: 12) { create() }
                    .disabled(creating || FileTree.nameError(name) != nil)
                    .focused($focused, equals: .create)
                    .overlay(Capsule().stroke(focused == .create ? Theme.accent : .clear, lineWidth: 2))
            }
        }
        .background(WindowKeyAnchor(handler: keys))
        .onAppear {
            focused = .name
            keys.start { event in
                if event.keyCode == 53 { dialogs.dismiss(); return true }
                if event.keyCode == 48 {
                    guard !creating else { return true }
                    let choices: [Focus] = FileTree.nameError(name) == nil ? [.name, .cancel, .create] : [.name, .cancel]
                    let index = choices.firstIndex(of: focused ?? .name) ?? 0
                    let step = event.modifierFlags.contains(.shift) ? -1 : 1
                    focused = choices[(index + step + choices.count) % choices.count]
                    return true
                }
                if event.keyCode == 36 {
                    if focused == .cancel { dialogs.dismiss() } else { create() }
                    return true
                }
                return false
            }
        }
        .onDisappear { keys.stop() }
    }

    private func create() {
        guard !creating, FileTree.nameError(name) == nil else { return }
        creating = true
        let dialogID = dialogs.current?.id
        if let dialogID { dialogs.setDismissalGuard(for: dialogID) { false } }
        Task {
            let result = await FileTree.create(name: name, folder: folder, in: directory)
            creating = false
            if let dialogID { dialogs.setDismissalGuard(for: dialogID) { true } }
            switch result {
            case .failed(let message): failure = message; focused = .name
            case .created(let url): dialogs.dismiss(); created(url)
            }
        }
    }
}
