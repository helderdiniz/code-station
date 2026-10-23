import AppKit
import SwiftUI

struct PushReviewView: View {
    let model: PushReviewModel
    let repository: String
    let branch: String
    let upstream: String?
    let changed: () async -> Void
    @Environment(DialogPresenter.self) private var dialogs
    @State private var keys = WindowKeyHandler(handlesTyping: true)
    @State private var retry = 0
    @State private var dialogID: UUID?
    @FocusState private var focus: String?
    @AccessibilityFocusState private var errorFocused: Bool

    private var title: String {
        switch model.phase {
        case .loading: "Review your push"
        case .pulling: "Pulling before pushing"
        case .pushing: "Pushing commits"
        case .failed: model.errorTitle
        case .complete: "You’re all up to date."
        case .ready:
            model.behind > 0 ? "Pull before pushing"
                : replaces ? "Replace \(remoteName)?"
                : model.commits.isEmpty ? (publishes ? "Publish branch?" : "Push branch?")
                : "Push \(counted(model.commits.count, "commit"))?"
        }
    }

    // Unknown until origin has been read, so the badge does not show and then vanish.
    private var publishes: Bool { upstream == nil && !model.nameOnOrigin && model.phase != .loading }
    private var replaces: Bool { !model.replaced.isEmpty }

    // The remote side of the route. A branch with no upstream yet will be published to
    // origin under its own name.
    private var remote: (prefix: String, name: String) {
        guard let upstream, let slash = upstream.firstIndex(of: "/") else {
            return ("origin/", upstream ?? branch)
        }
        return (String(upstream[...slash]), String(upstream[upstream.index(after: slash)...]))
    }

    private var remoteName: String { remote.prefix + remote.name }

