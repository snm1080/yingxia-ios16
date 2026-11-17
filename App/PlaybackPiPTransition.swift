import Foundation

/// PiP changes presentation ownership while the media session stays alive.
/// A restore request is acknowledged only once its native picture is mounted.
struct PlaybackPiPTransition {
    private(set) var active = false
    private(set) var restoring = false
    private(set) var dismissalPending = false
    private(set) var restoreRequested = false
    private var mounted = false

    var hidesPlayer: Bool { dismissalPending || (active && !restoreRequested) }
    var preservesSessionOnDismiss: Bool { active || restoring || dismissalPending }

    mutating func prepareToStart() { restoreRequested = false; mounted = false }
    mutating func started() {
        active = true
        // AVKit can ask to restore before its start animation has completed.
        // That request keeps the already mounted player instead of dismissing it.
        if !restoreRequested { restoring = false; mounted = false; dismissalPending = true }
    }
    mutating func beginRestore() { restoreRequested = true; restoring = true; mounted = false }
    mutating func stopped() { active = false; if mounted { restoring = false } }
    mutating func coverDismissed() { dismissalPending = false }
    mutating func surfaceMounted() {
        guard !dismissalPending else { return }
        mounted = true; if !active { restoring = false }
    }
    // A controller/media cancellation cannot finish UIKit's previous cover animation.
    // Its delayed dismissal setter stays guarded until the actual onDismiss callback.
    mutating func cancelled() { active = false; restoring = false; restoreRequested = false; mounted = false }
}

/// AVKit hands this callback to a nonisolated delegate. Ownership moves to the
/// main actor; it is never invoked from the delegate's source executor.
final class PlaybackPiPRestoreReply: @unchecked Sendable {
    private let completion: (Bool) -> Void
    init(_ completion: @escaping (Bool) -> Void) { self.completion = completion }
    @MainActor func complete(_ restored: Bool) { completion(restored) }
}
