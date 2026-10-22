import SwiftUI

struct ScheduledTaskConfirmation: View {
    @Environment(ProjectStore.self) private var store
    @Environment(ScheduledTaskService.self) private var service
    @Environment(DialogPresenter.self) private var dialogs

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: service.pendingConfirmationID, initial: true) { presentPending() }
            .onChange(of: service.failure) { presentPending() }
            .onChange(of: dialogs.current?.id) { presentPending() }
    }

    private func presentPending() {
        guard dialogs.current == nil else { return }
        if let failure = service.failure {
            service.failure = nil
            dialogs.show(.notice("Could not run the scheduled task", message: failure))
        } else if let id = service.pendingConfirmationID, let task = store.project(id) {
            presentConfirmation(for: task)
        }
    }

    private func presentConfirmation(for task: Project) {
        guard dialogs.current == nil,
              let schedule = store.project(task.id)?.task?.schedule else { return }
        dialogs.show(Dialog(
            title: "Run \"\(task.name)\"?",
            message: "Its \(schedule.summary.lowercased()) timer is due. Start the next scheduled run?",
            actions: [
                .init(label: "Run now", kind: .primary) {
                    service.confirm(.run, projectID: task.id)
                },
                .init(label: "Skip this run", kind: .cancel) {
                    service.confirm(.skip, projectID: task.id)
                },
                .init(label: "Turn off timer") {
                    service.confirm(.turnOff, projectID: task.id)
                }
            ],
            onCancel: {
                service.confirm(.skip, projectID: task.id)
            }))
    }

}
