import Foundation

/// Never block the display-link/UI thread behind the GPU. Two retained
/// commands are enough to keep it fed without an unbounded frame backlog.
final class MetalFrameSubmissionGate: @unchecked Sendable {
    private let lock = NSLock()
    private let maximum = 2
    private var inFlight = 0

    var hasCapacity: Bool {
        lock.lock(); defer { lock.unlock() }
        return inFlight < maximum
    }

    func begin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard inFlight < maximum else { return false }
        inFlight += 1
        return true
    }

    func end() {
        lock.lock(); defer { lock.unlock() }
        inFlight = max(0, inFlight - 1)
    }
}
