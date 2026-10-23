import Foundation
import Observation

@MainActor
@Observable
final class ScheduledTaskService {
    private(set) var pendingConfirmationID: UUID?
    var failure: String?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    private let store: ProjectStore
    private let runner: SessionRunner
    private let agentAvatarName: () -> String?

    init(store: ProjectStore, runner: SessionRunner, agentAvatarName: @escaping () -> String?) {
        self.store = store
        self.runner = runner
        self.agentAvatarName = agentAvatarName
    }

    func start() {
        guard watchTask == nil else { return }
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick(at: Date())
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
            }
        }
    }

    func stop() {
        watchTask?.cancel()
        watchTask = nil
    }

    enum Confirmation { case run, skip, turnOff }

    func confirm(_ action: Confirmation, projectID: UUID, at date: Date = Date()) {
        guard pendingConfirmationID == projectID else { return }
        pendingConfirmationID = nil
        switch action {
        case .run: run(projectID, at: date)
        case .skip: ScheduledTaskExecution.skip(projectID, at: date, store: store)
        case .turnOff: ScheduledTaskExecution.turnOff(projectID, store: store)
        }
    }

    func tick(at date: Date) {
        if let id = pendingConfirmationID,
           store.project(id)?.task?.schedule?.isWaitingForConfirmation != true {
            pendingConfirmationID = nil
        }
        for var task in store.projects where task.kind == .adHoc {
            guard var spec = task.task, var schedule = spec.schedule, schedule.isActive else {
                continue
            }

            if schedule.nextRunAt == nil, !schedule.isWaitingForConfirmation {
                schedule.prepareIfNeeded(at: date)
                spec.schedule = schedule
                task.task = spec
                store.setTaskSpec(spec, for: task.id)
            }

            guard ScheduledTaskExecution.blocker(for: task, at: date, store: store,
                                                 runner: runner) == nil else { continue }

            if schedule.isWaitingForConfirmation {
                if pendingConfirmationID == nil { pendingConfirmationID = task.id }
                continue
            }

            if schedule.timing == .interval, schedule.requiresConfirmation {
                schedule.waitForConfirmation()
                spec.schedule = schedule
                store.setTaskSpec(spec, for: task.id)
                if pendingConfirmationID == nil { pendingConfirmationID = task.id }
                continue
            }

            run(task.id, at: date)
        }
    }

    private func run(_ projectID: UUID, at date: Date) {
        if case .failure(let error) = ScheduledTaskExecution.run(
            projectID, at: date, store: store, runner: runner, agentAvatarName: agentAvatarName()) {
            failure = error.message
        }
    }
}
