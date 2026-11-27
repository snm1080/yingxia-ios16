//
//  FFmpegDecode.swift
//  KSPlayer
//
//  Created by kintan on 2018/3/9.
//

import AVFoundation
import CoreVideo
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
    // Build 45: the same machinery now also absorbs a hard VT session
    // failure — avcodec reporting AVERROR_UNKNOWN (-1313558101), which is
    // what FFmpeg 8.1's videotoolbox hwaccel returns when
    // VTDecompressionSessionDecodeFrame fails (bad data / decoder
    // malfunction / invalid session; the raw OSStatus is only in
    // FFmpeg's own log). Build 44's on-device sessions showed this error
    // killing playback within the first GOP after a start/seek on some
    // files, deterministically at the same position across wholesale
    // app-level retries (which re-feed the same GOP into a fresh
    // session). Rebuilding here and dropping to the NEXT keyframe
    // changes the input, which is what breaks the determinism. Bounded
    // per decoder instance; once the budget is spent the error surfaces
    // exactly as before.
    private var starvedVideoPackets = 0
    private var awaitingRebuildKeyFrame = false
    private var decoderRebuildCount = 0
    private var nativeCodecErrorRebuilds = 0
    private var pendingRebuildReason = "starved"
    // Build 42: one-time Dolby path diagnostic state.
    private var sawDolbyRPUBuffer = false
    private var reportedDolbyPath = false
    // Build 43: one-time RPU/frame dump state (black-picture localization).
    private var reportedDolbyDump = false
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
            if shouldRebuildForNativeCodecError(mediaType: packet.assetTrack.mediaType, error: sendResult) { return }
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
                    // Build 43: colour-stage reports the settings bypass
                    // as its own value so an export shows which renderer
                    // the session actually used.
                    let colourStage = dolbyMetadata == nil ? "off" : (options.dolbyVisionColorStageEnabled ? "on" : "bypass-legacy")
                    options.onPlaybackDiagnostic?("dv ffmpeg format=\(formatName) rpu=\(dolbyMetadata != nil ? "parsed" : "absent") rpu-buffer=\(sawDolbyRPUBuffer ? "present" : "absent") colour-stage=\(colourStage)")
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
                            if let dolbyMetadata, !reportedDolbyDump {
                                reportedDolbyDump = true
                                // Build 43: one-shot per-session dumps so a
                                // black picture can be localized from the
                                // diagnostics export alone: what the RPU
                                // parse produced (values, not presence),
                                // and whether the decoded base layer itself
                                // carries picture before any shader runs.
                                let cvBuffer = pixelBuffer.cvPixelBuffer
                                let planes = cvBuffer.map { CVPixelBufferGetPlaneCount($0) } ?? pixelBuffer.planeCount
                                let formatCode = cvBuffer.map { Self.fourCC(CVPixelBufferGetPixelFormatType($0)) } ?? "unknown"
                                options.onPlaybackDiagnostic?("dv rpu-dump \(dolbyMetadata.diagnosticSummary) planes=\(planes) format=\(formatCode)")
                                if let cvBuffer {
                                    options.onPlaybackDiagnostic?("dv frame-dump \(Self.frameSampleStats(cvBuffer))")
                                }
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
                    if shouldRebuildForNativeCodecError(mediaType: packet.assetTrack.mediaType, error: result) { break }
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
                pendingRebuildReason = "starved"
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
        options.onPlaybackDiagnostic?("decoder rebuild count=\(decoderRebuildCount) reason=\(pendingRebuildReason)")
        pendingRebuildReason = "starved"
    }

    /// Build 45: is this error a dead VideoToolbox session behind the
    /// FFmpeg hwaccel? FFmpeg 8.1's videotoolbox end-frame maps every
    /// VTDecompressionSessionDecodeFrame failure (bad data, decoder
    /// malfunction, invalid session) to AVERROR_UNKNOWN (-1313558101)
    /// and returns it from send/receive; the app used to surface it as
    /// the terminal 「当前设备无法解码这条杜比视界视频」. Absorb it
    /// instead: arm the build-42 rebuild at the next keyframe and drop
    /// the offending packet/GOP silently (the resync paths set the
    /// no-completion-handler precedent). Gated to video contexts that
    /// actually carry a VT hw device, so software decode and audio keep
    /// build-44 behaviour exactly. Budget: 4 rebuilds per decoder
    /// instance; past that, return false and let the error surface.
    private func shouldRebuildForNativeCodecError(mediaType: AVFoundation.AVMediaType, error: Int32) -> Bool {
        guard mediaType == .video, error == AVError.unknown.code,
              codecContext?.pointee.hw_device_ctx != nil else { return false }
        guard nativeCodecErrorRebuilds < 4 else { return false }
        nativeCodecErrorRebuilds += 1
        awaitingRebuildKeyFrame = true
        pendingRebuildReason = "native-codec-error"
        starvedVideoPackets = 0
        KSLog("FFmpegDecode: VT session failed (AVERROR_UNKNOWN); rebuilding codec context at next keyframe (\(nativeCodecErrorRebuilds)/4)")
        options.onPlaybackDiagnostic?("decoder rebuild reason=native-codec-error count=\(nativeCodecErrorRebuilds)")
        return true
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

    /// Build 43: renders a pixel format OSType as its four-character code
    /// when printable, else as hex.
    private static func fourCC(_ code: OSType) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF),
        ]
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }),
           let string = String(bytes: bytes, encoding: .ascii)
        {
            return string
        }
        return String(format: "0x%08x", code)
    }

    /// Build 43: min/max sample values of one decoded frame's planes,
    /// read straight from the CVPixelBuffer (strided scan, first Dolby
    /// frame of a session only). Ten-bit samples are reported as 10-bit
    /// code values (stored value >> 6). A base layer that is already
    /// black before the shader shows up here as a collapsed range.
    private static func frameSampleStats(_ pixelBuffer: CVPixelBuffer) -> String {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let tenBit = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        let eightBit = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        guard tenBit || eightBit else { return "stats=unsupported-format" }
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            return "stats=lock-failed"
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        var segments: [String] = []
        for plane in 0 ..< CVPixelBufferGetPlaneCount(pixelBuffer) {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) else { continue }
            let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
            let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
            let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
            var lo = Int.max
            var hi = Int.min
            if tenBit {
                for y in stride(from: 0, to: height, by: 2) {
                    let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt16.self)
                    var x = 0
                    while x < width {
                        let value = Int(row[x]) >> 6
                        if value < lo { lo = value }
                        if value > hi { hi = value }
                        x += 2
                    }
                }
            } else {
                for y in stride(from: 0, to: height, by: 2) {
                    let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                    var x = 0
                    while x < width {
                        let value = Int(row[x])
                        if value < lo { lo = value }
                        if value > hi { hi = value }
                        x += 2
                    }
                }
            }
            let label = plane == 0 ? "y" : (plane == 1 ? "cbcr" : "p\(plane)")
            segments.append("\(label)=[\(lo),\(hi)]")
        }
        return segments.joined(separator: " ")
    }
}
