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
                : model.commits.isEmpty ? (upstream == nil ? "Publish branch?" : "Push branch?")
                : "Push \(counted(model.commits.count, "commit"))?"
        }
    }

    private var description: String {
        switch model.phase {
        case .loading: "Checking the commits that will be shared with origin."
        case .failed: "Your commits are safely stored on this computer."
        case .complete: "Your branch has been sent to origin."
        default:
            model.behind > 0 ? "\(upstream ?? "Origin") has \(counted(model.behind, "new commit")). Pull before sending your commits."
                : upstream.map { "These commits will be pushed to \($0)." }
                    ?? "This branch will be published to origin and start tracking it."
        }
    }

    private var actionTitle: String {
        switch model.phase {
        case .pulling: "Pulling…"
        case .pushing: "Pushing…"
        case .failed: "Try again"
        case .complete: "Done"
        default: model.behind > 0 ? "Pull, then push" : upstream == nil ? "Publish branch" : "Push commits"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: model.phase == .failed ? "exclamationmark.triangle" : "arrow.up")
                    .foregroundStyle(model.phase == .failed ? Theme.warningText : Theme.accent)
                    .padding(12).background(Theme.field, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 7) {
                    Text(title).font(.serif(24)).accessibilityAddTraits(.isHeader)
                    Text(description).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                }.frame(maxWidth: .infinity, alignment: .leading)
                GlyphButton(icon: "xmark") { dialogs.dismiss() }
                    .disabled(model.isWorking).focused($focus, equals: "close")
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(focus == "close" ? Theme.accent : .clear, lineWidth: 2))
                    .accessibilityLabel("Close push review")
            }.padding(22)
            Divider().overlay(Theme.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    route
                    preview
                        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
                        .motion(Motion.reveal, value: model.phase)
                    if model.stashConflict {
                        Label("Your commits were pulled, but restoring uncommitted changes left conflicts. The files contain conflict markers and the originals remain in the stash.", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12)).foregroundStyle(Theme.warningText)
                            .padding(12).background(Theme.warningBackground, in: RoundedRectangle(cornerRadius: 8))
                    }
                    Label("Uncommitted changes stay on this computer.", systemImage: "lock")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                }.padding(22)
            }.frame(maxHeight: .infinity)
            Divider().overlay(Theme.border)
            HStack(spacing: 10) {
                if model.isWorking {
                    ChangesProgressLabel(title: model.phase == .pulling ? "Pulling from origin…" : "Sending to origin…")
                } else {
                    Text(model.phase == .complete ? "Synced with origin" : "Review before sharing")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                }
                Spacer(minLength: 0)
                ActionButton(title: "Cancel", tone: .outlined) { dialogs.dismiss() }
                    .disabled(model.isWorking).focused($focus, equals: "cancel")
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(focus == "cancel" ? Theme.accent : .clear, lineWidth: 2))
                    .opacity(model.phase == .complete ? 0 : 1)
                    .allowsHitTesting(model.phase != .complete)
                    .accessibilityHidden(model.phase == .complete)
                ActionButton(title: actionTitle, tone: .green, fills: true, action: primaryAction)
                    .frame(width: 150)
                    .disabled(model.phase == .loading || model.isWorking)
                    .focused($focus, equals: "primary")
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(focus == "primary" ? Theme.accent : .clear, lineWidth: 2))
            }.padding(16).background(Theme.field)
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

    private var route: some View {
        HStack(spacing: 12) {
            ProjectTileView(name: repository, tint: Theme.projectTint(for: repository), side: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(repository).font(.system(size: 12, weight: .semibold))
                Text(branch).font(.mono(11)).textSelection(.enabled)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "arrow.right").foregroundStyle(Theme.accent).accessibilityHidden(true)
            Text(upstream ?? "origin").font(.mono(11)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }.padding(14).background(Theme.field, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private var preview: some View {
        switch model.phase {
        case .loading:
            ChangesLoadingPlaceholder(title: "Checking origin…", rows: 2)
                .transition(.opacity)
        case .failed:
            VStack(alignment: .leading, spacing: 12) {
                Text(model.error).font(.mono(11)).textSelection(.enabled)
                    .foregroundStyle(Theme.warningText)
                    .accessibilityFocused($errorFocused)
                Text("Check the error, then try again to review the current commits.")
                    .font(.system(size: 12)).foregroundStyle(Theme.warningText)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.warningBackground, in: RoundedRectangle(cornerRadius: 10))
                .transition(.opacity)
        case .complete:
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    ChangesSuccessMark()
                    Text("\(counted(model.commits.count, "commit")) sent to origin")
                        .font(.system(size: 14, weight: .medium))
                }
                if !model.pulled.isEmpty {
                    Text("Pulled \(counted(model.pulled.count, "commit")) from origin.").font(.system(size: 12))
                    RemoteCommitList(commits: model.pulled, emptyMessage: "")
                }
            }.transition(.opacity)
        default:
            RemoteCommitList(commits: model.commits, emptyMessage: "There are no new commits to send.")
                .transition(.opacity)
        }
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
