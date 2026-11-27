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

/// Build 47: the last real VideoToolbox OSStatus behind an
/// AVERROR_UNKNOWN, scraped from FFmpeg's own av_log output.
/// FFmpeg 8.1's videotoolbox hwaccel (ff_videotoolbox_common_end_frame)
/// logs `Failed to decode frame (<name>, <status>)` at error level
/// when VTDecompressionSessionDecodeFrame fails, and its output
/// callback logs `vt decoder cb: output image buffer is null:
/// <status>, reconfig <0|1>` at warning level when a frame comes
/// back empty — in both cases immediately before returning the
/// AVERROR_UNKNOWN that is all Swift ever sees. The av_log callback
/// in MEPlayerItem forwards those two lines here; FFmpegDecode's
/// native-codec witness line consumes the value, so a status is
/// attached to exactly one sighting. Thread-safe: the av_log
/// callback can fire on any FFmpeg thread, the read happens on the
/// decode thread in the same call stack that produced the error.
final class VTDecodeFailureLog {
    static let shared = VTDecodeFailureLog()
    private let lock = NSLock()
    private var status: Int32?
    private var recordedAt = Date.distantPast

    private init() {}

    func record(formattedLine: String) {
        guard let parsed = Self.parse(formattedLine) else { return }
        lock.lock()
        status = parsed
        recordedAt = Date()
        lock.unlock()
    }

