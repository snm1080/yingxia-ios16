import Foundation

/// Playback notices use monotonic time so backgrounding or a wall-clock adjustment cannot
/// revive a prompt. Repeated state samples keep their ID and therefore cannot extend its life.
struct PlayerNotice: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case information, success, warning }
    let id: UUID
    let message: String
    /// A second line under the message, for a notice whose headline is a full
    /// sentence of its own: the danmaku match banner's loaded count rides
    /// here instead of being appended to a line that then truncates it away.
    let detail: String?
    let kind: Kind
    let expiresAt: Double
    init(message: String, kind: Kind = .information, duration: Double = 5,
         now: Double = ProcessInfo.processInfo.systemUptime, detail: String? = nil) {
        id = UUID(); self.message = String(message.prefix(280)); self.detail = detail.map { String($0.prefix(120)) }; self.kind = kind
        expiresAt = now + min(10, max(1, duration.isFinite ? duration : 5))
    }
    func isVisible(at uptime: Double) -> Bool { uptime.isFinite && uptime < expiresAt && !message.isEmpty }
    static func nextExpiry(_ notices: [Self], at uptime: Double) -> Double? {
        notices.filter { $0.isVisible(at: uptime) }.map(\.expiresAt).min()
    }
}
