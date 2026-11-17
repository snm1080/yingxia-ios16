import Foundation

/// Playback notices use monotonic time so backgrounding or a wall-clock adjustment cannot
/// revive a prompt. Repeated state samples keep their ID and therefore cannot extend its life.
struct PlayerNotice: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case information, success, warning }
    let id: UUID
    let message: String
    let kind: Kind
    let expiresAt: Double
    init(message: String, kind: Kind = .information, duration: Double = 5,
         now: Double = ProcessInfo.processInfo.systemUptime) {
        id = UUID(); self.message = String(message.prefix(280)); self.kind = kind
        expiresAt = now + min(10, max(1, duration.isFinite ? duration : 5))
    }
    func isVisible(at uptime: Double) -> Bool { uptime.isFinite && uptime < expiresAt && !message.isEmpty }
    static func nextExpiry(_ notices: [Self], at uptime: Double) -> Double? {
        notices.filter { $0.isVisible(at: uptime) }.map(\.expiresAt).min()
    }
}