    /// The most recent status if it is at most 5 seconds old;
    /// consuming clears it either way, so a stale status is never
    /// attached to a later, unrelated sighting.
    func consumeRecentStatus() -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        guard let status, Date().timeIntervalSince(recordedAt) <= 5 else {
            self.status = nil
            return nil
        }
        self.status = nil
        return status
    }

    private static func parse(_ line: String) -> Int32? {
        // "Failed to decode frame (bad data, -12909)"
        if line.hasPrefix("Failed to decode frame") {
            guard let open = line.lastIndex(of: "("), let close = line.lastIndex(of: ")"), open < close else { return nil }
            let inner = line[line.index(after: open) ..< close]
            guard let last = inner.split(separator: ",").last else { return nil }
            return Int32(last.trimmingCharacters(in: .whitespaces))
        }
        // "vt decoder cb: output image buffer is null: -12909, reconfig 1"
        let callbackPrefix = "vt decoder cb: output image buffer is null:"
        if line.hasPrefix(callbackPrefix) {
            let rest = line.dropFirst(callbackPrefix.count)
            guard let first = rest.split(separator: ",").first else { return nil }
            return Int32(first.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}

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
    // Build 46: on device, build 45's absorption never fired — its
    // hw_device_ctx gate read nil even in sessions actively producing
    // VideoToolbox frames. The gate now uses decoder-recorded state
    // and every AVERROR_UNKNOWN sighting emits a witness line
    // (`dv nativecodec seen site=… absorbed=… reason=…`); see
    // shouldRebuildForNativeCodecError and UPSTREAM.md.
    // Build 47: build 46's absorption fired, but at a poisoned stream
    // position every rebuilt context re-failed within a packet or two
    // (Sam's build-46 export: 4 clusters of 15–35 sightings, each
    // burning the whole budget of 4 against rebuilds that produced
    // zero frames, then the app-level reopen repeating the cycle —
    // while the export's two isolated incidents were cured by a
    // single rebuild each). The rebuild now escalates how much
    // stream it drops: a context that fails again before proving
    // itself (30 frame-producing packets) makes the next rebuild
    // skip extra GOPs (0, 1, 2, 4), so the budget of 4 spans ~11
    // GOPs instead of 4; a context that does prove itself restores
    // the budget (budget per genuinely-rebuilt session). Sightings
    // that arrive while a rebuild is already pending are absorbed
    // without consuming budget (`absorbed=pending`), and the witness
    // line gains `vtstatus=` — the real VideoToolbox OSStatus FFmpeg
    // logs just before collapsing it to AVERROR_UNKNOWN, scraped by
    // VTDecodeFailureLog. See UPSTREAM.md.
    private var starvedVideoPackets = 0
    private var awaitingRebuildKeyFrame = false
    private var decoderRebuildCount = 0
    private var nativeCodecErrorRebuilds = 0
    private var pendingRebuildReason = "starved"
    // Build 47: native-codec incident state. framesSinceRebuild
    // counts frame-producing video packets since the current codec
    // context was created (init or last rebuild); 30 is the proof
    // threshold — a healthy context produces frames continuously,
    // while build 46's poisoned rebuilds died within 1–2 packets.
    private var nativeCodecFramesSinceRebuild = 0
    private var nativeCodecFramelessStreak = 0
    private var pendingRebuildSkipKeyFrames = 0
    private var nativeCodecPendingWitnessLogged = false
    // Build 46: whether this video context is backed by the VideoToolbox
    // hwaccel, recorded from our own state (see shouldRebuild... below):
    // true when hardware decode was requested at init — the exact
    // condition under which createContext installs the get_format
    // callback — and latched on if a VideoToolbox-format frame is ever
    // produced. Build 45 instead read codecContext.hw_device_ctx back
    // from FFmpeg, which proved unreliable (see UPSTREAM.md).
    private var vtBackedVideoContext = false
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
        // Build 46: snapshot the hwaccel request exactly as createContext
        // evaluated it (it installs the get_format callback only for a
        // video context with hardware decode on). Snapshotting in init
        // keeps the flag consistent with the context actually opened,
        // even if the shared options object is mutated later.
        vtBackedVideoContext = assetTrack.mediaType == .video && (hardwareDecode ?? options.hardwareDecode)
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
            // Build 47: a native-codec rebuild armed after consecutive
            // frameless failures first drops extra whole GOPs (the
            // keyframes counted here), so the new context resumes past
            // the poisoned region instead of re-feeding its next GOP.
            // The starved path always arms with a skip of 0.
            if pendingRebuildSkipKeyFrames > 0 {
                pendingRebuildSkipKeyFrames -= 1
                return
            }
            rebuildCodecContext()
            awaitingRebuildKeyFrame = false
            nativeCodecPendingWitnessLogged = false
        }
        guard let codecContext else {
            completionHandler(.failure(NSError(description: "The media decoder could not be opened.")))
            return
        }
        guard prepareLivePacket(packet) else { return }
        let sendResult = avcodec_send_packet(codecContext, packet.corePacket)
        if sendResult < 0, sendResult != AVError.tryAgain.code {
            if shouldRebuildForNativeCodecError(mediaType: packet.assetTrack.mediaType, error: sendResult, site: "send-packet") { return }
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
                    // Build 46: a produced VideoToolbox-format frame is
                    // direct evidence this context decodes through the
                    // hwaccel; latch it for the absorption gate.
                    if inputFrame.pointee.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue { vtBackedVideoContext = true }
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
                    if shouldRebuildForNativeCodecError(mediaType: packet.assetTrack.mediaType, error: result, site: "receive-frame") { break }
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
            // Build 47: proof accounting for the native-codec budget.
            // A rebuilt context that sustains 30 frame-producing
            // packets has genuinely recovered, so the incident is
            // over: restore the rebuild budget and clear the
            // frameless streak. Fewer frames than that and a further
            // failure is the same incident continuing (build 46's
            // poisoned rebuilds produced at most a frame or two).
            nativeCodecFramesSinceRebuild += 1
            if nativeCodecFramesSinceRebuild >= 30,
               nativeCodecErrorRebuilds > 0 || nativeCodecFramelessStreak > 0
            {
                nativeCodecErrorRebuilds = 0
                nativeCodecFramelessStreak = 0
                options.onPlaybackDiagnostic?("dv nativecodec budget restored frames=30")
            }
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
        // Build 47: the new context starts unproven for the
        // native-codec incident accounting.
        nativeCodecFramesSinceRebuild = 0
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
    /// no-completion-handler precedent). Budget: 4 rebuilds per decoder
    /// instance; past that, return false and let the error surface.
    ///
    /// Build 46: build 45's gate also required
    /// `codecContext.hw_device_ctx != nil`, and on device that read
    /// nil in EVERY failing session — including sessions that had just
    /// produced AV_PIX_FMT_VIDEOTOOLBOX frames through the same
    /// decoder — so the absorption never fired once (build-45 export,
    /// 2026-11-27: 72+ occurrences of the error, zero rebuild lines).
    /// The field is written only inside the get_format callback
    /// (AVFFmpegExtension.swift) under frame threading and is read
    /// nowhere else in the codebase; it is not a reliable witness of
    /// VT activity. The gate now uses our own recorded state
    /// (`vtBackedVideoContext`: hwaccel requested at init, latched on
    /// by any produced VideoToolbox-format frame), and every
    /// AVERROR_UNKNOWN sighting at either call site emits a
    /// `dv nativecodec seen` witness line with the decision, so an
    /// export proves coverage either way. Software decode (no hwaccel
    /// requested, no VT frame) and audio still return false and keep
    /// the pre-build-45 behaviour exactly.
    ///
    /// Build 47: three refinements from Sam's build-46 export, where
    /// the absorption fired but could not cross a poisoned region.
    /// (1) Pending suppression: a sighting that arrives while a
    /// rebuild is already armed is absorbed without consuming budget
    /// or re-arming (`absorbed=pending`, witnessed once per pending
    /// window). The packet-drop guard at the top of decodeFrame
    /// already keeps send/receive unreachable while a rebuild is
    /// pending, so this is a belt-and-braces invariant — but it makes
    /// "budget is only spent at arming time" hold by construction,
    /// not by call-flow luck. (2) Escalation: if the context being
    /// replaced never proved itself (< 30 frame-producing packets
    /// since it was created), the failure continues the same
    /// incident, so the rebuild skips extra GOPs before resuming
    /// (0, 1, 2, 4 extra keyframes across consecutive frameless
    /// failures) — one GOP per rebuild could not cross the multi-GOP
    /// poisoned regions in the export, and each attempt burned
    /// budget. A context that had proved itself starts the ladder
    /// over. (3) The witness line gains `vtstatus=`: the real
    /// VideoToolbox OSStatus, which FFmpeg 8.1's videotoolbox
    /// hwaccel logs ("Failed to decode frame (bad data, -12909)" /
    /// "vt decoder cb: output image buffer is null: -12909, ...")
    /// immediately before collapsing it to AVERROR_UNKNOWN; the
    /// av_log callback in MEPlayerItem scrapes those two lines into
    /// VTDecodeFailureLog, and the value is consumed here so it is
    /// attached to exactly the sighting that produced it.
    private func shouldRebuildForNativeCodecError(mediaType: AVFoundation.AVMediaType, error: Int32, site: String) -> Bool {
        guard error == AVError.unknown.code else { return false }
        // Build 47 (1): a rebuild is already armed and packets are
        // being dropped until it lands; a further sighting in this
        // window is the same incident, not a new one. Absorb it
        // without spending budget, witnessed once per window.
        if awaitingRebuildKeyFrame {
            if !nativeCodecPendingWitnessLogged {
                nativeCodecPendingWitnessLogged = true
                options.onPlaybackDiagnostic?("dv nativecodec seen site=\(site) absorbed=pending reason=rebuild-pending code=\(error)\(vtStatusSuffix())")
            }
            return true
        }
        let absorbed: Bool
        let reason: String
        if mediaType != .video {
            absorbed = false
            reason = "not-video"
        } else if !vtBackedVideoContext {
            absorbed = false
            reason = "not-vt-backed"
        } else if nativeCodecErrorRebuilds >= 4 {
            absorbed = false
            reason = "budget-exhausted"
        } else {
            absorbed = true
            reason = "vt-session-failure"
        }
        // Witness first: the line is emitted on every sighting, before
        // the caller acts on the decision, absorbed or not.
        options.onPlaybackDiagnostic?("dv nativecodec seen site=\(site) absorbed=\(absorbed ? "yes" : "no") reason=\(reason) code=\(error)\(vtStatusSuffix())")
        guard absorbed else { return false }
        nativeCodecErrorRebuilds += 1
        // Build 47 (2): escalate the drop when the outgoing context
        // never proved itself; a proven context (≥ 30 frame-producing
        // packets) marks a new, isolated incident and restarts the
        // ladder. Skip ladder indexed by the frameless streak.
        let skipKeyFrames: Int
        if nativeCodecFramesSinceRebuild >= 30 {
            nativeCodecFramelessStreak = 0
            skipKeyFrames = 0
        } else {
            let ladder = [0, 1, 2, 4]
            skipKeyFrames = ladder[min(nativeCodecFramelessStreak, ladder.count - 1)]
            nativeCodecFramelessStreak += 1
        }
        pendingRebuildSkipKeyFrames = skipKeyFrames
        awaitingRebuildKeyFrame = true
        nativeCodecPendingWitnessLogged = false
        pendingRebuildReason = "native-codec-error"
        starvedVideoPackets = 0
        KSLog("FFmpegDecode: VT session failed (AVERROR_UNKNOWN) at \(site); rebuilding codec context at next keyframe (\(nativeCodecErrorRebuilds)/4), skipping \(skipKeyFrames) extra GOPs")
        options.onPlaybackDiagnostic?("decoder rebuild reason=native-codec-error count=\(nativeCodecErrorRebuilds) skipgops=\(skipKeyFrames)")
        return true
    }

    /// Build 47: ` vtstatus=<OSStatus>` when VTDecodeFailureLog holds
    /// a status scraped from FFmpeg's log within the last 5 seconds
    /// (consumed by the read), else an empty string.
    private func vtStatusSuffix() -> String {
        guard let status = VTDecodeFailureLog.shared.consumeRecentStatus() else { return "" }
        return " vtstatus=\(status)"
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
        // Build 47: a seek moves to a new position, so the pending
        // skip and the incident proof/streak restart with it. The
        // rebuild budget itself is only restored by the 30-frame
        // proof in noteDecodeProgress.
        pendingRebuildSkipKeyFrames = 0
        nativeCodecPendingWitnessLogged = false
        nativeCodecFramesSinceRebuild = 0
        nativeCodecFramelessStreak = 0
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
        // Build 47: same incident-state reset as doFlushCodec.
        pendingRebuildSkipKeyFrames = 0
        nativeCodecPendingWitnessLogged = false
        nativeCodecFramesSinceRebuild = 0
        nativeCodecFramelessStreak = 0
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
