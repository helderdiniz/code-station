import SwiftUI

// The columns of the Docker table after the name, kind by kind. The header and every row
// read their widths from here, so the two can never drift apart.
enum DockerColumns {
    static let check: CGFloat = 30
    static let inset: CGFloat = 14

    static func widths(_ kind: DockerKind) -> [CGFloat] {
        switch kind {
        case .containers: [214, 100, 60, 88]
        case .images, .volumes: [170, 72, 64]
        case .networks: [80, 150, 64]
        }
    }

    static func titles(_ kind: DockerKind) -> (name: String, rest: [String]) {
        switch kind {
        case .containers: ("Name", ["Status", "Ports", "Size", ""])
        case .images: ("Image", ["Used by", "Size", ""])
        case .volumes: ("Volume", ["Used by", "Size", ""])
        case .networks: ("Network", ["Driver", "Connected", ""])
        }
    }

    // Sizes and the row's buttons line up on their right edge, the way figures in a
    // column are read.
    static func trailing(_ kind: DockerKind, _ index: Int) -> Bool {
        switch kind {
        case .containers: index >= 2
        case .images, .volumes: index >= 1
        case .networks: index == 2
        }
    }
}

// One line of the table: the box that ticks it, what it is, its columns and the buttons
// that act on it alone. A click anywhere on the line ticks it, so the buttons only show
// under the pointer or while the keyboard is moving around, and never fight the tick.
struct DockerTableRow<Main: View, Cells: View, Actions: View>: View {
    let kind: DockerKind
    let name: String
    let selectable: Bool
    let selected: Bool
    var busy = false
    let toggle: () -> Void
    let click: () -> Void
    let menu: () -> [MenuEntry]
    @ViewBuilder let main: Main
    @ViewBuilder let cells: Cells
    @ViewBuilder let actions: Actions

    @State private var hovering = false
    private var focus = KeyboardFocusVisibility.shared

    init(kind: DockerKind, name: String, selectable: Bool, selected: Bool, busy: Bool = false,
         toggle: @escaping () -> Void, click: @escaping () -> Void,
         menu: @escaping () -> [MenuEntry],
         @ViewBuilder main: () -> Main, @ViewBuilder cells: () -> Cells,
         @ViewBuilder actions: () -> Actions) {
        self.kind = kind
        self.name = name
        self.selectable = selectable
        self.selected = selected
        self.busy = busy
        self.toggle = toggle
        self.click = click
        self.menu = menu
        self.main = main()
        self.cells = cells()
        self.actions = actions()
    }

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if selectable {
                    Button(action: toggle) {
                        CheckboxMark(isOn: selected)
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverLift(amount: Motion.smallLift)
                    .accessibilityLabel("Select \(name)")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                } else {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 26, height: 26)
                        .appTooltip("Built in to Docker")
                }
            }
            .frame(width: DockerColumns.check, alignment: .leading)
            .motion(Motion.control, value: selected)

            main
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 12)
            cells
            actions
                .frame(width: DockerColumns.widths(kind).last ?? 64, alignment: .trailing)
                .opacity(hovering || focus.isVisible ? 1 : 0)
                .motion(Motion.hover, value: hovering)
        }
        .padding(.horizontal, DockerColumns.inset)
        .frame(minHeight: 46)
        .background(selected ? Theme.accent.opacity(0.07) : .clear)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Theme.accentFill)
                .frame(width: 3)
                .opacity(selected ? 1 : 0)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
        .opacity(busy ? 0.7 : 1)
        .contentShape(Rectangle())
        .onTapGesture { if selectable { click() } }
        .hoverFill(cornerRadius: 0)
        .onPointerHover { hovering = $0 }
        .appContextMenu(menu)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// The name column: what the thing is called and, under it in mono, where it came from.
struct DockerNameCell<Badges: View>: View {
    let title: String
    var tag: String? = nil
    var untagged = false
    let subtitle: String
    var fullName: String? = nil
    @ViewBuilder let badges: Badges

