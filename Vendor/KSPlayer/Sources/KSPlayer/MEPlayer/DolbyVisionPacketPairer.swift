import FFmpegKit
import Foundation

/// Joins converted P8.1 metadata to its original UHD base access unit.
/// Retain base decode order even when EL presentation times are reordered.
final class DolbyVisionPacketPairer {
    enum Failure: Error { case allocation, invalidTimestamp, missingRPU, queueLimit, malformedRPU }

    final class Output {
        let packet: UnsafeMutablePointer<AVPacket>
        private var owned: UnsafeMutablePointer<AVPacket>?
        init?(copying input: UnsafeMutablePointer<AVPacket>) {
            guard let copy = av_packet_clone(input) else { return nil }
            packet = copy; owned = copy
        }
        deinit { av_packet_free(&owned) }
    }

    private struct Metadata {
        let pts: Int64
        let dts: Int64
        let duration: Int64
        let nal: Data
        let sourcePosition: Int64
        let originalNAL: Data
    }

    let baseTrackID: Int32
    let enhancementTrackID: Int32
    private let baseTimebase: AVRational
    private let enhancementTimebase: AVRational
    private let maximumFrames: Int
    private let maximumBytes: Int
    private let convert: (Data) throws -> Data
    private let flush: () -> Void
    private var base: [Output] = []
    private var metadata: [Metadata] = []
    private var bufferedBytes = 0
    private var seededRPU: Metadata?

    init(baseTrackID: Int32, enhancementTrackID: Int32, baseTimebase: AVRational, enhancementTimebase: AVRational,
         maximumFrames: Int = 32, maximumBytes: Int = 32 * 1024 * 1024,
         convert: @escaping (Data) throws -> Data, flush: @escaping () -> Void) {
        self.baseTrackID = baseTrackID
        self.enhancementTrackID = enhancementTrackID
        self.baseTimebase = baseTimebase
        self.enhancementTimebase = enhancementTimebase
        self.maximumFrames = maximumFrames
        self.maximumBytes = maximumBytes
        self.convert = convert
        self.flush = flush
    }

    func append(packet: UnsafeMutablePointer<AVPacket>) throws {
        let value = packet.pointee
        if value.stream_index == baseTrackID {
            guard let saved = Output(copying: packet) else { throw Failure.allocation }
            base.append(saved)
            bufferedBytes += max(0, Int(value.size))
        } else if value.stream_index == enhancementTrackID {
            guard value.size > 0, let bytes = value.data else { throw Failure.missingRPU }
            let units = VideoNALFormat.annexBUnits(Data(bytes: bytes, count: Int(value.size)))
            let rpus = units.filter { $0.count >= 3 && (($0[0] >> 1) & 63) == 62 }
            guard rpus.count == 1 else { throw Failure.missingRPU }
            guard value.pts != .min || value.dts != .min else { throw Failure.invalidTimestamp }
            if let seeded = seededRPU {
                let samePTS = seeded.pts != .min && value.pts != .min && seeded.pts == value.pts
                let sameDTS = (seeded.pts == .min || value.pts == .min)
                    && seeded.dts != .min && value.dts != .min && seeded.dts == value.dts
                let samePosition = seeded.sourcePosition < 0 || value.pos < 0 || seeded.sourcePosition == value.pos
                if (samePTS || sameDTS), samePosition, seeded.originalNAL == rpus[0] {
                    // The primer already converted this exact first RPU.
                    // Native reads may include it again after its base AU.
                    seededRPU = nil
                    return
                }
                // A different original AU must advance the converter once;
                // only the single seeded source RPU is eligible for skipping.
                seededRPU = nil
            }
            let nal = try convert(rpus[0])
            guard nal.count >= 3, ((nal[0] >> 1) & 63) == 62 else { throw Failure.malformedRPU }
            metadata.append(Metadata(pts: value.pts, dts: value.dts, duration: value.duration, nal: nal,
                                     sourcePosition: value.pos, originalNAL: rpus[0]))
            bufferedBytes += nal.count
        }
        guard base.count <= maximumFrames, metadata.count <= maximumFrames, bufferedBytes <= maximumBytes else {
            throw Failure.queueLimit
        }
    }

    func takeReady() throws -> Output? {
        guard let first = base.first else { return nil }
        let packet = first.packet.pointee
        let index: Int?
        if packet.pts != .min {
            index = metadata.firstIndex { $0.pts != .min && av_compare_ts(packet.pts, baseTimebase, $0.pts, enhancementTimebase) == 0 }
                ?? metadata.firstIndex { $0.pts == .min && packet.dts != .min && $0.dts != .min
                    && av_compare_ts(packet.dts, baseTimebase, $0.dts, enhancementTimebase) == 0 }
        } else if packet.dts != .min {
            index = metadata.firstIndex { $0.dts != .min && av_compare_ts(packet.dts, baseTimebase, $0.dts, enhancementTimebase) == 0 }
        } else {
            // Some original Blu-rays omit the base AU's PES timestamp. Both
            // authored streams still have one AU per frame in decode order.
            index = metadata.isEmpty ? nil : 0
        }
        guard let index else { return nil }
        let rpu = metadata.remove(at: index)
        base.removeFirst()
        bufferedBytes -= Int(packet.size) + rpu.nal.count
        let suffix = Data([0, 0, 0, 1]) + rpu.nal
        guard suffix.count <= Int(Int32.max), av_grow_packet(first.packet, Int32(suffix.count)) >= 0,
              let bytes = first.packet.pointee.data else { throw Failure.allocation }
        suffix.copyBytes(to: bytes.advanced(by: Int(packet.size)), count: suffix.count)
        if packet.pts == .min, rpu.pts != .min {
            first.packet.pointee.pts = av_rescale_q(rpu.pts, enhancementTimebase, baseTimebase)
        }
        if packet.dts == .min, rpu.dts != .min {
            first.packet.pointee.dts = av_rescale_q(rpu.dts, enhancementTimebase, baseTimebase)
        }
        if packet.duration <= 0, rpu.duration > 0 {
            first.packet.pointee.duration = av_rescale_q(rpu.duration, enhancementTimebase, baseTimebase)
        }
        return first
    }

    var hasUnmatchedBase: Bool { !base.isEmpty }

    func reset() {
        discardQueuedPackets()
        seededRPU = nil
        flush()
    }

    /// Metadata pre-roll warms the converter, then the ordinary seek restores
    /// its demux position. Keep converter references while dropping probe AUs.
    func discardQueuedPackets() {
        base.removeAll(); metadata.removeAll(); bufferedBytes = 0
    }

    func warmMetadata(packet: UnsafeMutablePointer<AVPacket>) throws -> Bool {
        guard packet.pointee.stream_index == enhancementTrackID else { return false }
        try append(packet: packet)
        discardQueuedPackets()
        return true
    }

    /// Keep this exact original RPU for the first base AU after demux restore.
    /// Its reference state is advanced once; duplicate original reads skip it.
    func seedFirstMetadata(packet: UnsafeMutablePointer<AVPacket>) throws {
        guard packet.pointee.stream_index == enhancementTrackID else { throw Failure.missingRPU }
        try append(packet: packet)
        guard base.isEmpty, metadata.count == 1 else { throw Failure.missingRPU }
        seededRPU = metadata[0]
    }

}
