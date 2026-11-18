import Foundation

/// nextDrawable can wait for presentation even after a GPU command completes.
/// Keep that wait off the UI thread, with one worker and one ready resource.
/// The lock protects only ownership/version transfers, never the provider wait.
final class MetalDrawableAcquisition<Value>: @unchecked Sendable {
    private let queue = DispatchQueue(label: "KSPlayer.drawable", qos: .userInteractive)
    private let lock = NSLock()
    private var epoch: UInt64 = 0
    private var acquiring = false
    private var ready: Value?
    private var wake: (@MainActor @Sendable () -> Void)?

    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        epoch &+= 1; ready = nil; wake = nil
        // A provider already waiting cannot be cancelled. Keep its worker
        // occupied until it returns, rather than enqueue another wait.
    }

    func takeOrRequest(acquire: @escaping @Sendable () -> Value?,
                       completion: @escaping @MainActor @Sendable () -> Void) -> Value? {
        lock.lock()
        if let value = ready {
            ready = nil; lock.unlock()
            return value
        }
        wake = completion
        guard !acquiring else { lock.unlock(); return nil }
        acquiring = true
        let requestEpoch = epoch
        lock.unlock()
        queue.async { [self] in
            let value = acquire()
            lock.lock()
            acquiring = false
            let current = requestEpoch == epoch
            if current { ready = value }
            // A newer request may have arrived while the old provider waited.
            // Wake it to acquire its own drawable; never transfer the old one.
            let callback = current && value == nil ? nil : wake
            let deliveryEpoch = epoch
            lock.unlock()
            if let callback {
                DispatchQueue.main.async { [self] in
                    lock.lock(); let valid = deliveryEpoch == epoch; lock.unlock()
                    if valid { callback() }
                }
            }
        }
        return nil
    }
}
