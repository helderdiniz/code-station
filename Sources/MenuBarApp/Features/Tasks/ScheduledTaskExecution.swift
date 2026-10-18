import Foundation

@MainActor
enum ScheduledTaskExecution {
    static func isBusy(_ task: Project, store: ProjectStore, runner: SessionRunner) -> Bool {
        store.standaloneSessions(for: task.id).contains { runner.state($0.id).isBusy }
    }

    // Why a scheduled run cannot start right now, or nil when it can. The loop passes
    // over a blocked task quietly and a run asked for by hand reports the reason, so the
    // two agree on what counts as ready.
    static func blocker(for task: Project, at date: Date, store: ProjectStore,
                        runner: SessionRunner) -> String? {
        guard task.kind == .adHoc, let schedule = task.task?.schedule, schedule.isActive else {
            return "The task timer is no longer active."
        }
        guard schedule.isWaitingForConfirmation
                || schedule.nextRunAt.map({ $0 <= date }) == true else {
            return "The task timer is not due yet."
        }
        if store.isMissing(task) { return "The task folder is no longer on disk." }
        if task.task?.prompt.isBlank ?? true { return "The task has no prompt to run." }
        if isBusy(task, store: store, runner: runner) {
            return "Another run is still working in the task folder."
        }
        if TaskRun.automaticValues(for: task) == nil {
            return "Run the task once to save its required input values."
        }
        return nil
    }

    @discardableResult
    static func run(_ projectID: UUID, at date: Date = Date(), store: ProjectStore,
                    runner: SessionRunner, agentAvatarName: String?)
        -> Result<ChatSession, PersistenceFailure> {
        guard let task = store.project(projectID) else {
            return .failure(PersistenceFailure(message: "The task timer is no longer active."))
        }
        if let blocker = blocker(for: task, at: date, store: store, runner: runner) {
            return .failure(PersistenceFailure(message: blocker))
        }
        // The blocker check has already made sure every required answer is there.
        let values = TaskRun.automaticValues(for: task) ?? [:]

        let result = TaskRun.run(task, values: values, scheduled: true, store: store,
                                 runner: runner,
                                 agentAvatarName: agentAvatarName)
        switch result {
        case .success(let session):
            changeSchedule(projectID, store: store) { $0.recordRun(at: date) }
            return .success(session)
        case .failure(let failure):
            // A storage failure should not be retried every two seconds. The occurrence
            // is skipped and the visible error lets the user deal with the cause.
            skip(projectID, at: date, store: store)
            return .failure(failure)
        }
    }

    static func skip(_ projectID: UUID, at date: Date = Date(), store: ProjectStore) {
        changeSchedule(projectID, store: store) { $0.skip(at: date) }
    }

    static func turnOff(_ projectID: UUID, store: ProjectStore) {
        changeSchedule(projectID, store: store) { $0.turnOff() }
    }

    private static func changeSchedule(_ projectID: UUID, store: ProjectStore,
                                       change: (inout TaskSchedule) -> Void) {
        guard var spec = store.project(projectID)?.task, var schedule = spec.schedule else { return }
        change(&schedule)
        spec.schedule = schedule
        store.setTaskSpec(spec, for: projectID)
    }
}
