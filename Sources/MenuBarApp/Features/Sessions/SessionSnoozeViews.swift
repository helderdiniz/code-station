import SwiftUI

// How a session is put to sleep and brought back: the entry in its row's menu, the
// question of how long, and the line over the composer while it sleeps.
enum SessionSnoozeMenu {
    @MainActor
    static func entry(for session: ChatSession, store: ProjectStore,
                      dialogs: DialogPresenter) -> MenuEntry {
        if store.isSnoozed(session.id) {
            .item("Wake up", icon: "bell") { store.wake(session.id) }
        } else {
            .item("Snooze…", icon: "moon.zzz") {
                dialogs.show(SessionSnoozeDialog.make(for: session, store: store))
            }
        }
    }
}

// The pick, shared between the dialog's pills and its Snooze button.
@MainActor
@Observable
private final class SnoozeChoice {
    var choice: SessionSnooze.Choice = .untilReply
    // Fixed when the dialog opens, so the time it names is the time the snooze gets.
    let now = Date()
}

enum SessionSnoozeDialog {
    @MainActor
    static func make(for session: ChatSession, store: ProjectStore) -> Dialog {
        let picked = SnoozeChoice()
        var dialog = Dialog(
            title: "Snooze \"\(session.title)\"",
            message: "The session stays quiet and is marked as snoozed in the sidebar. A question from the agent wakes it.",
            content: AnyView(SnoozeChoices(picked: picked)),
            actions: [
                Dialog.Action(label: "Snooze", kind: .primary) {
                    store.snooze(session.id, picked.choice.snooze(now: picked.now))
                },
                Dialog.Action(label: "Cancel", kind: .cancel),
            ])
        dialog.width = 540
        return dialog
    }
}

private struct SnoozeChoices: View {
    @Bindable var picked: SnoozeChoice
    @Namespace private var track

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                ForEach(SessionSnooze.Choice.allCases) { choice in
                    ChoicePill(title: choice.title(now: picked.now), selected: picked.choice == choice,
                               thumb: track) {
                        picked.choice = choice
                    }
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.field))
            Text(picked.choice.note(now: picked.now))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
                .motion(Motion.control, value: picked.choice)
        }
    }
}

// Says so when a timed snooze runs out, since nothing else about the session changes
// when it does. It waits for any other dialog to be put away first, and every session
// that came back while it waited is told of in one go.
struct SnoozeReminder: View {
    @Environment(ProjectStore.self) private var store
    @Environment(DialogPresenter.self) private var dialogs

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: store.snoozeReminders.count, initial: true) { present() }
            .onChange(of: dialogs.current?.id) { present() }
    }

    private func present() {
        guard dialogs.current == nil, !store.snoozeReminders.isEmpty else { return }
        let due = store.takeSnoozeReminders()
        guard let first = due.first else { return }
        if due.count == 1 {
            dialogs.show(Dialog(
                title: "\"\(first.session.title)\" is back",
                message: "It was snoozed \(first.snooze.phrase()). It can notify you again.",
                actions: [
                    .init(label: "Open session", kind: .primary) {
                        store.selectSession(first.session.id)
                    },
                    .init(label: "Snooze again") {
                        dialogs.show(SessionSnoozeDialog.make(for: first.session, store: store))
                    },
                    .init(label: "OK", kind: .cancel),
                ]))
        } else {
            var dialog = Dialog(
                title: "\(due.count) sessions are back",
                message: "Their snoozes have ended. They can notify you again.",
                actions: [.init(label: "OK", kind: .cancel)])
            dialog.content = AnyView(SessionTitleList(titles: due.map(\.session.title)))
            dialogs.show(dialog)
        }
    }
}

// Over the composer while the session sleeps, with the way back.
struct SessionSnoozeStrip: View {
    let snooze: SessionSnooze
    let wake: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 11, weight: .semibold))
            Text("Snoozed \(snooze.phrase())")
                .font(.system(size: 12, weight: .medium))
            Spacer(minLength: 8)
            InlineLink(title: "Wake up", size: 12, action: wake)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.sunken))
        .accessibilityElement(children: .combine)
    }
}
