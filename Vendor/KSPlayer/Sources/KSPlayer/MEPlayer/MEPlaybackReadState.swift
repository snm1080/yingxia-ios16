import Foundation

/// The buffer-capacity callback and demux thread share this predicate. Changing
/// it and waiting use one mutex, so a resume/seek/close cannot precede a stale
/// wait and leave the reader asleep after the last signal.
final class MEPlaybackReadState: @unchecked Sendable {
    private let condition = NSCondition()
    private var state = MESourceState.idle

    var value: MESourceState {
        condition.lock()
        defer { condition.unlock() }
        return state
    }

    func set(_ value: MESourceState) {
        condition.lock()
        state = value
        condition.broadcast()
        condition.unlock()
    }

    @discardableResult func transition(from old: MESourceState, to value: MESourceState,
                                       preparing: () -> Void = {}) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard state == old else { return false }
        preparing()
        state = value
        condition.broadcast()
        return true
    }

    func waitWhilePaused() {
        condition.lock()
        defer { condition.unlock() }
        while state == .paused { condition.wait() }
    }

    /// Accept related transport states in a single critical section. Chaining
    /// separate comparisons can reject a valid seek when capacity resumes the
    /// reader between them. The old state decides whether to restart EOF input.
    @discardableResult func transition(from allowed: [MESourceState], to value: MESourceState,
                                       preparing: (MESourceState) -> Void) -> MESourceState? {
        condition.lock()
        defer { condition.unlock() }
        guard allowed.contains(state) else { return nil }
        let previous = state
        preparing(previous)
        state = value
        condition.broadcast()
        return previous
    }
}
