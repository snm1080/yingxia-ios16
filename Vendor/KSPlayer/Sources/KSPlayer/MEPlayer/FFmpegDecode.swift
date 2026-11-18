//
//  FFmpegDecode.swift
//  KSPlayer
//
//  Created by kintan on 2018/3/9.
//

import AVFoundation
import Foundation
import FFmpegKit

class FFmpegDecode: DecodeProtocol {
    private let options: KSOptions
    private var coreFrame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private var bestEffortTimestamp = Int64(0)
    private let frameChange: FrameChange
    private let filter: MEFilter
    private let seekByBytes: Bool
    private let isVideo: Bool
    private var initError: Error?
    private var failureReported = false
    private var reportedDecoderName: String?
    // Dolby Vision profile 7 -> 8.1 inline conversion (reconstruction).
    // The FFmpegKit TVDolby bridge rewrites a profile-7 RPU NAL (HEVC type 62)
    // into a profile-8.1 RPU (dovi_tool mode 2: FEL mapping/NLQ stripped), so a
    // BL-only decode still gets a valid RPU; the EL NALs (type 63) are dropped.
    // Packets that fail conversion are passed through untouched.
    private var dolbyConverter: OpaquePointer?
    private let dolbyProfile7: Bool
    private let nalLengthSize: Int
    required init(assetTrack: FFmpegAssetTrack, options: KSOptions) {
        self.options = options
        seekByBytes = assetTrack.seekByBytes
        isVideo = assetTrack.mediaType == .video
        dolbyProfile7 = assetTrack.mediaType == .video && assetTrack.codecpar.codec_id == AV_CODEC_ID_HEVC && assetTrack.dovi?.dv_profile == 7
        var lengthSize = 0
        if assetTrack.codecpar.codec_id == AV_CODEC_ID_HEVC,
           let extradata = assetTrack.codecpar.extradata, assetTrack.codecpar.extradata_size >= 22, extradata[0] == 1
        {
            // hvcC: byte 21 holds lengthSizeMinusOne in its low two bits.
            lengthSize = Int(extradata[21] & 0x03) + 1
        }
        nalLengthSize = lengthSize
        do {
            codecContext = try assetTrack.createContext(options: options)
        } catch {
            initError = error
            KSLog(error as CustomStringConvertible)
        }
        codecContext?.pointee.time_base = assetTrack.timebase.rational
        filter = MEFilter(timebase: assetTrack.timebase, isAudio: assetTrack.mediaType == .audio, nominalFrameRate: assetTrack.nominalFrameRate, options: options)
        if assetTrack.mediaType == .video {
            frameChange = VideoSwresample(fps: assetTrack.nominalFrameRate, isDovi: assetTrack.dovi != nil)
        } else {
            frameChange = AudioSwresample(audioDescriptor: assetTrack.audioDescriptor!)
        }
    }

