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
    private let assetTrack: FFmpegAssetTrack
    private let hardwareDecodeOption: Bool?
    private var coreFrame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private var bestEffortTimestamp = Int64(0)
    private let frameChange: FrameChange
    private let filter: MEFilter
    private let seekByBytes: Bool
    private var reportedVideoDecoder: String?
    private var audioResynchronizationPackets = 8
    private var liveResynchronizationPackets = 8
    private var awaitingLiveVideoKeyFrame = false
    // Build 42: decoder-level recovery. A VideoToolbox session behind the
    // FFmpeg hwaccel can wedge the same way the native session does — it
    // keeps accepting packets but returns no frames. Count consecutive
    // frame-less video packets; at the build-29 threshold (120) rebuild the
    // codec context here and resume at the next keyframe (the PlayKit
    // pattern) instead of relying on the app-level wholesale reopen.
    private var starvedVideoPackets = 0
    private var awaitingRebuildKeyFrame = false
    private var decoderRebuildCount = 0
    // Build 42: one-time Dolby path diagnostic state.
    private var sawDolbyRPUBuffer = false
    private var reportedDolbyPath = false
    required init(assetTrack: FFmpegAssetTrack, options: KSOptions, hardwareDecode: Bool? = nil) {
        self.options = options
        self.assetTrack = assetTrack
        hardwareDecodeOption = hardwareDecode
        seekByBytes = assetTrack.seekByBytes
        do {
            codecContext = try assetTrack.createContext(options: options, hardwareDecode: hardwareDecode)
        } catch {
            KSLog(error as CustomStringConvertible)
        }
        codecContext?.pointee.time_base = assetTrack.timebase.rational
        filter = MEFilter(timebase: assetTrack.timebase, isAudio: assetTrack.mediaType == .audio, nominalFrameRate: assetTrack.nominalFrameRate, options: options)
        if assetTrack.mediaType == .video {
            frameChange = VideoSwresample(fps: assetTrack.nominalFrameRate, isDovi: assetTrack.dovi != nil,
                                          preferBiPlanar420: assetTrack.codecpar.codec_id == AV_CODEC_ID_AV1)
        } else {
            frameChange = AudioSwresample(audioDescriptor: assetTrack.audioDescriptor!)
        }
    }

    func decodeFrame(from packet: Packet, completionHandler: @escaping (Result<MEFrame, Error>) -> Void) {
        if awaitingRebuildKeyFrame {
            // Drop packets silently (the prepareLivePacket precedent) until a
            // keyframe lets the rebuilt context resume cleanly. If the
            // rebuild failed, codecContext is nil and the guard below turns
            // this keyframe into the terminal decoder error.
            guard packet.isKeyFrame else { return }
            rebuildCodecContext()
            awaitingRebuildKeyFrame = false
        }
        guard let codecContext else {
            completionHandler(.failure(NSError(description: "The media decoder could not be opened.")))
            return
        }
        guard prepareLivePacket(packet) else { return }
        let sendResult = avcodec_send_packet(codecContext, packet.corePacket)
        if sendResult < 0, sendResult != AVError.tryAgain.code {
            if shouldResynchronizePacket(mediaType: packet.assetTrack.mediaType, error: sendResult) { return }
            completionHandler(.failure(NSError(errorCode: packet.assetTrack.mediaType == .audio ? .codecAudioReceiveFrame : .codecVideoReceiveFrame, avErrorCode: sendResult)))
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

        var producedFrame = false
        while true {
            let result = avcodec_receive_frame(codecContext, coreFrame)
            if result == 0, let inputFrame = coreFrame {
                guard acceptLiveFrame(mediaType: packet.assetTrack.mediaType,
                    corrupt: inputFrame.pointee.flags & AV_FRAME_FLAG_CORRUPT != 0) else { continue }
                producedFrame = true
                if packet.assetTrack.mediaType == .audio { audioResynchronizationPackets = 0 }
                if packet.assetTrack.mediaType == .video {
                    let decoder = inputFrame.pointee.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue ? "VideoToolbox (FFmpeg)" : "FFmpeg software"
                    if reportedVideoDecoder != decoder {
                        reportedVideoDecoder = decoder
                        options.onVideoDecoderChanged?(decoder)
                    }
                }
                var displayData: MasteringDisplayMetadata?
                var contentData: ContentLightMetadata?
                var ambientViewingEnvironment: AmbientViewingEnvironment?
                var dolbyMetadata: DolbyVisionFrameMetadata?

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
                                // The raw RPU bytes are superseded by the parsed
                                // AVDOVIMetadata below; presence noted for logging.
                                sawDolbyRPUBuffer = true
                            } else if sideData.type == AV_FRAME_DATA_DOVI_METADATA { // AVDOVIMetadata
                                // Build 42: parse the RPU instead of discarding
                                // it; the GPU colour stage consumes it per frame.
                                let data = sideData.data.withMemoryRebound(to: AVDOVIMetadata.self, capacity: 1) { $0 }
                                dolbyMetadata = DolbyVisionFrameMetadata.parse(data)
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

                if packet.assetTrack.dovi != nil, !reportedDolbyPath {
                    reportedDolbyPath = true
                    let formatName = inputFrame.pointee.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue ? "videotoolbox" : "software"
                    options.onPlaybackDiagnostic?("dv ffmpeg format=\(formatName) rpu=\(dolbyMetadata != nil ? "parsed" : "absent") rpu-buffer=\(sawDolbyRPUBuffer ? "present" : "absent") colour-stage=\(dolbyMetadata != nil ? "on" : "off")")
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
                            videoFrame.dolbyVision = dolbyMetadata
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
                        if timestamp < 0 {
                            timestamp = avframe.pointee.pkt_dts
                        }
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
                    filter.flush()
                    break
                } else if result == AVError.tryAgain.code {
                    break
                } else {
                    if shouldResynchronizePacket(mediaType: packet.assetTrack.mediaType, error: result) { break }
                    let error = NSError(errorCode: packet.assetTrack.mediaType == .audio ? .codecAudioReceiveFrame : .codecVideoReceiveFrame, avErrorCode: result)
                    KSLog(error)
                    completionHandler(.failure(error))
                    break
                }
            }
        }
        noteDecodeProgress(mediaType: packet.assetTrack.mediaType, producedFrame: producedFrame)
    }

    /// Build 42: wedge detection for the FFmpeg decode path. A healthy
    /// decoder emits a frame within a few packets of any packet (B-frame
    /// reorder depth is far below this threshold); 120 consecutive
    /// frame-less video packets means the session behind the hwaccel is
    /// wedged. Arm a decoder-level rebuild at the next keyframe.
    private func noteDecodeProgress(mediaType: AVFoundation.AVMediaType, producedFrame: Bool) {
        guard mediaType == .video else { return }
        if producedFrame {
            starvedVideoPackets = 0
        } else if !awaitingRebuildKeyFrame {
            starvedVideoPackets += 1
            if starvedVideoPackets >= 120 {
                awaitingRebuildKeyFrame = true
                KSLog("FFmpegDecode: no frames for 120 consecutive packets; rebuilding codec context at next keyframe")
                options.onPlaybackDiagnostic?("decoder starved packets=120 rebuild=armed")
            }
        }
    }

    private func rebuildCodecContext() {
        avcodec_free_context(&codecContext)
        do {
            codecContext = try assetTrack.createContext(options: options, hardwareDecode: hardwareDecodeOption)
            codecContext?.pointee.time_base = assetTrack.timebase.rational
        } catch {
            KSLog(error as CustomStringConvertible)
            codecContext = nil
        }
        filter.flush()
        starvedVideoPackets = 0
        decoderRebuildCount += 1
        KSLog("FFmpegDecode: codec context rebuilt (count \(decoderRebuildCount))")
        options.onPlaybackDiagnostic?("decoder rebuild count=\(decoderRebuildCount) reason=starved")
    }

    private func prepareLivePacket(_ packet: Packet) -> Bool {
        guard options.isLiveStreaming else { return true }
        if (packet.corePacket?.pointee.flags ?? 0) & AV_PKT_FLAG_CORRUPT != 0 {
            // MPEG-TS continuity/PES loss cannot be repaired by a decoder.
            // Discard the damaged references and wait for a clean random access
            // point; the app's output deadline bounds an absent next keyframe.
            avcodec_flush_buffers(codecContext)
            filter.flush()
            if packet.assetTrack.mediaType == .video { awaitingLiveVideoKeyFrame = true }
            return false
        }
        if packet.assetTrack.mediaType == .video, awaitingLiveVideoKeyFrame {
            guard packet.isKeyFrame else { return false }
            awaitingLiveVideoKeyFrame = false
        }
        return true
    }

    private func shouldResynchronizePacket(mediaType: AVFoundation.AVMediaType, error: Int32) -> Bool {
        guard options.isLiveStreaming, error == AVError.invalidData.code else {
            return shouldResynchronizeAudio(mediaType: mediaType, error: error)
        }
        guard liveResynchronizationPackets > 0 else { return false }
        liveResynchronizationPackets -= 1
        avcodec_flush_buffers(codecContext)
        filter.flush()
        if mediaType == .video { awaitingLiveVideoKeyFrame = true }
        return true
    }

    private func acceptLiveFrame(mediaType: AVFoundation.AVMediaType, corrupt: Bool) -> Bool {
        guard options.isLiveStreaming else { return true }
        if corrupt {
            avcodec_flush_buffers(codecContext)
            filter.flush()
            if mediaType == .video { awaitingLiveVideoKeyFrame = true }
            return false
        }
        liveResynchronizationPackets = 8
        return true
    }

    private func shouldResynchronizeAudio(mediaType: AVFoundation.AVMediaType, error: Int32) -> Bool {
        // MPEG-PS byte-level resynchronization may return one partial MP2
        // packet after seeking. FFmpeg accepts the next complete frame on the
        // same context. Never turn that leading fragment into a dead track.
        // Keep this bounded and close the allowance as soon as audio decodes.
        guard mediaType == .audio, error == AVError.invalidData.code, audioResynchronizationPackets > 0 else { return false }
        audioResynchronizationPackets -= 1
        return true
    }

    func doFlushCodec() {
        audioResynchronizationPackets = 8
        liveResynchronizationPackets = 8
        awaitingLiveVideoKeyFrame = false
        starvedVideoPackets = 0
        awaitingRebuildKeyFrame = false
        bestEffortTimestamp = Int64(0)
        // seek之后要清空下，不然解码可能还会有缓存，导致返回的数据是之前seek的。
        avcodec_flush_buffers(codecContext)
        filter.flush()
    }

    func shutdown() {
        filter.flush()
        av_frame_free(&coreFrame)
        avcodec_free_context(&codecContext)
        frameChange.shutdown()
    }

    func decode() {
        audioResynchronizationPackets = 8
        liveResynchronizationPackets = 8
        awaitingLiveVideoKeyFrame = false
        starvedVideoPackets = 0
        awaitingRebuildKeyFrame = false
        bestEffortTimestamp = Int64(0)
        filter.flush()
        if codecContext != nil {
            avcodec_flush_buffers(codecContext)
        }
    }
}
