import Foundation

/// Immutable samples of the demuxer's actual byte/timestamp index. The worker
/// publishes these after opening/reading; the UI never inspects FFmpeg pointers.
public struct PlaybackCacheTimeline: Sendable {
    public struct Point: Sendable {
        public let position: Int64
        public let time: Double
        public init(position: Int64, time: Double) { self.position = position; self.time = time }
    }
    public let resourceID: String
    public let points: [Point]
    public let duration: Double?
    public let timeOrigin: Double
    public init(resourceID: String, points: [Point], duration: Double? = nil, timeOrigin: Double = 0) {
        self.resourceID = resourceID; self.points = points
        self.duration = duration; self.timeOrigin = timeOrigin
    }

    public struct Segment: Sendable {
        public let bytes: Range<Int64>
        public let time: ClosedRange<Double>
        public init(bytes: Range<Int64>, time: ClosedRange<Double>) { self.bytes = bytes; self.time = time }
    }

    public static func coveredRanges(indexes: [Self], coverage: [String: [Range<Int64>]],
                                     lengths: [String: Int64] = [:], segments: [String: [Segment]] = [:]) -> [ClosedRange<Double>] {
        guard !indexes.isEmpty else { return [] }
        var result: [ClosedRange<Double>]?
        for index in indexes {
            guard let bytes = coverage[index.resourceID], !bytes.isEmpty else { return [] }
            // A complete finite file has exact coverage even when the format
            // exposes only a growing fragment index (or no public index).
            if let length = lengths[index.resourceID], length > 0,
               let duration = index.duration, duration.isFinite, duration > 0,
               bytes.contains(where: { $0.lowerBound == 0 && $0.upperBound >= length }) {
                result = intersection(result, [0...duration])
                continue
            }
            var ranges: [ClosedRange<Double>] = []
            // Matroska audio entries share the cluster's byte offset. Keep the
            // earliest time at that offset, but reject real timestamp resets.
            var points: [Point] = []
            var previous: Point?
            for point in index.points {
                guard point.position >= 0, point.time.isFinite else { return [] }
                if let last = previous {
                    guard point.position >= last.position, point.time >= last.time else { return [] }
                    if point.position == last.position || point.time == last.time {
                        previous = point
                        continue
                    }
                }
                points.append(point); previous = point
            }
            var byteIndex = 0
            for offset in 1..<max(1, points.count) {
                let left = points[offset - 1], right = points[offset]
                guard left.position >= 0, right.position > left.position,
                      left.time.isFinite, right.time.isFinite, right.time > left.time else { return [] }
                while byteIndex < bytes.count && bytes[byteIndex].upperBound <= left.position { byteIndex += 1 }
                guard byteIndex < bytes.count else { break }
                guard right.time > 0, bytes[byteIndex].lowerBound <= left.position,
                      bytes[byteIndex].upperBound >= right.position else { continue }
                let start = max(0, left.time)
                if let last = ranges.last, last.upperBound == start {
                    ranges[ranges.count - 1] = last.lowerBound...right.time
                } else { ranges.append(start...right.time) }
            }
            // Fragment boundaries come from a validated global SIDX parsed
            // from bytes already in the cache, never an average bitrate guess.
            byteIndex = 0
            for segment in segments[index.resourceID] ?? [] {
                while byteIndex < bytes.count && bytes[byteIndex].upperBound <= segment.bytes.lowerBound { byteIndex += 1 }
                guard byteIndex < bytes.count else { break }
                let start = max(0, segment.time.lowerBound - index.timeOrigin)
                let end = min(index.duration ?? .greatestFiniteMagnitude, segment.time.upperBound - index.timeOrigin)
                guard start.isFinite, end.isFinite, end > start,
                      bytes[byteIndex].lowerBound <= segment.bytes.lowerBound,
                      bytes[byteIndex].upperBound >= segment.bytes.upperBound else { continue }
                ranges.append(start...end)
            }
            ranges = merged(ranges)
            result = intersection(result, ranges)
            if result?.isEmpty == true { return [] }
        }
        return result ?? []
    }

    public static func merged(_ ranges: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        var result: [ClosedRange<Double>] = []
        for range in ranges.filter({ $0.lowerBound.isFinite && $0.upperBound.isFinite && $0.upperBound > $0.lowerBound })
            .sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else { result.append(range) }
        }
        return result
    }

    private static func intersection(_ previous: [ClosedRange<Double>]?, _ ranges: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        guard let previous else { return ranges }
        var result: [ClosedRange<Double>] = [], a = 0, b = 0
        while a < previous.count && b < ranges.count {
            let start = max(previous[a].lowerBound, ranges[b].lowerBound)
            let end = min(previous[a].upperBound, ranges[b].upperBound)
            if end > start { result.append(start...end) }
            if previous[a].upperBound < ranges[b].upperBound { a += 1 } else { b += 1 }
        }
        return result
    }
}