    func decodeFrame(from packet: Packet, completionHandler: @escaping (Result<MEFrame, Error>) -> Void) {
        guard let codecContext else {
            // No decoder could be initialised for this stream at all: report the
            // terminal failure once instead of silently swallowing every packet.
            if isVideo, !failureReported {
                failureReported = true
                if let initError {
                    options.onVideoDecoderError?(initError)
                }
                options.onVideoDecoderFailed?("视频解码器初始化失败，请切换解码方式或线路。")
            }
            return
        }
        if dolbyProfile7, let corePacket = packet.corePacket {
            convertProfile7Packet(corePacket)
        }
        guard avcodec_send_packet(codecContext, packet.corePacket) == 0 else {
            return
        }

        // 需要avcodec_send_packet之后，properties的值才会变成FF_CODEC_PROPERTY_CLOSED_CAPTIONS
        if packet.assetTrack.mediaType == .video {
            if Int32(codecContext.pointee.properties) & FF_CODEC_PROPERTY_CLOSED_CAPTIONS != 0, packet.assetTrack.closedCaptionsTrack == nil {
                var codecpar = AVCodecParameters()
                codecpar.codec_type = AVMEDIA_TYPE_SUBTITLE
                codecpar.codec_id = AV_CODEC_ID_EIA_608
                if let subtitleAssetTrack = FFmpegAssetTrack(codecpar: codecpar) {
                    subtitleAssetTrack.name = "Closed Captions"
                    subtitleAssetTrack.startTime = packet.assetTrack.startTime
                    subtitleAssetTrack.timebase = packet.assetTrack.timebase
                    let subtitle = SyncPlayerItemTrack<SubtitleFrame>(mediaType: .subtitle, frameCapacity: 255, options: options)
                    subtitleAssetTrack.subtitle = subtitle
                    packet.assetTrack.closedCaptionsTrack = subtitleAssetTrack
                    subtitle.decode()
                }
            }
        }

        while true {
            let result = avcodec_receive_frame(codecContext, coreFrame)
            if result == 0, let inputFrame = coreFrame {
                if isVideo {
                    // The negotiated frame format is the actual decode path:
                    // VideoToolbox-backed frames vs pure software frames.
                    let name = AVPixelFormat(rawValue: inputFrame.pointee.format) == AV_PIX_FMT_VIDEOTOOLBOX ? "FFmpeg VideoToolbox" : "FFmpeg software"
                    if name != reportedDecoderName {
                        reportedDecoderName = name
                        options.onVideoDecoderChanged?(name)
                    }
                }
                var displayData: MasteringDisplayMetadata?
                var contentData: ContentLightMetadata?
                var ambientViewingEnvironment: AmbientViewingEnvironment?

                // filter之后，side_data信息会丢失，所以放在这里
                if inputFrame.pointee.nb_side_data > 0 {
                    for i in 0 ..< inputFrame.pointee.nb_side_data {
                        if let sideData = inputFrame.pointee.side_data[Int(i)]?.pointee {
                            if sideData.type == AV_FRAME_DATA_A53_CC {
                                if let closedCaptionsTrack = packet.assetTrack.closedCaptionsTrack,
                                   let subtitle = closedCaptionsTrack.subtitle
                                {
                                    let closedCaptionsPacket = Packet()
                                    if let corePacket = packet.corePacket {
                                        closedCaptionsPacket.corePacket?.pointee.pts = corePacket.pointee.pts
                                        closedCaptionsPacket.corePacket?.pointee.dts = corePacket.pointee.dts
                                        closedCaptionsPacket.corePacket?.pointee.pos = corePacket.pointee.pos
                                        closedCaptionsPacket.corePacket?.pointee.time_base = corePacket.pointee.time_base
                                        closedCaptionsPacket.corePacket?.pointee.stream_index = corePacket.pointee.stream_index
                                    }
                                    closedCaptionsPacket.corePacket?.pointee.flags |= AV_PKT_FLAG_KEY
                                    closedCaptionsPacket.corePacket?.pointee.size = Int32(sideData.size)
                                    let buffer = av_buffer_ref(sideData.buf)
                                    closedCaptionsPacket.corePacket?.pointee.data = buffer?.pointee.data
                                    closedCaptionsPacket.corePacket?.pointee.buf = buffer
                                    closedCaptionsPacket.assetTrack = closedCaptionsTrack
                                    subtitle.putPacket(packet: closedCaptionsPacket)
                                }
                            } else if sideData.type == AV_FRAME_DATA_SEI_UNREGISTERED {
                                let size = sideData.size
                                if size > AV_UUID_LEN {
                                    let str = String(cString: sideData.data.advanced(by: Int(AV_UUID_LEN)))
                                    options.sei(string: str)
                                }
                            } else if sideData.type == AV_FRAME_DATA_DOVI_RPU_BUFFER {
                                let data = sideData.data.withMemoryRebound(to: [UInt8].self, capacity: 1) { $0 }
                            } else if sideData.type == AV_FRAME_DATA_DOVI_METADATA { // AVDOVIMetadata
                                let data = sideData.data.withMemoryRebound(to: AVDOVIMetadata.self, capacity: 1) { $0 }
                                let header = av_dovi_get_header(data)
                                let mapping = av_dovi_get_mapping(data)
                                let color = av_dovi_get_color(data)
                                // frame.corePixelBuffer?.transferFunction = kCVImageBufferTransferFunction_ITU_R_2020
                            } else if sideData.type == AV_FRAME_DATA_DYNAMIC_HDR_PLUS { // AVDynamicHDRPlus
                                let data = sideData.data.withMemoryRebound(to: AVDynamicHDRPlus.self, capacity: 1) { $0 }.pointee
                            } else if sideData.type == AV_FRAME_DATA_DYNAMIC_HDR_VIVID { // AVDynamicHDRVivid
                                let data = sideData.data.withMemoryRebound(to: AVDynamicHDRVivid.self, capacity: 1) { $0 }.pointee
                            } else if sideData.type == AV_FRAME_DATA_MASTERING_DISPLAY_METADATA {
                                let data = sideData.data.withMemoryRebound(to: AVMasteringDisplayMetadata.self, capacity: 1) { $0 }.pointee
                                displayData = MasteringDisplayMetadata(
                                    display_primaries_r_x: UInt16(truncatingIfNeeded: data.display_primaries.0.0.num).bigEndian,
                                    display_primaries_r_y: UInt16(truncatingIfNeeded: data.display_primaries.0.1.num).bigEndian,
                                    display_primaries_g_x: UInt16(truncatingIfNeeded: data.display_primaries.1.0.num).bigEndian,
                                    display_primaries_g_y: UInt16(truncatingIfNeeded: data.display_primaries.1.1.num).bigEndian,
                                    display_primaries_b_x: UInt16(truncatingIfNeeded: data.display_primaries.2.0.num).bigEndian,
                                    display_primaries_b_y: UInt16(truncatingIfNeeded: data.display_primaries.2.1.num).bigEndian,
                                    white_point_x: UInt16(truncatingIfNeeded: data.white_point.0.num).bigEndian,
                                    white_point_y: UInt16(truncatingIfNeeded: data.white_point.1.num).bigEndian,
                                    minLuminance: UInt32(truncatingIfNeeded: data.min_luminance.num).bigEndian,
                                    maxLuminance: UInt32(truncatingIfNeeded: data.max_luminance.num).bigEndian
                                )
                            } else if sideData.type == AV_FRAME_DATA_CONTENT_LIGHT_LEVEL {
                                let data = sideData.data.withMemoryRebound(to: AVContentLightMetadata.self, capacity: 1) { $0 }.pointee
                                contentData = ContentLightMetadata(
                                    MaxCLL: UInt16(truncatingIfNeeded: data.MaxCLL).bigEndian,
                                    MaxFALL: UInt16(truncatingIfNeeded: data.MaxFALL).bigEndian
                                )
                            } else if sideData.type == AV_FRAME_DATA_AMBIENT_VIEWING_ENVIRONMENT {
                                let data = sideData.data.withMemoryRebound(to: AVAmbientViewingEnvironment.self, capacity: 1) { $0 }.pointee
                                ambientViewingEnvironment = AmbientViewingEnvironment(
                                    ambient_illuminance: UInt32(truncatingIfNeeded: data.ambient_illuminance.num).bigEndian,
                                    ambient_light_x: UInt16(truncatingIfNeeded: data.ambient_light_x.num).bigEndian,
                                    ambient_light_y: UInt16(truncatingIfNeeded: data.ambient_light_y.num).bigEndian
                                )
                            }
                        }
                    }
                }

                filter.filter(options: options, inputFrame: inputFrame) { avframe in
                    do {
                        var frame = try frameChange.change(avframe: avframe)
                        if let videoFrame = frame as? VideoVTBFrame, let pixelBuffer = videoFrame.corePixelBuffer {
                            if let pixelBuffer = pixelBuffer as? PixelBuffer {
                                pixelBuffer.formatDescription = packet.assetTrack.formatDescription
                            }
                            if displayData != nil || contentData != nil || ambientViewingEnvironment != nil {
                                videoFrame.edrMetaData = EDRMetaData(displayData: displayData, contentData: contentData, ambientViewingEnvironment: ambientViewingEnvironment)
                            }
                        }
                        frame.timebase = filter.timebase
                        // frame.timebase = Timebase(avframe.pointee.time_base)
                        frame.size = packet.size
                        frame.position = packet.position
                        frame.duration = avframe.pointee.duration
                        if frame.duration == 0, avframe.pointee.sample_rate != 0, frame.timebase.num != 0 {
                            frame.duration = Int64(avframe.pointee.nb_samples) * Int64(frame.timebase.den) / (Int64(avframe.pointee.sample_rate) * Int64(frame.timebase.num))
                        }
                        var timestamp = avframe.pointee.best_effort_timestamp
                        if timestamp < 0 {
                            timestamp = avframe.pointee.pts
                        }
                        // AVFrame.pkt_dts was removed by FFmpeg 8; the
                        // best-effort/pts chain above already covers ordering.
                        if timestamp < 0 {
                            timestamp = bestEffortTimestamp
                        }
                        frame.timestamp = timestamp
                        bestEffortTimestamp = timestamp &+ frame.duration
                        completionHandler(.success(frame))
                    } catch {
                        completionHandler(.failure(error))
                    }
                }
            } else {
                if result == AVError.eof.code {
                    avcodec_flush_buffers(codecContext)
                    break
                } else if result == AVError.tryAgain.code {
                    break
                } else {
                    let error = NSError(errorCode: packet.assetTrack.mediaType == .audio ? .codecAudioReceiveFrame : .codecVideoReceiveFrame, avErrorCode: result)
                    KSLog(error)
                    completionHandler(.failure(error))
                }
            }
        }
    }