    init(title: String, tag: String? = nil, untagged: Bool = false, subtitle: String,
         fullName: String? = nil, @ViewBuilder badges: () -> Badges) {
        self.title = title
        self.tag = tag
        self.untagged = untagged
        self.subtitle = subtitle
        self.fullName = fullName
        self.badges = badges()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12.5, weight: untagged ? .regular : .semibold))
                    .italic(untagged)
                    .foregroundStyle(untagged ? Theme.secondaryText : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .appTooltip(fullName ?? title)
                if let tag {
                    Text(tag)
                        .font(.mono(10.5, .medium))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Theme.field, in: RoundedRectangle(cornerRadius: 4))
                }
                badges
            }
            Text(subtitle)
                .font(.mono(10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

extension DockerNameCell where Badges == EmptyView {
    init(title: String, tag: String? = nil, untagged: Bool = false, subtitle: String,
         fullName: String? = nil) {
        self.init(title: title, tag: tag, untagged: untagged, subtitle: subtitle,
                  fullName: fullName) { EmptyView() }
    }
}

struct DockerStatusCell: View {
    let container: DockerContainer
    let working: DockerVerb?

    var body: some View {
        HStack(spacing: 7) {
            if let working {
                LoopSpinner()
                Text(working.progress)
                    .foregroundStyle(Theme.secondaryText)
                    .contentTransition(.opacity)
            } else {
                switch container.state {
                case .restarting:
                    BreathingCircle(colour: Theme.attention, restingOpacity: 1, fullOpacity: 0.35)
                        .frame(width: 7, height: 7)
                    Text("Restarting")
                        .foregroundStyle(Theme.attentionText)
                        .appTooltip(container.exitCode.map { "Exited with code \($0) and keeps coming back" }
                                    ?? "Keeps exiting and coming back")
                case .running:
                    Circle().fill(Theme.dotOn).frame(width: 7, height: 7)
                    Text("Up \(container.since)").lineLimit(1)
                    if let health = container.health {
                        DockerBadge(text: health, tone: health == "Unhealthy" ? .warning : .accent)
                    }
                case .paused:
                    Circle().fill(Theme.attention).frame(width: 7, height: 7)
                    Text("Paused").foregroundStyle(Theme.attentionText)
                case .created:
                    Circle().fill(Theme.dotOff).frame(width: 7, height: 7)
                    Text("Created, never started").foregroundStyle(Theme.secondaryText).lineLimit(1)
                case .exited, .dead, .removing:
                    Circle().fill(Theme.dotOff).frame(width: 7, height: 7)
                    Text(container.since.isEmpty ? "Stopped" : "Stopped \(container.since)")
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                    if let code = container.exitCode, code != 0 {
                        DockerBadge(text: "code \(code)", tone: .grey)
                            .appTooltip(code == 143 || code == 137
                                        ? "Exit code \(code), stopped by a signal" : "Exit code \(code)")
                    }
                }
            }
        }
        .font(.system(size: 12))
        .accessibilityElement(children: .combine)
    }
}

// The host ports a container publishes. Each opens in the browser, which is where a port
// is usually headed.
struct DockerPortsCell: View {
    let ports: [String]
    let open: (String) -> Void

    var body: some View {
        HStack(spacing: 4) {
            if ports.isEmpty {
                Text("None").font(.system(size: 12)).foregroundStyle(.tertiary)
            } else {
                ForEach(ports.prefix(2), id: \.self) { port in
                    DockerPortButton(port: port) { open(port) }
                }
                if ports.count > 2 {
                    Text("+\(ports.count - 2)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.secondaryText)
                        .appTooltip(ports.dropFirst(2).joined(separator: ", "))
                }
            }
        }
    }
}

private struct DockerPortButton: View {
    let port: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(port).font(.mono(11, .medium))
                if hovering {
                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: 8, weight: .bold))
                        .transition(.opacity)
                }
            }
            .foregroundStyle(hovering ? Theme.accent : .primary)
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(hovering ? Theme.accent.opacity(0.1) : Theme.field,
                        in: RoundedRectangle(cornerRadius: 5))
            .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .hoverLift(hovering)
        .onPointerHover { hovering = $0 }
        .motion(Motion.hover, value: hovering)
        .appTooltip("Open localhost:\(port)")
        .accessibilityLabel("Open localhost port \(port) in the browser")
    }
}

