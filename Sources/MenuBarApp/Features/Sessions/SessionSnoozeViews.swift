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
}

enum SessionSnoozeDialog {
    @MainActor
    static func make(for session: ChatSession, store: ProjectStore) -> Dialog {
        let picked = SnoozeChoice()
        var dialog = Dialog(
            title: "Snooze \"\(session.title)\"",
            message: "The session leaves the sidebar and stays quiet. A question from the agent wakes it.",
            content: AnyView(SnoozeChoices(picked: picked)),
            actions: [
                Dialog.Action(label: "Snooze", kind: .primary) {
                    store.snooze(session.id, picked.choice.snooze())
                },
                Dialog.Action(label: "Cancel", kind: .cancel),
            ])
        dialog.width = 480
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
                    ChoicePill(title: choice.title, selected: picked.choice == choice,
                               thumb: track) {
                        picked.choice = choice
                    }
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.field))
            Text(picked.choice.note)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
                .motion(Motion.control, value: picked.choice)
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