    private var actionTitle: String {
        switch model.phase {
        case .pulling: "Pulling…"
        case .pushing: "Pushing…"
        case .failed: "Try again"
        case .complete: "Done"
        default:
            model.behind > 0 ? "Pull, then push" : replaces ? "Replace on origin"
                : publishes ? "Publish branch" : "Push commits"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: model.phase == .failed || replaces ? "exclamationmark.triangle"
                      : model.behind > 0 ? "arrow.down" : "arrow.up")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(model.phase == .failed || replaces ? Theme.warningText : Theme.accent)
                    .frame(width: 36, height: 36)
                    .background(Theme.field, in: RoundedRectangle(cornerRadius: 9))
                    .padding(.top, 2)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        ProjectTileView(name: repository, tint: Theme.projectTint(for: repository), side: 18)
                            .accessibilityHidden(true)
                        Text(repository).font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.secondaryText).lineLimit(1)
                    }
                    Text(title).font(.serif(22)).accessibilityAddTraits(.isHeader)
                    route
                }.frame(maxWidth: .infinity, alignment: .leading)
                GlyphButton(icon: "xmark") { dialogs.dismiss() }
                    .disabled(model.isWorking).focused($focus, equals: "close")
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(focus == "close" ? Theme.accent : .clear, lineWidth: 2))
                    .accessibilityLabel("Close push review")
            }.padding(.top, 18).padding(.leading, 20).padding(.trailing, 18).padding(.bottom, 16)
            Divider().overlay(Theme.border)
            HuggingHeight {
                ScrollView { reviewBody }.scrollBounceBehavior(.basedOnSize)
            }
            Divider().overlay(Theme.border)
            HStack(spacing: 10) {
                Group {
                    if model.phase == .loading {
                        ChangesProgressLabel(title: "Checking origin…")
                    } else if model.isWorking {
                        ChangesProgressLabel(title: model.phase == .pulling ? "Pulling from origin…" : "Sending to origin…")
                    } else if model.phase == .complete {
                        Text("Synced with origin")
                    } else {
                        Label("Uncommitted changes stay on this computer.", systemImage: "lock")
                    }
                }
                .font(.system(size: 11)).foregroundStyle(Theme.secondaryText).lineLimit(1)
                Spacer(minLength: 0)
                ActionButton(title: "Cancel", tone: .outlined) { dialogs.dismiss() }
                    .disabled(model.isWorking).focused($focus, equals: "cancel")
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(focus == "cancel" ? Theme.accent : .clear, lineWidth: 2))
                    .opacity(model.phase == .complete ? 0 : 1)
                    .allowsHitTesting(model.phase != .complete)
                    .accessibilityHidden(model.phase == .complete)
                ActionButton(title: actionTitle, tone: replaces && model.phase == .ready ? .danger : .green,
                             fills: true, action: primaryAction)
                    .frame(width: 150)
                    .disabled(model.phase == .loading || model.isWorking)
                    .focused($focus, equals: "primary")
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(focus == "primary" ? Theme.accent : .clear, lineWidth: 2))
            }.padding(.vertical, 12).padding(.leading, 20).padding(.trailing, 14).background(Theme.field)
        }
        .background(Theme.card)
        .background(WindowKeyAnchor(handler: keys))
        .task(id: retry) { await model.load() }
        .onAppear { dialogID = dialogs.current?.id; focus = "cancel"; keys.start { handleKey($0) } }
        .onDisappear { model.invalidate(); keys.stop(); dialogs.restoreFocus() }
        .onChange(of: model.phase) { _, phase in
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: title, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
            if phase == .failed { errorFocused = true; focus = "primary" }
            if phase == .complete { focus = "primary" }
        }
    }

    private var reviewBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            preview
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .motion(Motion.reveal, value: model.phase)
            if model.stashConflict {
                Label("Your commits were pulled, but restoring uncommitted changes left conflicts. The files contain conflict markers and the originals remain in the stash.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(Theme.warningText)
                    .padding(12).background(Theme.warningBackground, in: RoundedRectangle(cornerRadius: 8))
            }
        }.padding(.top, 14).padding(.horizontal, 20).padding(.bottom, 18)
    }

    // Always one line. When both names do not fit, each chip gives up room and cuts its
    // name short, and the full name stays in the tooltip.
    private var route: some View {
        HStack(spacing: 6) {
            BranchChip(icon: "arrow.triangle.branch", name: branch)
            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent)
            BranchChip(icon: "cloud", prefix: remote.prefix, name: remote.name, isNew: publishes)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("From \(branch) to \(remoteName)\(publishes ? ", a new branch on origin" : "")")
    }

    @ViewBuilder private var preview: some View {
        switch model.phase {
        case .loading:
            PushReviewSkeleton().transition(.opacity)
        case .failed:
            VStack(alignment: .leading, spacing: 8) {
                Text(model.error).font(.mono(11)).textSelection(.enabled)
                    .accessibilityFocused($errorFocused)
                Text("Your commits are safe on this computer. Check the error, then try again.")
                    .font(.system(size: 12))
            }.foregroundStyle(Theme.warningText)
                .padding(.vertical, 12).padding(.horizontal, 14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.warningBackground, in: RoundedRectangle(cornerRadius: 10))
                .transition(.opacity)
        case .complete:
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ChangesSuccessMark()
                    Text("\(counted(model.commits.count, "commit")) sent to \(remoteName)")
                        .font(.system(size: 14, weight: .medium))
                }
                if !model.pulled.isEmpty {
                    Text("Pulled \(counted(model.pulled.count, "commit")) from origin.").font(.system(size: 12))
                    RemoteCommitList(commits: model.pulled, emptyMessage: "", incoming: true)
                }
            }.transition(.opacity)
        default:
            VStack(alignment: .leading, spacing: 12) {
                if model.behind > 0 {
                    Text("\(Text(remoteName).fontWeight(.semibold).foregroundStyle(.primary)) has \(counted(model.behind, "new commit")) you don’t have yet. Pull them first, then your commits go up.")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    listLabel("Coming down", count: model.incoming.count)
                    RemoteCommitList(commits: model.incoming, emptyMessage: "", incoming: true)
                    listLabel("Going up", count: model.commits.count)
                } else if replaces {
                    Text("Origin already has a branch called \(Text(remote.name).fontWeight(.semibold).foregroundStyle(.primary)), but it is not part of this branch’s history. The two only share a name. Pushing replaces it, and the commits below leave origin.")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Label("If someone still needs those commits, cancel and give this branch a new name instead.", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12)).foregroundStyle(Theme.warningText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.warningBackground, in: RoundedRectangle(cornerRadius: 8))
                    listLabel("Removed from origin", count: model.replaced.count)
                    RemoteCommitList(commits: model.replaced, emptyMessage: "", incoming: true)
                    listLabel("Going up", count: model.commits.count)
                } else if model.nameOnOrigin {
                    Text("Origin already has this branch, and yours builds on it. Pushing moves it forward and keeps the two in step from now on.")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                } else if upstream == nil {
                    Text("Origin doesn’t have this branch yet. Publishing creates it and keeps the two in step from now on.")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                RemoteCommitList(commits: model.commits, emptyMessage: "There are no new commits to send.")
            }.transition(.opacity)
        }
    }

    private func listLabel(_ title: String, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 12, weight: .semibold)).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            Text("\(count)").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
        }
        .padding(.bottom, -4)
        .accessibilityElement(children: .combine)
    }

    private func primaryAction() {
        switch model.phase {
        case .failed: retry += 1
        case .complete: dialogs.dismiss()
        case .ready:
            Task { if await model.send() { await changed() } }
        default: break
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard dialogs.current?.id == dialogID else { return false }
        if event.keyCode == 53 { dialogs.dismiss(); return true }
        if event.keyCode == 48 {
            guard !model.isWorking else { return true }
            var order = model.phase == .complete ? ["primary", "close"] : ["cancel", "close"]
            if model.phase == .ready || model.phase == .failed { order.insert("primary", at: 1) }
            let index = order.firstIndex(of: focus ?? "") ?? 0
            let step = event.modifierFlags.contains(.shift) ? -1 : 1
            focus = order[(index + step + order.count) % order.count]
            return true
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            if focus == "cancel" || focus == "close" { dialogs.dismiss() }
            else { primaryAction() }
            return true
        }
        return false
    }
}

