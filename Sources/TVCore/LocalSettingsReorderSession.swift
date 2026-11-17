import Foundation

/// A row is moved only after a matching local drop. Starting/hovering/cancelling
/// a native drag never writes the library or changes enabled/selected sources.
public struct LocalSettingsReorderSession {
    private struct Payload: Codable { let token: UUID; let id: String }
    private var active: Payload?
    public var sourceID: String? { active?.id }
    public init() {}
    public mutating func begin(_ id: String) -> Data {
        let payload = Payload(token: UUID(), id: id)
        active = payload
        return try! JSONEncoder().encode(payload)
    }
    public mutating func cancel() { active = nil }
    /// A late native drag-end callback must not cancel a newer drag.
    public mutating func cancel(_ data: Data) {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.token == active?.token else { return }
        active = nil
    }
    public mutating func accept(_ data: Data, onto target: String, validIDs: [String]) -> String? {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.token == active?.token, payload.id == active?.id else { return nil }
        active = nil
        guard payload.id != target, validIDs.contains(payload.id), validIDs.contains(target) else { return nil }
        return payload.id
    }
}

/// Measured in the receiving list's coordinate space. A single list drop target
/// covers the spaces between rows and the padding above/below the visible rows.
public struct LocalSettingsReorderFrame: Equatable, Sendable {
    public let id: String
    public let minY: Double
    public let maxY: Double
    public init(id: String, minY: Double, maxY: Double) {
        self.id = id; self.minY = minY; self.maxY = maxY
    }
    public static func target(at y: Double, frames: [Self], validIDs: [String]) -> String? {
        guard y.isFinite else { return nil }
        let valid = Set(validIDs)
        let rows = frames.filter { valid.contains($0.id) && $0.minY.isFinite && $0.maxY.isFinite && $0.maxY > $0.minY }
            .sorted { $0.minY < $1.minY }
        guard let first = rows.first else { return nil }
        var previous = first
        for row in rows.dropFirst() {
            // Split the gap equally; dropping on either row always selects that row.
            if y < (previous.maxY + row.minY) / 2 { return previous.id }
            previous = row
        }
        return previous.id
    }
}
