import AppKit
import SwiftUI

enum FileNameSearch {
    static let resultLimit = 200

    static func matches(_ query: String, in files: [FileNode], beneath root: String) -> [FileNode] {
        let query = normalized(query.trimmed)
        guard !query.isEmpty else { return [] }

        return files.compactMap { node -> (node: FileNode, rank: Int, path: String)? in
            let path = node.path.pathRelative(to: root) ?? node.path
            let name = normalized(node.name)
            let normalizedPath = normalized(path)
            let rank: Int
            if name == query {
                rank = 0
            } else if name.hasPrefix(query) {
                rank = 1
            } else if name.contains(query) {
                rank = 2
            } else if normalizedPath.contains(query) {
                rank = 3
            } else {
                return nil
            }
            return (node, rank, path)
        }
        .sorted { left, right in
            if left.rank != right.rank { return left.rank < right.rank }
            return left.path.localizedStandardCompare(right.path) == .orderedAscending
        }
        .prefix(resultLimit)
        .map(\.node)
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

@MainActor
@Observable
final class ExplorerSearchModel {
    let root: String
    let includeHidden: Bool

    var query = "" {
        didSet { if query != oldValue { refreshMatches() } }
    }
    private(set) var matches: [FileNode] = []
    private(set) var selectedIndex: Int?
    private(set) var loading = true

    private var files: [FileNode] = []

    init(root: String, includeHidden: Bool) {
        self.root = root
        self.includeHidden = includeHidden
    }

    var selected: FileNode? {
        guard let selectedIndex, matches.indices.contains(selectedIndex) else { return nil }
        return matches[selectedIndex]
    }

    func load() async {
        let files = await FileTree.files(
            beneath: URL(fileURLWithPath: root), includeHidden: includeHidden)
        guard !Task.isCancelled else { return }
        self.files = files
        loading = false
        refreshMatches()
    }

    func select(_ index: Int) {
        guard matches.indices.contains(index) else { return }
        selectedIndex = index
    }

    // Wraps at both ends, so the last result is one step up from the first.
    func moveSelection(by offset: Int) {
        guard !matches.isEmpty else { return }
        selectedIndex = ((selectedIndex ?? 0) + offset % matches.count + matches.count) % matches.count
    }

    private func refreshMatches() {
        matches = FileNameSearch.matches(query, in: files, beneath: root)
        selectedIndex = matches.isEmpty ? nil : 0
    }
}

struct ShiftDoubleTapDetector {
    static let maximumInterval: TimeInterval = 0.5

    private var previousTap: TimeInterval?

    mutating func registerTap(at timestamp: TimeInterval) -> Bool {
        if let previousTap, timestamp - previousTap <= Self.maximumInterval {
            self.previousTap = nil
            return true
        }
        previousTap = timestamp
        return false
    }

    mutating func reset() {
        previousTap = nil
    }
}

struct ExplorerSearchShortcut: NSViewRepresentable {
    let onOpen: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onOpen: onOpen) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.anchor = view
        context.coordinator.start()
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.anchor = view
        context.coordinator.onOpen = onOpen
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        weak var anchor: NSView?
        var onOpen: () -> Void

        private var detector = ShiftDoubleTapDetector()
        private var token: Any?

        init(onOpen: @escaping () -> Void) {
            self.onOpen = onOpen
        }

        func start() {
            guard token == nil else { return }
            token = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
                let shouldOpen = MainActor.assumeIsolated { self.handle(event) }
                if shouldOpen {
                    DispatchQueue.main.async { self.onOpen() }
                }
                return event
            }
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard event.window === anchor?.window else {
                detector.reset()
                return false
            }
            guard event.type == .flagsChanged,
                  event.keyCode == 56 || event.keyCode == 60 else {
                detector.reset()
                return false
            }
            guard event.modifierFlags.contains(.shift) else { return false }
            return detector.registerTap(at: event.timestamp)
        }

        func stop() {
            if let token { NSEvent.removeMonitor(token) }
            token = nil
            detector.reset()
        }
    }
}
