import Foundation
import Observation

@MainActor
@Observable
final class SessionAttention {
    var finished: Set<UUID> = []
    var markedUnread: Set<UUID> = []
    @ObservationIgnored var applicationIsActive = true

    @discardableResult
    func noteTurnEnded(_ sessionID: UUID, isVisible: Bool, isRemote: Bool) -> Bool {
        guard !isRemote, !(applicationIsActive && isVisible) else { return false }
        finished.insert(sessionID)
        return true
    }
}