private struct BranchChip: View {
    let icon: String
    var prefix = ""
    let name: String
    var isNew = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondaryText)
            Text("\(Text(prefix).foregroundStyle(Theme.secondaryText))\(name)")
                .font(.mono(11, .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            if isNew {
                Text("New")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Theme.dotOnText)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Theme.dotOn.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                    .fixedSize()
                    .padding(.leading, 2)
            }
        }
        .padding(.leading, 6).padding(.trailing, 8)
        .frame(height: 22)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(
            Theme.settingsBorder, style: StrokeStyle(lineWidth: 1, dash: isNew ? [3, 2] : [])))
        .appTooltip(prefix + name)
    }
}

// Rows the shape of the commit list, so the dialog keeps its size while origin is read.
// They fade in only if the read takes long enough to notice.
private struct PushReviewSkeleton: View {
    @State private var visible = false

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array([0.6, 0.78, 0.52].enumerated()), id: \.offset) { index, share in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 4).fill(Theme.field).frame(width: 56, height: 8)
                    GeometryReader { geometry in
                        RoundedRectangle(cornerRadius: 4).fill(Theme.field)
                            .frame(width: geometry.size.width * share, height: 8)
                            .frame(maxHeight: .infinity, alignment: .center)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 32)
                .overlay(alignment: .top) {
                    if index > 0 { Rectangle().fill(Theme.hairline).frame(height: 1) }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.settingsBorder))
        .opacity(visible ? 1 : 0)
        .motion(Motion.reveal, value: visible)
        .task {
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            visible = true
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Checking origin…")
    }
}
