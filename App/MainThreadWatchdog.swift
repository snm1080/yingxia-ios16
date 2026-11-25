#if os(iOS)
import Foundation
import TVCore

/// Build 37 probe for the mini-player stall diagnosis (see
/// ~/tools/staging/miniplayer-tap/DIAGNOSIS.md §6): once a second a background timer
/// asks the main queue for a round trip and logs the delay. A main thread wedged after
/// a song starts — the leading suspect when the strip ignores taps — appears here as a
/// round trip over 250 ms bracketed by missing heartbeats; clean heartbeats during
/// dead taps would clear the main thread and point at hit testing instead.
/// Logging only; it never touches playback or the strip.
/// `@unchecked Sendable`: `start()` runs once from the app's init, and `ticks` is only
/// touched from the timer source's own serial event handler.
final class MainThreadWatchdog: @unchecked Sendable {
    static let shared = MainThreadWatchdog()
    private var timer: DispatchSourceTimer?
    private var ticks = 0

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.ping() }
        timer.resume()
        self.timer = timer
        Diagnostics.shared.record(.info, "ui.watchdog", "watchdog started")
    }

    private func ping() {
        ticks += 1
        let heartbeat = ticks % 10 == 0
        let sent = DispatchTime.now().uptimeNanoseconds
        DispatchQueue.main.async {
            let ms = (DispatchTime.now().uptimeNanoseconds - sent) / 1_000_000
            if ms > 250 {
                Diagnostics.shared.record(.warning, "ui.watchdog", "main-thread round trip \(ms)ms")
            } else if heartbeat {
                Diagnostics.shared.record(.info, "ui.watchdog", "heartbeat round trip \(ms)ms")
            }
        }
    }
}
#endif
