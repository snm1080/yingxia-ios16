import Foundation

/// Identity captured before audio/provider work. A late response never belongs to another media or track.
public struct AISubtitleScope: Equatable, Sendable {
    public let sessionID: String, mediaID: String, audioID: String
    public let timeline: Int
    public init(sessionID: String, mediaID: String, timeline: Int, audioID: String) {
        self.sessionID = sessionID; self.mediaID = mediaID; self.timeline = timeline; self.audioID = audioID
    }
    public func accepts(sessionID: String, mediaID: String, timeline: Int, audioID: String) -> Bool {
        !self.sessionID.isEmpty && self.sessionID == sessionID && self.mediaID == mediaID && self.timeline == timeline && self.audioID == audioID
    }
}

public enum AISubtitleTimeline {
    public struct Cue: Equatable, Sendable {
        public let start: Double, end: Double, text: String
        public init(start: Double, end: Double, text: String) { self.start = start; self.end = end; self.text = text }
    }
    /// Resampled windows may overlap. Keep the valid parts outside this window, including the
    /// beginning of a cue crossing its start, but never display its stale overlap with new text.
    public static func replacingWindow(_ existing: [Cue], with replacement: [Cue], position: Double, duration: Double) -> [Cue] {
        guard position.isFinite, duration.isFinite, position >= 0, duration > 0, duration <= 30 else { return existing }
        let end = position + duration
        var result: [Cue] = []
        for cue in existing {
            if cue.end <= position || cue.start >= end { result.append(cue); continue }
            if cue.start < position { result.append(.init(start: cue.start, end: position, text: cue.text)) }
            if cue.end > end { result.append(.init(start: end, end: cue.end, text: cue.text)) }
        }
        result.append(contentsOf: replacement)
        return result.sorted { $0.start < $1.start }
    }
    /// Service timestamps are seconds in the video clock. Accept legacy numeric strings without coercing bools.
    public static func decode(_ data: Data, position: Double, duration: Double) throws -> [Cue] {
        guard position.isFinite, position >= 0, duration.isFinite, duration > 0, duration <= 30,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["cues"] as? [[String: Any]], rows.count <= 1024 else { return [] }
        func number(_ value: Any?) -> Double? {
            if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() { return value.doubleValue }
            return (value as? String).flatMap(Double.init)
        }
        return rows.compactMap { row in
            guard let start = number(row["start"]), let end = number(row["end"]), start.isFinite, end.isFinite,
                  end > start, end > position, start < position + duration,
                  let text = row["text"] as? String, text.utf8.count <= 65536 else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return Cue(start: max(position, start), end: min(position + duration, end), text: trimmed)
        }.sorted { $0.start < $1.start }
    }
    /// Wall-clock movement allows normal high-speed playback but detects both directions of a seek.
    public static func isContinuous(previous: Double, current: Double, elapsed: Double, speed: Double) -> Bool {
        guard previous.isFinite, current.isFinite, elapsed.isFinite, elapsed >= 0 else { return false }
        return current >= previous - 0.75 && current - previous <= max(3, elapsed * max(1, speed) + 2)
    }
}