// Who uses an image or a volume: the first container by name, and how many more.
struct DockerUsersCell: View {
    let users: [DockerContainer]
    var noneText = "Not used"

    var body: some View {
        if let first = users.first {
            HStack(spacing: 6) {
                Circle()
                    .fill(users.contains(where: \.isRunning) ? Theme.dotOn : Theme.dotOff)
                    .frame(width: 6, height: 6)
                Text(Self.name(first) + (users.count > 1 ? " +\(users.count - 1)" : ""))
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .appTooltip(users.map(\.name).joined(separator: ", "))
            .accessibilityElement(children: .combine)
        } else {
            Text(noneText).font(.system(size: 12)).foregroundStyle(.tertiary)
        }
    }

    private static func name(_ container: DockerContainer) -> String {
        guard let project = container.composeProject, let service = container.composeService else {
            return container.name
        }
        return "\(project)/\(service)"
    }
}

struct DockerSizeCell: View {
    let bytes: Int64?

    var body: some View {
        Text(bytes.map(DockerSize.text) ?? "-")
            .font(.system(size: 12))
            .monospacedDigit()
            .foregroundStyle((bytes ?? 0) < 1_000_000 ? Theme.secondaryText : .primary)
            .lineLimit(1)
            .contentTransition(.numericText())
    }
}

struct DockerBadge: View {
    enum Tone { case accent, grey, warning }

    let text: String
    var tone: Tone = .accent

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(ink)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(fill, in: RoundedRectangle(cornerRadius: 5))
    }

    private var ink: Color {
        switch tone {
        case .accent: Theme.accent
        case .grey: Theme.secondaryText
        case .warning: Theme.warningText
        }
    }

    private var fill: Color {
        switch tone {
        case .accent: Theme.accent.opacity(0.1)
        case .grey: Theme.field
        case .warning: Theme.warningBackground
        }
    }
}

// A compose project heading its containers, or the run of containers that belong to none.
struct DockerGroupHeader: View {
    let project: String?
    let containers: [DockerContainer]
    let selectedCount: Int
    let collapsed: Bool
    let busy: Bool
    let toggle: () -> Void
    let collapse: () -> Void
    let act: (DockerVerb) -> Void

    private var running: Int { containers.count(where: \.isRunning) }

    private var state: String {
        if running == containers.count { return "all running" }
        if running == 0 { return containers.count == 1 ? "stopped" : "all stopped" }
        return "\(running) of \(containers.count) running"
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: toggle) {
                CheckboxMark(isOn: selectedCount > 0 && selectedCount == containers.count,
                             mixed: selectedCount > 0 && selectedCount < containers.count)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverLift(amount: Motion.smallLift)
            .frame(width: DockerColumns.check, alignment: .leading)
            .motion(Motion.control, value: selectedCount)
            .accessibilityLabel("Select every container in \(project ?? "Standalone containers")")

            Button(action: collapse) {
                HStack(spacing: 8) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: 12)
                        .contentTransition(.symbolEffect(.replace))
                    if let project {
                        RoundedRectangle(cornerRadius: 2.5)
                            .fill(Theme.projectTint(for: project).colour)
                            .frame(width: 9, height: 9)
                    }
                    Text(project ?? "Standalone containers")
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    Text(state)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.secondaryText)
                        .contentTransition(.opacity)
                    if project != nil { DockerBadge(text: "Compose") }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(project ?? "Standalone containers"), \(state)")
            .accessibilityHint(collapsed ? "Expand" : "Collapse")

            Spacer(minLength: 8)

