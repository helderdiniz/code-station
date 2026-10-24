import SwiftUI

// What git says about each file under the open projects, keyed by absolute path, so a
// row can carry its status badge without asking git as it draws.
@MainActor
@Observable
final class ExplorerGitStatus {
    private(set) var statuses: [String: GitStatusKind] = [:]

    func refresh(roots: [String]) async {
        var statuses: [String: GitStatusKind] = [:]
        for root in roots {
            let snapshot = await GitInspector.snapshot(at: root, lane: .interactive)
            guard !Task.isCancelled else { return }
            guard case .ready = snapshot.state else { continue }
            for file in snapshot.files {
                let path = URL(fileURLWithPath: snapshot.root).standardizedFileURL.appendingPathComponent(file.path).path
                if let relative = path.pathRelative(to: URL(fileURLWithPath: root).resolvingSymlinksInPath().path) {
                    statuses[URL(fileURLWithPath: root).appendingPathComponent(relative).path] = file.kind
                }
            }
        }
        self.statuses = statuses
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
