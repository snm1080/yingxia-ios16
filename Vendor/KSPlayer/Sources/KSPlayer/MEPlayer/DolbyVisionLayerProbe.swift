import Foundation
import FFmpegKit

/// A demuxed packet retained during the bounded, initial Dolby layer probe.
/// Moving its reference back to the reader preserves timestamps and side data.
final class DolbyVisionProbePacket {
    private var packet: UnsafeMutablePointer<AVPacket>?

    init?(copying original: UnsafeMutablePointer<AVPacket>) {
        packet = av_packet_clone(original)
        if packet == nil { return nil }
    }

    func move(to destination: UnsafeMutablePointer<AVPacket>) {
        guard let packet else { return }
        av_packet_move_ref(destination, packet)
    }

    deinit { av_packet_free(&packet) }
}

enum DolbyVisionLayerProbe {
    struct Pair {
        let baseTrackID: Int32
        let enhancementTrackID: Int32
    }

    struct Result {
        var pair: Pair?
        var packets: [DolbyVisionProbePacket] = []
    }

    /// UHD Blu-ray authors primary HEVC on 0x1011 and Dolby enhancement on
    /// 0x1015. This only permits inspection; the PIDs do not prove Dolby.
    /// Require both HDMV streams in the same program before reading packets.
    static func candidate(in format: UnsafeMutablePointer<AVFormatContext>) -> Pair? {
        guard let streams = format.pointee.streams, let programs = format.pointee.programs else { return nil }
        for index in 0 ..< Int(format.pointee.nb_programs) {
            guard let program = programs[index], let indices = program.pointee.stream_index else { continue }
            var base: Int32?
            var enhancement: Int32?
            for offset in 0 ..< Int(program.pointee.nb_stream_indexes) {
                let streamIndex = Int(indices[offset])
                guard streamIndex < format.pointee.nb_streams, let stream = streams[streamIndex],
                      let parameters = stream.pointee.codecpar,
                      parameters.pointee.codec_type == AVMEDIA_TYPE_VIDEO,
                      parameters.pointee.codec_id == AV_CODEC_ID_HEVC,
                      parameters.pointee.codec_tag == 0x564D4448 // HDMV registration, FFmpeg byte order.
                else { continue }
                if stream.pointee.id == 0x1011 { base = stream.pointee.index }
                if stream.pointee.id == 0x1015 { enhancement = stream.pointee.index }
            }
            if let base, let enhancement { return Pair(baseTrackID: base, enhancementTrackID: enhancement) }
        }
        return nil
    }

    static func isFullEnhancementLayer(_ header: AVDOVIRpuDataHeader) -> Bool {
        // Same P7 inference as FFmpeg dovi_rpu.c, scoped to the authored
        // separate HDMV enhancement stream. P5 and single-layer P8 are excluded.
        header.rpu_type == 2 && header.vdr_rpu_profile == 1
            && header.el_spatial_resampling_filter_flag != 0
            && header.disable_residual_flag == 0 && header.vdr_bit_depth == 12
    }

    static func inspect(format: UnsafeMutablePointer<AVFormatContext>, maximumPackets: Int = 256,
                        maximumBytes: Int = 4 * 1024 * 1024, deadline: TimeInterval) -> Result {
        var result = Result()
        guard let pair = candidate(in: format), maximumPackets > 0, maximumBytes > 0,
              let stream = format.pointee.streams[Int(pair.enhancementTrackID)],
              let parameters = stream.pointee.codecpar,
              let codec = avcodec_find_decoder(AV_CODEC_ID_HEVC)
        else { return result }
        var context = avcodec_alloc_context3(codec)
        var frame = av_frame_alloc()
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet); av_frame_free(&frame); avcodec_free_context(&context) }
        guard let context, let frame, let packet,
              avcodec_parameters_to_context(context, parameters) >= 0 else { return result }
        // Parse the original RPU with FFmpeg. No hardware decode, display,
        // second playback instance, or persistent cache is created for this probe.
        context.pointee.thread_count = 1
        context.pointee.flags |= AV_CODEC_FLAG_LOW_DELAY
        guard avcodec_open2(context, codec, nil) >= 0 else { return result }
        var totalBytes = 0
        while result.packets.count < maximumPackets, totalBytes < maximumBytes,
              ProcessInfo.processInfo.systemUptime < deadline {
            guard av_read_frame(format, packet) >= 0 else { break }
            guard let saved = DolbyVisionProbePacket(copying: packet) else {
                av_packet_unref(packet)
                break
            }
            result.packets.append(saved)
            totalBytes += max(0, Int(packet.pointee.size))
            if packet.pointee.stream_index == pair.enhancementTrackID {
                let sent = avcodec_send_packet(context, packet)
                if sent >= 0 {
                    while avcodec_receive_frame(context, frame) >= 0 {
                        if let metadata = av_frame_get_side_data(frame, AV_FRAME_DATA_DOVI_METADATA),
                           metadata.pointee.size >= MemoryLayout<AVDOVIMetadata>.size,
                           let bytes = metadata.pointee.data {
                            let data = UnsafeRawPointer(bytes).assumingMemoryBound(to: AVDOVIMetadata.self)
                            if let header = av_dovi_get_header(data), isFullEnhancementLayer(header.pointee) {
                                result.pair = pair
                            }
                        }
                        av_frame_unref(frame)
                        if result.pair != nil { break }
                    }
                }
            }
            av_packet_unref(packet)
            if result.pair != nil { break }
        }
        return result
    }
}
