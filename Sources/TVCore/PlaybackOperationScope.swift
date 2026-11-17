import Foundation

public struct PlaybackOperationScope: Sendable {
    public struct Ticket: Equatable, Sendable { fileprivate let media: UUID; fileprivate let operation: UInt64 }
    private var media = UUID()
    private var operation: UInt64 = 0
    public init() {}
    public mutating func beginSeek() -> Ticket { operation &+= 1; return Ticket(media: media, operation: operation) }
    public mutating func replaceMedia() { media = UUID(); operation = 0 }
    public func accepts(_ ticket: Ticket) -> Bool { ticket.media == media && ticket.operation == operation }
}

public enum NextMediaPolicy {
    public static func mayPrepare(enabled: Bool, paused: Bool, buffering: Bool, seeking: Bool, bufferedSeconds: Double, speed: Double) -> Bool {
        enabled && !paused && !buffering && !seeking && speed.isFinite && speed > 0 && bufferedSeconds.isFinite && bufferedSeconds / speed >= 20
    }
}
