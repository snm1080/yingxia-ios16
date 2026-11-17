import Foundation

public struct RemoteEpisodeSkipSegment: Codable, Equatable, Hashable, Sendable {
    public let kind: String
    public let start: Double
    public let end: Double
    public let source: String
    public init(kind: String, start: Double, end: Double, source: String) {
        self.kind = kind; self.start = start; self.end = end; self.source = source
    }
    public func isValid(duration: Double) -> Bool {
        guard ["opening", "ending"].contains(kind), duration.isFinite, duration > 0, start.isFinite, end.isFinite, start >= 0,
              end > start, end <= duration + 0.5, end - start < duration else { return false }
        if source == "手动" { return end - start <= 3600 }
        return end - start > 1 && end - start <= 600 &&
            (kind == "opening" ? start <= min(600, duration / 3) : kind == "ending" && start >= duration / 2)
    }
}

public struct RemoteEpisodeSkipChapter: Codable, Equatable, Sendable {
    public let time: Double
    public let title: String
    public let end: Double?
    public init(time: Double, title: String, end: Double? = nil) { self.time = time; self.title = title; self.end = end }
}

/// Preserve exact chapter/provider intervals: cold opens and post-credit scenes are not part of the skip.
public enum RemoteEpisodeSkipPlan {
    public static func local(settings: EpisodeSkipSettings, duration: Double, chapters: [RemoteEpisodeSkipChapter]) -> [RemoteEpisodeSkipSegment] {
        guard duration.isFinite, duration > 0 else { return [] }
        var result: [RemoteEpisodeSkipSegment] = []
        if settings.validationError(duration: duration) == nil {
            if settings.introEnd > 0 { result.append(.init(kind: "opening", start: 0, end: settings.introEnd, source: "手动")) }
            if settings.outroLength > 0 { result.append(.init(kind: "ending", start: duration - settings.outroLength, end: duration, source: "手动")) }
        }
        let rows = chapters.filter { $0.time.isFinite && $0.time >= 0 }.prefix(2000).sorted { $0.time < $1.time }
        for (index, row) in rows.enumerated() {
            let title = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let kind: String
            if title.range(of: #"^(?:op|opening|intro|片头)(?:\s*\d+)?(?:\s*[-:：].*)?$"#, options: [.regularExpression, .caseInsensitive]) != nil { kind = "opening" }
            else if title.range(of: #"^(?:ed|ending|outro|credits|end credits|片尾)(?:\s*\d+)?(?:\s*[-:：].*)?$"#, options: [.regularExpression, .caseInsensitive]) != nil { kind = "ending" }
            else { continue }
            if result.contains(where: { $0.kind == kind && $0.source == "手动" }) { continue }
            let segment = RemoteEpisodeSkipSegment(kind: kind, start: row.time, end: row.end ?? (index + 1 < rows.count ? rows[index + 1].time : duration), source: "章节")
            append(segment, to: &result, duration: duration)
        }
        return result.sorted { $0.start < $1.start }
    }
    public static func merging(local: [RemoteEpisodeSkipSegment], remote: [RemoteEpisodeSkipSegment], duration: Double) -> [RemoteEpisodeSkipSegment] {
        var result = local.filter { $0.isValid(duration: duration) }
        for segment in remote {
            guard !local.contains(where: { $0.kind == segment.kind }) else { continue }
            append(segment, to: &result, duration: duration)
        }
        return result.sorted { $0.start < $1.start }
    }
    private static func append(_ segment: RemoteEpisodeSkipSegment, to result: inout [RemoteEpisodeSkipSegment], duration: Double) {
        guard segment.isValid(duration: duration), !result.contains(where: { $0.start < segment.end && segment.start < $0.end }),
              result.reduce(segment.end - segment.start, { $0 + $1.end - $1.start }) < duration else { return }
        result.append(segment)
    }
}

public struct RemoteEpisodeSkipPass: Sendable {
    private var handled: Set<RemoteEpisodeSkipSegment> = []
    public init() {}
    public mutating func target(time: Double, duration: Double, playing: Bool, enabled: Bool, segments: [RemoteEpisodeSkipSegment]) -> Double? {
        guard enabled, playing, time.isFinite, time >= 0, duration.isFinite, time <= duration else { return nil }
        for segment in segments where segment.isValid(duration: duration) && !handled.contains(segment) {
            // A plan arriving after a segment must not revive it on a manual rewind.
            if time >= segment.end - 0.05 { handled.insert(segment); continue }
            guard time >= segment.start else { continue }
            handled.insert(segment)
            return min(segment.end, duration - 0.05)
        }
        return nil
    }
}
