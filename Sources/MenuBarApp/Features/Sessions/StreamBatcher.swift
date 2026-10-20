import Foundation
import Synchronization

final class StreamBatcher: Sendable {
    struct Batch: Sendable {
        var events: [StreamEvent] = []
        var stderr = ""
        var stdoutActivity = false
        var stdoutClosed = false
        var stderrClosed = false
    }

    private struct State: Sendable {
        var pending = Batch()
        var flushScheduled = false
    }
    private let state = Mutex(State())

    func append(events: [StreamEvent] = [], stderr: String = "",
                stdoutActivity: Bool = false, stdoutClosed: Bool = false,
                stderrClosed: Bool = false) -> Bool {
        state.withLock { state in
            state.pending.events.append(contentsOf: events)
            state.pending.stderr += stderr
            state.pending.stdoutActivity = state.pending.stdoutActivity || stdoutActivity
            state.pending.stdoutClosed = state.pending.stdoutClosed || stdoutClosed
            state.pending.stderrClosed = state.pending.stderrClosed || stderrClosed
            guard !state.flushScheduled else { return false }
            state.flushScheduled = true
            return true
        }
    }

    func drain() -> Batch {
        state.withLock { state in
            let batch = state.pending
            state = State()
            return batch
        }
    }
}
