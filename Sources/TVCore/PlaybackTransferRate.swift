import Foundation

/// A short rolling byte window remains readable across segmented download
/// bursts and resets when a player is reopened. It never estimates from bitrate.
public struct PlaybackTransferRate: Sendable {
    private struct Sample: Sendable {
        let time: Double
        let bytes: Int64
    }
    private var identity: UUID?
    private var samples: [Sample] = []
    private let window = 3.0

    public init() {}

    public mutating func sample(bytes: Int64, at time: Double, identity: UUID) -> Double? {
        guard time.isFinite, time >= 0, bytes >= 0 else { return nil }
        if self.identity != identity || samples.last.map({ time <= $0.time || bytes < $0.bytes }) == true {
            self.identity = identity
            samples = [Sample(time: time, bytes: bytes)]
            return nil
        }
        samples.append(Sample(time: time, bytes: bytes))
        while samples.count > 2, samples[1].time <= time - window { samples.removeFirst() }
        if samples.count > 64 { samples.removeFirst(samples.count - 64) }
        guard let first = samples.first, time > first.time else { return nil }
        let rate = Double(bytes - first.bytes) / (time - first.time)
        return rate.isFinite && rate >= 0 ? rate : nil
    }
}
