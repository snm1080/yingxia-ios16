import Foundation

/// Every async track result carries a media and selection revision. Explicit choices invalidate
/// earlier automatic/source work, and clearing keeps suppression until another choice or episode.
public struct DanmakuTrackSelection: Sendable {
    public enum Origin: String, Codable, Sendable { case automatic, source, manual, cleared }
    public struct Ticket: Sendable, Equatable { let media: String; let revision: UInt64 }
    public private(set) var origin: Origin?
    private var media = ""
    private var revision: UInt64 = 0
    public init() {}
    public var ticket: Ticket { Ticket(media: media, revision: revision) }
    public var hasExplicitChoice: Bool { origin == .manual || origin == .cleared }
    public mutating func begin(media: String) {
        guard self.media != media else { return }
        self.media = media; revision &+= 1; origin = nil
    }
    public mutating func select(_ origin: Origin) { revision &+= 1; self.origin = origin }
    public func accepts(_ ticket: Ticket, origin incoming: Origin) -> Bool {
        guard ticket == self.ticket else { return false }
        if hasExplicitChoice { return incoming == .manual || incoming == .cleared }
        return origin != .source || incoming != .automatic
    }
}