            if project != nil {
                HStack(spacing: 6) {
                    if running > 0 {
                        ActionButton(title: "Stop all", tone: .outlined, height: 24, size: 11,
                                     icon: "stop.fill") { act(.stop) }
                            .disabled(busy)
                    }
                    if running < containers.count {
                        ActionButton(title: "Start all", tone: .outlined, height: 24, size: 11,
                                     icon: "play.fill") { act(.start) }
                            .disabled(busy)
                    }
                }
            }
        }
        .padding(.horizontal, DockerColumns.inset)
        .frame(height: 38)
        .background(Theme.sunken)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

// Rises from the bottom of the table once anything is ticked, with the actions that work
// on everything ticked at once. It is the only place in the sheet that carries red.
struct DockerSelectionBar: View {
    let kind: DockerKind
    let count: Int
    let bytes: Int64
    let running: Int
    let delete: () -> Void
    let act: (DockerVerb) -> Void
    let clear: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 5) {
                Text("\(count)")
                    .contentTransition(.numericText())
                    .motion(Motion.pop, value: count)
                Text(count == 1 ? "\(kind.noun) selected" : "\(kind.noun)s selected")
                if bytes >= 1_000_000 {
                    Text(DockerSize.text(bytes))
                        .foregroundStyle(Theme.terminalDim)
                        .padding(.leading, 4)
                        .contentTransition(.numericText())
                }
            }
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Theme.terminalText)
            .monospacedDigit()
            .padding(.leading, 6)
            .padding(.trailing, 10)
            .accessibilityElement(children: .combine)

            if kind == .containers {
                DockerBarButton(title: "Start", icon: "play.fill") { act(.start) }
                    .disabled(running == count)
                DockerBarButton(title: "Stop", icon: "stop.fill") { act(.stop) }
                    .disabled(running == 0)
                DockerBarButton(title: "Restart", icon: "arrow.clockwise") { act(.restart) }
                    .disabled(running == 0)
                Rectangle().fill(Theme.terminalDim.opacity(0.4)).frame(width: 1, height: 20)
                    .padding(.horizontal, 4)
            }
            ActionButton(title: "Delete", tone: .danger, height: 30, size: 12.5, icon: "trash",
                         action: delete)
                .appTooltip("Delete the selection (⌫)")
            DockerBarButton(title: nil, icon: "xmark", action: clear)
                .appTooltip("Clear the selection (Esc)")
                .accessibilityLabel("Clear the selection")
        }
        .padding(6)
        .background(Theme.terminal, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Selection actions")
    }
}

private struct DockerBarButton: View {
    let title: String?
    let icon: String
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 10.5, weight: .semibold))
                if let title { Text(title).font(.system(size: 12.5, weight: .semibold)) }
            }
            .foregroundStyle(Theme.terminalText)
            .padding(.horizontal, title == nil ? 0 : 10)
            .frame(minWidth: 30)
            .frame(height: 30)
            .background(Color.white.opacity(hovering && isEnabled ? 0.1 : 0),
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .hoverLift(hovering)
        .onPointerHover { hovering = $0 }
        .motion(Motion.hover, value: hovering)
    }
}

// A line of the table before docker has answered, the same height as a real one so
// nothing jumps when the rows arrive.
struct DockerSkeletonRow: View {
    let width: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 4).fill(Theme.field).frame(width: 16, height: 16)
                .frame(width: DockerColumns.check, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 3).fill(Theme.field).frame(width: width, height: 10)
                RoundedRectangle(cornerRadius: 3).fill(Theme.sunken).frame(width: width * 1.6, height: 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            RoundedRectangle(cornerRadius: 3).fill(Theme.field).frame(width: 90, height: 10)
                .frame(width: 214, alignment: .leading)
            RoundedRectangle(cornerRadius: 3).fill(Theme.field).frame(width: 40, height: 10)
                .frame(width: 100, alignment: .leading)
            RoundedRectangle(cornerRadius: 3).fill(Theme.field).frame(width: 40, height: 10)
                .frame(width: 60 + 88, alignment: .leading)
        }
        .padding(.horizontal, DockerColumns.inset)
        .frame(height: 46)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .accessibilityHidden(true)
    }
}
