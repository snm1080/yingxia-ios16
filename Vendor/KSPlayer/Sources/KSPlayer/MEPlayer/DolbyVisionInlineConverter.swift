import FFmpegKit
import Foundation

/// An explicitly tagged inline P7 access unit contains base HEVC, an RPU,
/// and optional type-63 encapsulated FEL. Preserve base samples and timing.
final class DolbyVisionInlineConverter {
    enum Failure: Error { case malformedNAL, missingRPU, allocation }
    private let annexB: Bool
    private let lengthFieldBytes: Int
    private let convert: (Data) throws -> Data
    private let flush: () -> Void
    private var seeded: (input: Data, output: Data, pts: Int64, dts: Int64, position: Int64)?

    init(annexB: Bool, lengthFieldBytes: Int, convert: @escaping (Data) throws -> Data, flush: @escaping () -> Void) {
        self.annexB = annexB
        self.lengthFieldBytes = lengthFieldBytes
        self.convert = convert
        self.flush = flush
    }

    func convertAccessUnit(_ data: Data) throws -> Data {
        let units: [Data]
        if annexB { units = VideoNALFormat.annexBUnits(data) }
        else {
            guard [1, 2, 3, 4].contains(lengthFieldBytes) else { throw Failure.malformedNAL }
            let bytes = [UInt8](data)
            var parsed: [Data] = [], offset = 0
            while offset < bytes.count {
                guard offset + lengthFieldBytes <= bytes.count else { throw Failure.malformedNAL }
                var length = 0
                for index in 0 ..< lengthFieldBytes { length = (length << 8) | Int(bytes[offset + index]) }
                offset += lengthFieldBytes
                guard length > 0, length <= bytes.count - offset else { throw Failure.malformedNAL }
                parsed.append(Data(bytes[offset ..< offset + length])); offset += length
            }
            units = parsed
        }
        let rpus = units.filter { $0.count > 2 && (($0[0] >> 1) & 63) == 62 }
        guard rpus.count == 1 else { throw Failure.missingRPU }
        let converted = try convert(rpus[0])
        guard converted.count > 2, ((converted[0] >> 1) & 63) == 62 else { throw Failure.malformedNAL }
        var result = Data()
        for unit in units {
            guard unit.count >= 2 else { throw Failure.malformedNAL }
            let type = (unit[0] >> 1) & 63
            if type == 63 || type == 62 { continue }
            try append(unit, to: &result)
        }
        try append(converted, to: &result)
        return result
    }

    private func append(_ unit: Data, to result: inout Data) throws {
        if annexB { result.append(contentsOf: [0, 0, 0, 1]) }
        else {
            guard UInt64(unit.count) < (UInt64(1) << (lengthFieldBytes * 8)) else { throw Failure.malformedNAL }
            let length = UInt32(unit.count)
            for index in (0 ..< lengthFieldBytes).reversed() {
                result.append(UInt8(truncatingIfNeeded: length >> (index * 8)))
            }
        }
        result.append(unit)
    }

    func convert(packet: UnsafeMutablePointer<AVPacket>) throws {
        guard packet.pointee.size > 0, let source = packet.pointee.data else { throw Failure.malformedNAL }
        let original = Data(bytes: source, count: Int(packet.pointee.size))
        let data: Data
        if let seeded,
           (seeded.pts != .min && packet.pointee.pts == seeded.pts
                || (seeded.pts == .min || packet.pointee.pts == .min) && packet.pointee.dts == seeded.dts),
           (seeded.position < 0 || packet.pointee.pos < 0 || seeded.position == packet.pointee.pos),
           seeded.input == original {
            data = seeded.output
            self.seeded = nil
        } else {
            guard seeded == nil else { throw Failure.malformedNAL }
            data = try convertAccessUnit(original)
        }
        guard data.count <= Int(Int32.max) else { throw Failure.allocation }
        var replacement = av_packet_alloc()
        defer { av_packet_free(&replacement) }
        guard let replacement, av_new_packet(replacement, Int32(data.count)) >= 0,
              av_packet_copy_props(replacement, packet) >= 0 else { throw Failure.allocation }
        data.copyBytes(to: replacement.pointee.data, count: data.count)
        av_packet_unref(packet)
        av_packet_move_ref(packet, replacement)
    }

    func reset() { seeded = nil; flush() }

    func warm(packet: UnsafeMutablePointer<AVPacket>) throws {
        guard packet.pointee.size > 0, let bytes = packet.pointee.data else { throw Failure.malformedNAL }
        _ = try convertAccessUnit(Data(bytes: bytes, count: Int(packet.pointee.size)))
    }

    func seedFirst(packet: UnsafeMutablePointer<AVPacket>) throws {
        guard packet.pointee.size > 0, let bytes = packet.pointee.data else { throw Failure.malformedNAL }
        let input = Data(bytes: bytes, count: Int(packet.pointee.size))
        let output = try convertAccessUnit(input)
        seeded = (input, output, packet.pointee.pts, packet.pointee.dts, packet.pointee.pos)
    }
}

enum DolbyVisionConfiguration {
    static func isProfile7(_ parameters: AVCodecParameters) -> Bool {
        guard parameters.codec_id == AV_CODEC_ID_HEVC,
              let side = av_packet_side_data_get(parameters.coded_side_data, parameters.nb_coded_side_data, AV_PKT_DATA_DOVI_CONF),
              side.pointee.size >= 8, let data = side.pointee.data else { return false }
        return data[2] == 7 && data[4] != 0 && data[6] != 0
    }

    static func configureP81(_ parameters: UnsafeMutablePointer<AVCodecParameters>, frameRate: AVRational) throws {
        var size = 0
        guard let configuration = av_dovi_alloc(&size) else { throw DolbyVisionInlineConverter.Failure.allocation }
        let fps = frameRate.den > 0 ? Double(frameRate.num) / Double(frameRate.den) : 24
        configuration.pointee.dv_version_major = 1
        configuration.pointee.dv_version_minor = 0
        configuration.pointee.dv_profile = 8
        configuration.pointee.dv_level = fps <= 24.1 ? 6 : fps <= 30.1 ? 7 : fps <= 48.1 ? 8 : 9
        configuration.pointee.rpu_present_flag = 1
        configuration.pointee.el_present_flag = 0
        configuration.pointee.bl_present_flag = 1
        configuration.pointee.dv_bl_signal_compatibility_id = 1
        configuration.pointee.dv_md_compression = 0
        let bytes = UnsafeMutableRawPointer(configuration).assumingMemoryBound(to: UInt8.self)
        guard av_packet_side_data_add(&parameters.pointee.coded_side_data, &parameters.pointee.nb_coded_side_data,
            AV_PKT_DATA_DOVI_CONF, bytes, size, 0) != nil else {
            av_free(configuration)
            throw DolbyVisionInlineConverter.Failure.allocation
        }
    }
}