    /// Rewrites one profile-7 HEVC packet in place: EL NALs (type 63) are
    /// dropped and RPU NALs (type 62) are converted to profile 8.1 through the
    /// TVDolby bridge. Any structural surprise or conversion error leaves the
    /// packet exactly as it was.
    private func convertProfile7Packet(_ corePacket: UnsafeMutablePointer<AVPacket>) {
        guard let data = corePacket.pointee.data, corePacket.pointee.size > 2 else { return }
        let size = Int(corePacket.pointee.size)
        // Split the packet into NAL units (payload offset/length pairs).
        var nals: [(offset: Int, length: Int)] = []
        if nalLengthSize > 0 {
            var offset = 0
            while offset + nalLengthSize <= size {
                var length = 0
                for index in 0 ..< nalLengthSize {
                    length = (length << 8) | Int(data[offset + index])
                }
                offset += nalLengthSize
                guard length > 2, offset + length <= size else { return }
                nals.append((offset, length))
                offset += length
            }
            guard offset == size, !nals.isEmpty else { return }
        } else {
            // Annex B: locate start codes; a NAL runs to the next start code.
            var payloadStarts: [Int] = []
            var codeStarts: [Int] = []
            var index = 0
            while index + 3 <= size {
                if data[index] == 0, data[index + 1] == 0, data[index + 2] == 1 {
                    codeStarts.append(index)
                    payloadStarts.append(index + 3)
                    index += 3
                } else if index + 4 <= size, data[index] == 0, data[index + 1] == 0, data[index + 2] == 0, data[index + 3] == 1 {
                    codeStarts.append(index)
                    payloadStarts.append(index + 4)
                    index += 4
                } else {
                    index += 1
                }
            }
            guard !payloadStarts.isEmpty else { return }
            for position in payloadStarts.indices {
                let end = position + 1 < codeStarts.count ? codeStarts[position + 1] : size
                let length = end - payloadStarts[position]
                guard length > 2 else { return }
                nals.append((payloadStarts[position], length))
            }
        }
        func nalType(_ nal: (offset: Int, length: Int)) -> Int {
            Int((data[nal.offset] >> 1) & 0x3F)
        }
        guard nals.contains(where: { nalType($0) == 62 || nalType($0) == 63 }) else { return }
        if dolbyConverter == nil {
            dolbyConverter = tv_dolby_converter_create()
        }
        guard let converter = dolbyConverter else { return }
        var output = Data()
        output.reserveCapacity(size)
        for nal in nals {
            let type = nalType(nal)
            if type == 63 {
                continue
            }
            var payload = Data(bytes: data + nal.offset, count: nal.length)
            if type == 62 {
                var converted: UnsafeMutablePointer<UInt8>?
                var convertedSize = 0
                if tv_dolby_convert_p7_to_p81(converter, data + nal.offset, nal.length, &converted, &convertedSize) >= 0, let converted {
                    payload = Data(bytes: converted, count: convertedSize)
                    av_free(converted)
                }
            }
            if nalLengthSize > 0 {
                var remaining = payload.count
                var prefix = [UInt8](repeating: 0, count: nalLengthSize)
                for position in (0 ..< nalLengthSize).reversed() {
                    prefix[position] = UInt8(remaining & 0xFF)
                    remaining >>= 8
                }
                output.append(contentsOf: prefix)
            } else {
                output.append(contentsOf: [0, 0, 0, 1] as [UInt8])
            }
            output.append(payload)
        }
        guard let replacement = av_packet_alloc() else { return }
        defer { var temp: UnsafeMutablePointer<AVPacket>? = replacement; av_packet_free(&temp) }
        guard av_new_packet(replacement, Int32(output.count)) == 0 else { return }
        output.withUnsafeBytes { source in
            if let base = source.baseAddress, let target = replacement.pointee.data {
                target.assign(from: base.assumingMemoryBound(to: UInt8.self), count: output.count)
            }
        }
        guard av_packet_copy_props(replacement, corePacket) == 0 else { return }
        av_packet_unref(corePacket)
        av_packet_move_ref(corePacket, replacement)
    }

    func doFlushCodec() {
        bestEffortTimestamp = Int64(0)
        // seek之后要清空下，不然解码可能还会有缓存，导致返回的数据是之前seek的。
        avcodec_flush_buffers(codecContext)
        if let dolbyConverter {
            tv_dolby_converter_flush(dolbyConverter)
        }
    }

    func shutdown() {
        av_frame_free(&coreFrame)
        avcodec_free_context(&codecContext)
        tv_dolby_converter_free(&dolbyConverter)
        frameChange.shutdown()
    }

    func decode() {
        bestEffortTimestamp = Int64(0)
        if codecContext != nil {
            avcodec_flush_buffers(codecContext)
        }
        if let dolbyConverter {
            tv_dolby_converter_flush(dolbyConverter)
        }
    }
}
