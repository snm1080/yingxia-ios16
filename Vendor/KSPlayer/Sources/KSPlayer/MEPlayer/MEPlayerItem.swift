//
//  MEPlayerItem.swift
//  KSPlayer
//
//  Created by kintan on 2018/3/9.
//

import AVFoundation
import FFmpegKit
public final class MEPlayerItem: Sendable {
    private let url: URL
    private let options: KSOptions
    private let operationQueue = OperationQueue()
    private let condition = NSCondition()
    private var formatCtx: UnsafeMutablePointer<AVFormatContext>?
    private let cacheInputIO: PlaybackInputIO
    private var outputFormatCtx: UnsafeMutablePointer<AVFormatContext>?
    private var outputPacket: UnsafeMutablePointer<AVPacket>?
    private var streamMapping = [Int: Int]()
    private var openOperation: BlockOperation?
    private var readOperation: BlockOperation?
    private var closeOperation: BlockOperation?
    private var seekingCompletionHandler: ((Bool) -> Void)?
    // 没有音频数据可以渲染
    private var isAudioStalled = true
    private var audioClock = KSClock()
    private let audioClockLock = NSLock()
    private var audioClockGeneration: UInt64 = 0
    private var audioClockUpdatesEnabled = true
    /// Companion audio supplies a relative media clock; decoded video PTS stays
    /// in this input's original container epoch.
    var externalAudioClock: (() -> KSClock?)?
    var suppressEmbeddedAudio = false
    private var videoClock = KSClock()
    private var isFirst = true
    private var isSeek = false
    private var allPlayerItemTracks = [PlayerItemTrackProtocol]()
    private var maxFrameDuration = 10.0
    private var videoAudioTracks = [CapacityProtocol]()
    private var videoTrack: SyncPlayerItemTrack<VideoVTBFrame>?
    private var audioTrack: SyncPlayerItemTrack<AudioFrame>?
    private(set) var assetTracks = [FFmpegAssetTrack]()
    private var videoAdaptation: VideoAdaptationState?
    private var videoDisplayCount = UInt8(0)
    private var seekByBytes = false
    private var lastVideoDisplayTime = CACurrentMediaTime()
    public private(set) var chapters: [Chapter] = []
    public var currentPlaybackTime: TimeInterval {
        state == .seeking ? seekTime : (mainClock().time - startTime).seconds
    }

    /// 最近一帧绘制到 display layer 的 PTS——即画面上正在显示的那一帧。每次
    /// `setVideo(time:position:)` 渲染时更新；暂停 / stall 时无新帧绘制即冻结在最后一帧。
    /// 与 `currentPlaybackTime` 的差别：后者跟 audioClock，而 audioClock 在 prefill /
    /// cold-start / seek 后会瞬间被推到音频 buffer 头，跑在画面之前。
    public var displayedVideoTime: TimeInterval {
        state == .seeking ? seekTime : (videoClock.time - startTime).seconds
    }
    func relativeVideoTime(for timestamp: CMTime) -> TimeInterval { (timestamp - startTime).seconds }

    private var seekTime = TimeInterval(0)
    private var subtitlePrerollDeadline: CFTimeInterval?
    private var injectedSubtitlePackets: [Packet] = []
    private var colorProbeDeadline: TimeInterval?
    private var colorProbePackets: [DolbyVisionProbePacket] = []
    private var colorProbePacketIndex = 0
    private var dolbyPacketPairer: DolbyVisionPacketPairer?
    private var inlineDolbyConverters: [Int32: DolbyVisionInlineConverter] = [:]
    private var startTime = CMTime.zero
    public private(set) var duration: TimeInterval = 0
    public var hasReachedEndOfInput: Bool { state == .finished }
    #if DEBUG
    private var seekTracePacketsRemaining = 0
    private var seekTrace = ""
    public var renderDiagnostic: String {
        "reader=\(state) videoPackets=\(videoTrack?.packetCount ?? 0) videoFrames=\(videoTrack?.frameCount ?? 0) audioPackets=\(audioTrack?.packetCount ?? 0) audioFrames=\(audioTrack?.frameCount ?? 0) audioPTS=\(audioClockLock.withLock { audioClock.time.seconds }) videoPTS=\(videoClock.time.seconds) startPTS=\(startTime.seconds) videoFilter=\(videoTrack?.seekTime ?? -1) audioFilter=\(audioTrack?.seekTime ?? -1) seekTrace=\(seekTrace) decodeTrace=\(videoTrack?.decodeDiagnostic ?? "none")"
    }
    public var subtitleDiagnostic: String {
        assetTracks.filter { $0.mediaType == .subtitle }.prefix(4).map { track in
            let frames = track.subtitle?.outputRenderQueue.search(removing: { _ in false }, where: { _ in true }) ?? []
            return "id=\(track.trackID),enabled=\(track.isEnabled),codec=\(track.codecName),frames=\(frames.count),cues=" + frames.prefix(4).map {
                "\($0.part.start)-\($0.part.end):chars=\($0.part.text?.length ?? 0)"
            }.joined(separator: "/")
        }.joined(separator: ";")
    }
    #endif
    public private(set) var fileSize: Double = 0
    public private(set) var naturalSize = CGSize.zero
    private var error: NSError? {
        didSet {
            if error != nil {
                state = .failed
            }
        }
    }

    private var state = MESourceState.idle {
        didSet {
            switch state {
            case .opened:
                // Publish readiness after readThread can accept an immediate resume seek.
                break
            case .reading:
                timer.fireDate = Date.distantPast
            case .closed:
                timer.invalidate()
            case .failed:
                delegate?.sourceDidFailed(error: error)
                timer.fireDate = Date.distantFuture
            case .idle, .opening, .seeking, .paused, .finished:
                break
            }
        }
    }

    private lazy var timer: Timer = .scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
        self?.codecDidChangeCapacity()
    }

    lazy var dynamicInfo = DynamicInfo { [weak self] in
        // metadata可能会实时变化。所以把它放在DynamicInfo里面
        toDictionary(self?.formatCtx?.pointee.metadata)
    } bytesRead: { [weak self] in
        self?.cacheInputIO.bytesRead ?? 0
    } audioBitrate: { [weak self] in
        Int(8 * (self?.audioTrack?.bitrate ?? 0))
    } videoBitrate: { [weak self] in
        Int(8 * (self?.videoTrack?.bitrate ?? 0))
    }

    private static var onceInitial: Void = {
        var result = avformat_network_init()
        av_log_set_callback { ptr, level, format, args in
            guard let format else {
                return
            }
            var filterOptions: KSOptions?
            if let ptr {
                let avclass = ptr.assumingMemoryBound(to: UnsafePointer<AVClass>.self).pointee
                if avclass == avfilter_get_class() {
                    let context = ptr.assumingMemoryBound(to: AVFilterContext.self).pointee
                    if let opaque = context.graph?.pointee.opaque {
                        filterOptions = Unmanaged<KSOptions>.fromOpaque(opaque).takeUnretainedValue()
                    }
                }
            }
            // FFmpeg calls custom callbacks before applying its log threshold.
            // Demux/decoder TRACE lines are emitted for every packet/NAL: skip
            // their String/varargs formatting when nobody consumes the message.
            // idet's DEBUG output still drives automatic interlace detection.
            let parserMissing = strncmp(format, "parser not found for codec", 26) == 0
            guard level <= KSOptions.logLevel.rawValue || filterOptions?.autoDeInterlace == true || parserMissing else { return }
            var log = String(cString: format)
            let arguments: CVaListPointer? = args
            if let arguments {
                log = NSString(format: log, arguments: arguments) as String
            }
            filterOptions?.filter(log: log)
            // 找不到解码器
            if parserMissing {
                KSLog(level: .error, log)
            }
            KSLog(level: LogLevel(rawValue: level) ?? .warning, log)
        }
    }()

    weak var delegate: MEPlayerDelegate?
    public init(url: URL, options: KSOptions) {
        self.url = url
        self.options = options
        cacheInputIO = PlaybackInputIO(originalURL: url, transportURL: options.cacheIOURL ?? url)
        timer.fireDate = Date.distantFuture
        operationQueue.name = "KSPlayer_" + String(describing: self).components(separatedBy: ".").last!
        operationQueue.maxConcurrentOperationCount = 1
        operationQueue.qualityOfService = .userInteractive
        _ = MEPlayerItem.onceInitial
    }

    func select(track: some MediaPlayerTrack, performSeek: Bool = true) -> Bool {
        if (track as? FFmpegAssetTrack)?.isDolbyVisionEnhancementLayer == true { return false }
        if track.isEnabled {
            return false
        }
        assetTracks.filter { $0.mediaType == track.mediaType }.forEach {
            $0.isEnabled = track === $0
        }
        guard let assetTrack = track as? FFmpegAssetTrack else {
            return false
        }
        if assetTrack.mediaType == .video {
            findBestAudio(videoTrack: assetTrack)
        } else if assetTrack.mediaType == .subtitle {
            if assetTrack.isImageSubtitle {
                if !options.isSeekImageSubtitle {
                    return false
                }
            } else {
                return false
            }
        }
        if performSeek {
            seek(time: currentPlaybackTime) { _ in }
        }
        return true
    }
}

// MARK: private functions

extension MEPlayerItem {
    private func openThread() {
        avformat_close_input(&self.formatCtx)
        formatCtx = avformat_alloc_context()
        guard let formatCtx else {
            error = NSError(errorCode: .formatCreate)
            return
        }
        var interruptCB = AVIOInterruptCB()
        interruptCB.opaque = Unmanaged.passUnretained(self).toOpaque()
        interruptCB.callback = { ctx -> Int32 in
            guard let ctx else {
                return 0
            }
            let formatContext = Unmanaged<MEPlayerItem>.fromOpaque(ctx).takeUnretainedValue()
            if let deadline = formatContext.subtitlePrerollDeadline, CACurrentMediaTime() >= deadline { return 1 }
            if let deadline = formatContext.colorProbeDeadline, ProcessInfo.processInfo.systemUptime >= deadline { return 1 }
            switch formatContext.state {
            case .finished, .closed, .failed:
                return 1
            default:
                return 0
            }
        }
        formatCtx.pointee.interrupt_callback = interruptCB
        cacheInputIO.install(on: formatCtx)
        // avformat_close_input这个函数会调用io_close2。但是自定义协议是不会调用io_close2这个函数
//        formatCtx.pointee.io_close2 = { _, _ -> Int32 in
//            0
//        }
        setHttpProxy()
        var avOptions = options.formatContextOptions.avOptions
        if let pb = options.process(url: url) {
            // 如果要自定义协议的话，那就用avio_alloc_context，对formatCtx.pointee.pb赋值
            formatCtx.pointee.pb = pb.getContext()
        }
        let urlString: String
        if url.isFileURL {
            urlString = url.path
        } else {
            urlString = url.absoluteString
        }
        var result = avformat_open_input(&self.formatCtx, urlString, nil, &avOptions)
        av_dict_free(&avOptions)
        if result == AVError.eof.code {
            state = .finished
            delegate?.sourceDidFinished()
            return
        }
        guard result == 0 else {
            error = .init(errorCode: .formatOpenInput, avErrorCode: result)
            avformat_close_input(&self.formatCtx)
            return
        }
        options.openTime = CACurrentMediaTime()
        formatCtx.pointee.flags |= AVFMT_FLAG_GENPTS
        if options.nobuffer {
            formatCtx.pointee.flags |= AVFMT_FLAG_NOBUFFER
        }
        if let probesize = options.probesize {
            formatCtx.pointee.probesize = probesize
        }
        if let maxAnalyzeDuration = options.maxAnalyzeDuration {
            formatCtx.pointee.max_analyze_duration = maxAnalyzeDuration
        }
        result = avformat_find_stream_info(formatCtx, nil)
        cacheInputIO.publishBytes()
        guard result == 0 else {
            error = .init(errorCode: .formatFindStreamInfo, avErrorCode: result)
            avformat_close_input(&self.formatCtx)
            return
        }
        // FIXME: hack, ffplay maybe should not use avio_feof() to test for the end
        formatCtx.pointee.pb?.pointee.eof_reached = 0
        let flags = formatCtx.pointee.iformat.pointee.flags
        maxFrameDuration = flags & AVFMT_TS_DISCONT == AVFMT_TS_DISCONT ? 10.0 : 3600.0
        options.findTime = CACurrentMediaTime()
        options.formatName = String(cString: formatCtx.pointee.iformat.pointee.name)
        // Average-bitrate byte estimates can miss VBR transport-stream targets
        // by minutes. Accurate mode must let the demuxer locate timestamp/keyframes.
        seekByBytes = !options.isAccurateSeek && (flags & AVFMT_NO_BYTE_SEEK == 0) && (flags & AVFMT_TS_DISCONT != 0) && options.formatName != "ogg"
        if formatCtx.pointee.start_time != Int64.min {
            startTime = CMTime(value: formatCtx.pointee.start_time, timescale: AV_TIME_BASE)
            videoClock.time = startTime
            audioClockLock.withLock { audioClock.time = startTime }
        }
        duration = TimeInterval(max(formatCtx.pointee.duration, 0)) / TimeInterval(AV_TIME_BASE)
        fileSize = Double(formatCtx.pointee.bit_rate) * duration / 8
        createCodec(formatCtx: formatCtx)
        if state == .failed || state == .closed { return }
        if formatCtx.pointee.nb_chapters > 0 {
            chapters.removeAll()
            for i in 0 ..< formatCtx.pointee.nb_chapters {
                if let chapter = formatCtx.pointee.chapters[Int(i)]?.pointee {
                    let timeBase = Timebase(chapter.time_base)
                    let start = timeBase.cmtime(for: chapter.start).seconds
                    let end = timeBase.cmtime(for: chapter.end).seconds
                    let metadata = toDictionary(chapter.metadata)
                    let title = metadata["title"] ?? ""
                    chapters.append(Chapter(start: start, end: end, title: title))
                }
            }
        }

        if let outputURL = options.outputURL {
            startRecord(url: outputURL)
        }
        if videoTrack == nil, audioTrack == nil {
            error = NSError(description: "FFmpeg found no playable audio or video tracks.")
        } else {
            state = .opened
            read()
        }
    }

    func startRecord(url: URL) {
        stopRecord()
        let filename = url.isFileURL ? url.path : url.absoluteString
        var ret = avformat_alloc_output_context2(&outputFormatCtx, nil, nil, filename)
        guard let outputFormatCtx, let formatCtx else {
            KSLog(NSError(errorCode: .formatOutputCreate, avErrorCode: ret))
            return
        }
        var index = 0
        var audioIndex: Int?
        var videoIndex: Int?
        let formatName = outputFormatCtx.pointee.oformat.pointee.name.flatMap { String(cString: $0) }
        for i in 0 ..< Int(formatCtx.pointee.nb_streams) {
            if let inputStream = formatCtx.pointee.streams[i] {
                // Same NULL-codecpar hazard as FFmpegAssetTrack.init(stream:);
                // this loop also visits every stream in the container.
                guard let inputCodecpar = inputStream.pointee.codecpar else { continue }
                let codecType = inputCodecpar.pointee.codec_type
                if [AVMEDIA_TYPE_AUDIO, AVMEDIA_TYPE_VIDEO, AVMEDIA_TYPE_SUBTITLE].contains(codecType) {
                    if codecType == AVMEDIA_TYPE_AUDIO {
                        if let audioIndex {
                            streamMapping[i] = audioIndex
                            continue
                        } else {
                            audioIndex = index
                        }
                    } else if codecType == AVMEDIA_TYPE_VIDEO {
                        if let videoIndex {
                            streamMapping[i] = videoIndex
                            continue
                        } else {
                            videoIndex = index
                        }
                    }
                    if let outStream = avformat_new_stream(outputFormatCtx, nil) {
                        streamMapping[i] = index
                        index += 1
                        avcodec_parameters_copy(outStream.pointee.codecpar, inputStream.pointee.codecpar)
                        if codecType == AVMEDIA_TYPE_SUBTITLE, formatName == "mp4" || formatName == "mov" {
                            outStream.pointee.codecpar.pointee.codec_id = AV_CODEC_ID_MOV_TEXT
                        }
                        if inputStream.pointee.codecpar.pointee.codec_id == AV_CODEC_ID_HEVC {
                            outStream.pointee.codecpar.pointee.codec_tag = CMFormatDescription.MediaSubType.hevc.rawValue.bigEndian
                        } else {
                            outStream.pointee.codecpar.pointee.codec_tag = 0
                        }
                    }
                }
            }
        }
        avio_open(&(outputFormatCtx.pointee.pb), filename, AVIO_FLAG_WRITE)
        ret = avformat_write_header(outputFormatCtx, nil)
        guard ret >= 0 else {
            KSLog(NSError(errorCode: .formatWriteHeader, avErrorCode: ret))
            avformat_close_input(&self.outputFormatCtx)
            return
        }
        outputPacket = av_packet_alloc()
    }

    private func createCodec(formatCtx: UnsafeMutablePointer<AVFormatContext>) {
        allPlayerItemTracks.removeAll()
        assetTracks.removeAll()
        videoAdaptation = nil
        videoTrack = nil
        audioTrack = nil
        videoAudioTracks.removeAll()
        colorProbePackets.removeAll()
        colorProbePacketIndex = 0
        dolbyPacketPairer = nil
        inlineDolbyConverters.removeAll()
        var colorLayerPair: DolbyVisionLayerProbe.Pair?
        // Generic/live inputs never enter this probe. Only an authored HDMV
        // program with both UHD PIDs permits a bounded RPU inspection.
        if duration > 0, options.formatName == "mpegts", DolbyVisionLayerProbe.candidate(in: formatCtx) != nil {
            colorProbeDeadline = ProcessInfo.processInfo.systemUptime + 1.0
            let probe = DolbyVisionLayerProbe.inspect(format: formatCtx, deadline: colorProbeDeadline!)
            colorProbeDeadline = nil
            colorLayerPair = probe.pair
            colorProbePackets = probe.packets
        }
        if let pair = colorLayerPair, let base = formatCtx.pointee.streams[Int(pair.baseTrackID)],
           let enhancement = formatCtx.pointee.streams[Int(pair.enhancementTrackID)],
           let parameters = base.pointee.codecpar {
            do {
                let converter = try DolbyVisionRPUConverter()
                dolbyPacketPairer = DolbyVisionPacketPairer(baseTrackID: pair.baseTrackID,
                    enhancementTrackID: pair.enhancementTrackID, baseTimebase: base.pointee.time_base,
                    enhancementTimebase: enhancement.pointee.time_base,
                    convert: { try converter.convert($0) }, flush: { converter.flush() })
                try DolbyVisionConfiguration.configureP81(parameters, frameRate: base.pointee.avg_frame_rate)
            } catch {
                self.error = NSError(description: "杜比视界 P7 转 P8.1 初始化失败，请切换线路。")
                return
            }
        }
        assetTracks = (0 ..< Int(formatCtx.pointee.nb_streams)).compactMap { i in
            if let coreStream = formatCtx.pointee.streams[i] {
                coreStream.pointee.discard = AVDISCARD_ALL
                var inlineP7 = false
                if let parameters = coreStream.pointee.codecpar, DolbyVisionConfiguration.isProfile7(parameters.pointee) {
                    let original = parameters.pointee
                    do {
                        let converter = try DolbyVisionRPUConverter()
                        let extra = original.extradata.map { Data(bytes: $0, count: max(0, Int(original.extradata_size))) } ?? Data()
                        let annexB = VideoNALFormat.isAnnexB(extra)
                        let length = !annexB && extra.count > 21 ? Int(extra[21] & 3) + 1 : 4
                        inlineDolbyConverters[coreStream.pointee.index] = DolbyVisionInlineConverter(annexB: annexB,
                            lengthFieldBytes: length, convert: { try converter.convert($0) }, flush: { converter.flush() })
                        try DolbyVisionConfiguration.configureP81(parameters, frameRate: coreStream.pointee.avg_frame_rate)
                        inlineP7 = true
                    } catch {
                        self.error = NSError(description: "杜比视界 P7 单层转换初始化失败，请切换线路。")
                        return nil
                    }
                }
                if let assetTrack = FFmpegAssetTrack(stream: coreStream) {
                    assetTrack.isDolbyVisionEnhancementLayer = coreStream.pointee.index == colorLayerPair?.enhancementTrackID
                    assetTrack.hasDolbyVisionEnhancementLayer = coreStream.pointee.index == colorLayerPair?.baseTrackID
                    assetTrack.convertsDolbyVisionP7ToP81 = inlineP7 || (assetTrack.hasDolbyVisionEnhancementLayer && dolbyPacketPairer != nil)
                    if assetTrack.isDolbyVisionEnhancementLayer {
                        // The reader needs its RPU packets, never its residual
                        // pixels. Keep the demux stream while excluding UI/decode.
                        coreStream.pointee.discard = AVDISCARD_DEFAULT
                    }
                    if assetTrack.mediaType == .subtitle {
                        let subtitle = SyncPlayerItemTrack<SubtitleFrame>(mediaType: .subtitle, frameCapacity: 255, options: options)
                        assetTrack.subtitle = subtitle
                        allPlayerItemTracks.append(subtitle)
                    }
                    assetTrack.seekByBytes = seekByBytes
                    return assetTrack
                }
            }
            return nil
        }
        var videoIndex: Int32 = -1
        if !options.videoDisable {
            let videos = assetTracks.filter { $0.mediaType == .video && !$0.isDolbyVisionEnhancementLayer }
            let wantedStreamNb: Int32
            if !videos.isEmpty, let index = options.wantedVideo(tracks: videos), videos.indices.contains(index) {
                wantedStreamNb = videos[index].trackID
            } else if let colorLayerPair {
                // av_find_best_stream ranks packet counts, not base/enhancement
                // semantics. The exact UHD title otherwise chooses its residual.
                wantedStreamNb = colorLayerPair.baseTrackID
            } else {
                wantedStreamNb = -1
            }
            videoIndex = av_find_best_stream(formatCtx, AVMEDIA_TYPE_VIDEO, wantedStreamNb, -1, nil, 0)
            if let first = videos.first(where: { $0.trackID == videoIndex }) {
                first.isEnabled = true
                let rotation = first.rotation
                if rotation > 0, options.autoRotate {
                    options.hardwareDecode = false
                    if abs(rotation - 90) <= 1 {
                        options.videoFilters.append("transpose=clock")
                    } else if abs(rotation - 180) <= 1 {
                        options.videoFilters.append("hflip")
                        options.videoFilters.append("vflip")
                    } else if abs(rotation - 270) <= 1 {
                        options.videoFilters.append("transpose=cclock")
                    } else if abs(rotation) > 1 {
                        options.videoFilters.append("rotate=\(rotation)*PI/180")
                    }
                }
                naturalSize = abs(rotation - 90) <= 1 || abs(rotation - 270) <= 1 ? first.naturalSize.reverse : first.naturalSize
                options.process(assetTrack: first)
                let frameCapacity = options.videoFrameMaxCount(fps: first.nominalFrameRate, naturalSize: naturalSize, isLive: duration == 0)
                let track = options.syncDecodeVideo ? SyncPlayerItemTrack<VideoVTBFrame>(mediaType: .video, frameCapacity: frameCapacity, options: options) : AsyncPlayerItemTrack<VideoVTBFrame>(mediaType: .video, frameCapacity: frameCapacity, options: options)
                track.delegate = self
                allPlayerItemTracks.append(track)
                videoTrack = track
                if first.codecpar.codec_id != AV_CODEC_ID_MJPEG {
                    videoAudioTracks.append(track)
                }
                let bitRates = videos.map(\.bitRate).filter {
                    $0 > 0
                }
                if bitRates.count > 1, options.videoAdaptable, !first.hasDolbyVisionEnhancementLayer {
                    let bitRateState = VideoAdaptationState.BitRateState(bitRate: first.bitRate, time: CACurrentMediaTime())
                    videoAdaptation = VideoAdaptationState(bitRates: bitRates.sorted(by: <), duration: duration, fps: first.nominalFrameRate, bitRateStates: [bitRateState])
                }
            }
        }

        let audios = assetTracks.filter { $0.mediaType == .audio }
        let wantedStreamNb: Int32
        if !audios.isEmpty, let index = options.wantedAudio(tracks: audios) {
            wantedStreamNb = audios[index].trackID
        } else {
            wantedStreamNb = -1
        }
        let index = av_find_best_stream(formatCtx, AVMEDIA_TYPE_AUDIO, wantedStreamNb, videoIndex, nil, 0)
        if !options.audioDisable, !suppressEmbeddedAudio, let first = audios.first(where: {
            index > 0 ? $0.trackID == index : true
        }), first.codecpar.codec_id != AV_CODEC_ID_NONE {
            first.isEnabled = true
            options.process(assetTrack: first)
            // 音频要比较所有的音轨，因为truehd的fps是1200，跟其他的音轨差距太大了
            let fps = audios.map(\.nominalFrameRate).max() ?? 44
            let frameCapacity = options.audioFrameMaxCount(fps: fps, channelCount: Int(first.audioDescriptor?.audioFormat.channelCount ?? 2))
            let track = options.syncDecodeAudio ? SyncPlayerItemTrack<AudioFrame>(mediaType: .audio, frameCapacity: frameCapacity, options: options) : AsyncPlayerItemTrack<AudioFrame>(mediaType: .audio, frameCapacity: frameCapacity, options: options)
            track.delegate = self
            allPlayerItemTracks.append(track)
            audioTrack = track
            videoAudioTracks.append(track)
            isAudioStalled = false
        }
    }

    private func read() {
        readOperation = BlockOperation { [weak self] in
            guard let self else { return }
            Thread.current.name = (self.operationQueue.name ?? "") + "_read"
            Thread.current.stackSize = KSOptions.stackSize
            self.readThread()
        }
        readOperation?.queuePriority = .veryHigh
        readOperation?.qualityOfService = .userInteractive
        if let readOperation {
            operationQueue.addOperation(readOperation)
        }
    }

    private func readThread() {
        let notifyReady = state == .opened
        if state == .opened {
            if options.startPlayTime > 0 {
                colorProbePackets.removeAll(); colorProbePacketIndex = 0
                dolbyPacketPairer?.reset()
                inlineDolbyConverters.values.forEach { $0.reset() }
                let timestamp = startTime + CMTime(seconds: options.startPlayTime)
                let flags = seekByBytes ? AVSEEK_FLAG_BYTE : 0
                let seekStartTime = CACurrentMediaTime()
                let result = avformat_seek_file(formatCtx, -1, Int64.min, timestamp.value, Int64.max, flags)
                if result >= 0, dolbyPacketPairer != nil || !inlineDolbyConverters.isEmpty {
                    do { try warmDolbyMetadata(at: options.startPlayTime) }
                    catch {
                        if state == .closed { return }
                        self.error = NSError(description: "杜比视界 P8.1 续播元数据恢复失败，请从头播放或切换线路。")
                        return
                    }
                    guard avformat_seek_file(formatCtx, -1, Int64.min, timestamp.value, Int64.max, flags) >= 0 else {
                        if state == .closed { return }
                        self.error = NSError(description: "杜比视界续播输入位置恢复失败，请重新播放。")
                        return
                    }
                }
                audioClockLock.withLock { audioClock.time = timestamp }
                videoClock.time = timestamp
                KSLog("start PlayTime: \(timestamp.seconds) spend Time: \(CACurrentMediaTime() - seekStartTime)")
            }
            state = .reading
        }
        allPlayerItemTracks.forEach { $0.decode() }
        if notifyReady, state == .reading { delegate?.sourceDidOpened() }
        while [MESourceState.paused, .seeking, .reading].contains(state) {
            if state == .paused {
                condition.wait()
            }
            if state == .seeking {
                colorProbePackets.removeAll(); colorProbePacketIndex = 0
                dolbyPacketPairer?.reset()
                inlineDolbyConverters.values.forEach { $0.reset() }
                let seekToTime = seekTime
                let clockGeneration = audioClockLock.withLock { audioClockGeneration }
                injectedSubtitlePackets = []
                let subtitlePreroll = readSubtitlePreroll(at: seekToTime)
                let time = mainClock().time
                var increase = Int64(seekTime + startTime.seconds - time.seconds)
                var seekFlags = options.seekFlags
                let timeStamp: Int64
                if seekByBytes {
                    seekFlags |= AVSEEK_FLAG_BYTE
                    if let bitRate = formatCtx?.pointee.bit_rate {
                        increase = increase * bitRate / 8
                    } else {
                        increase *= 180_000
                    }
                    var position = Int64(-1)
                    if position < 0 {
                        position = videoClock.position
                    }
                    if position < 0 {
                        position = audioClockLock.withLock { audioClock.position }
                    }
                    if position < 0 {
                        position = avio_tell(formatCtx?.pointee.pb)
                    }
                    timeStamp = position + increase
                } else {
                    // Convert the complete absolute target once. Separately
                    // truncating current and delta seconds lost up to two seconds.
                    timeStamp = Int64(((seekToTime + startTime.seconds) * Double(AV_TIME_BASE)).rounded())
                    increase = timeStamp - Int64((time.seconds * Double(AV_TIME_BASE)).rounded())
                }
                // seek_file clears BACKWARD and derives direction from bounds.
                // Accurate seeking must decode forward from a preceding keyframe,
                // never jump to the next HLS segment/keyframe after the target.
                let seekMin = options.isAccurateSeek ? Int64.min : (increase > 0 ? timeStamp - increase + 2 : Int64.min)
                let seekMax = options.isAccurateSeek ? timeStamp : (increase < 0 ? timeStamp - increase - 2 : Int64.max)
                #if DEBUG
                seekTrace = "target=\(seekToTime),min=\(seekMin),ts=\(timeStamp),max=\(seekMax),flags=\(seekFlags),default=\(av_find_default_stream_index(formatCtx)),format=\(options.formatName)"
                seekTracePacketsRemaining = 20
                #endif
                // can not seek to key frame
                let seekStartTime = CACurrentMediaTime()
                var result = avformat_seek_file(formatCtx, -1, seekMin, timeStamp, seekMax, seekFlags)
//                var result = av_seek_frame(formatCtx, -1, timeStamp, seekFlags)
                // When seeking before the beginning of the file, and seeking fails,
                // try again without the backwards flag to make it seek to the
                // beginning.
                if result < 0, seekFlags & AVSEEK_FLAG_BACKWARD == AVSEEK_FLAG_BACKWARD {
                    KSLog("seek to \(seekToTime) failed. seekFlags remove BACKWARD")
                    options.seekFlags &= ~AVSEEK_FLAG_BACKWARD
                    seekFlags &= ~AVSEEK_FLAG_BACKWARD
                    result = avformat_seek_file(formatCtx, -1, seekMin, timeStamp, seekMax, seekFlags)
                }
                if result >= 0, dolbyPacketPairer != nil || !inlineDolbyConverters.isEmpty {
                    do { try warmDolbyMetadata(at: seekToTime) }
                    catch {
                        if state == .closed { return }
                        if seekToTime != seekTime || audioClockLock.withLock({ audioClockGeneration != clockGeneration }) {
                            continue
                        }
                        self.error = NSError(description: "杜比视界 P8.1 跳转元数据恢复失败，请从头播放或切换线路。")
                        return
                    }
                    if seekToTime != seekTime || audioClockLock.withLock({ audioClockGeneration != clockGeneration }) {
                        continue
                    }
                    result = avformat_seek_file(formatCtx, -1, seekMin, timeStamp, seekMax, seekFlags)
                    if result < 0 {
                        if state == .closed { return }
                        if seekToTime != seekTime || audioClockLock.withLock({ audioClockGeneration != clockGeneration }) {
                            continue
                        }
                        self.error = NSError(description: "杜比视界跳转输入位置恢复失败，请重新播放。")
                        return
                    }
                }
                KSLog("seek to \(seekToTime) spend Time: \(CACurrentMediaTime() - seekStartTime)")
                if state == .closed {
                    break
                }
                if seekToTime != seekTime || audioClockLock.withLock({ audioClockGeneration != clockGeneration }) {
                    continue
                }
                #if DEBUG
                seekTrace += ",result=\(result)"
                #endif
                isSeek = true
                allPlayerItemTracks.forEach { $0.seek(time: seekToTime + startTime.seconds) }
                if result >= 0 {
                    injectedSubtitlePackets = subtitlePreroll
                    for packet in subtitlePreroll { packet.assetTrack.subtitle?.putPacket(packet: packet) }
                }
                // Detach the completed request before invoking the application. Its callback
                // can immediately enqueue the next seek and must keep its own completion.
                let completion = seekingCompletionHandler
                seekingCompletionHandler = nil
                let seekClockTime = CMTime(seconds: seekToTime, preferredTimescale: time.timescale) + startTime
                audioClockLock.withLock { audioClock.time = seekClockTime }
                videoClock.time = CMTime(seconds: seekToTime, preferredTimescale: time.timescale) + startTime
                state = .reading
                let succeeded = result >= 0
                DispatchQueue.main.async {
                    // KSMEPlayer flushes the old audio output during completion.
                    // Keep audio callbacks disabled until that flush has happened,
                    // and only the current seek generation may re-enable them.
                    completion?(succeeded)
                    self.finishAudioClockSeek(time: seekClockTime, generation: clockGeneration)
                }
            } else if state == .reading {
                autoreleasepool {
                    _ = reading()
                }
            }
        }
    }

    /// Start the source RPU parser from a preceding keyframe before restoring
    /// the requested demux position. Output RPUs are full/uncompressed, so the
    /// native decoder never receives a reference to the previous seek epoch.
    private func warmDolbyMetadata(at target: TimeInterval) throws {
        if dolbyPacketPairer == nil {
            try warmInlineDolbyMetadata(at: target)
            return
        }
        guard let pairer = dolbyPacketPairer, target > 0, let formatCtx,
              let enhancement = formatCtx.pointee.streams[Int(pairer.enhancementTrackID)],
              let base = formatCtx.pointee.streams[Int(pairer.baseTrackID)] else { return }
        let timebase = enhancement.pointee.time_base
        guard timebase.num > 0, timebase.den > 0 else { throw DolbyVisionPacketPairer.Failure.invalidTimestamp }
        colorProbeDeadline = ProcessInfo.processInfo.systemUptime + 2
        var seeded = false
        defer {
            colorProbeDeadline = nil
            if !seeded { pairer.discardQueuedPackets() }
        }
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        guard let packet else { throw DolbyVisionPacketPairer.Failure.allocation }
        var count = 0, bytes = 0
        var firstPTS = Int64.min, firstDTS = Int64.min
        // Observe the actual keyframe reached by the final demux seek.
        while count < 512, bytes < 4 * 1024 * 1024, ProcessInfo.processInfo.systemUptime < (colorProbeDeadline ?? 0) {
            guard av_read_frame(formatCtx, packet) >= 0 else { break }
            count += 1; bytes += max(0, Int(packet.pointee.size))
            if packet.pointee.stream_index == pairer.baseTrackID {
                firstPTS = packet.pointee.pts; firstDTS = packet.pointee.dts
                av_packet_unref(packet)
                // A seek can cut after this AU's physical EL packet. Without
                // any timestamp, a later EL cannot prove the first AU's RPU.
                guard firstPTS != .min || firstDTS != .min else {
                    throw DolbyVisionPacketPairer.Failure.invalidTimestamp
                }
                break
            }
            av_packet_unref(packet)
        }
        let timestamp = firstDTS != .min ? firstDTS : firstPTS
        guard timestamp != .min else { throw DolbyVisionPacketPairer.Failure.invalidTimestamp }
        let firstSeconds = Double(timestamp) * Double(base.pointee.time_base.num) / Double(base.pointee.time_base.den)
        let probeTime = Int64(max(startTime.seconds, firstSeconds - 5) * Double(timebase.den) / Double(timebase.num))
        guard avformat_seek_file(formatCtx, pairer.enhancementTrackID, Int64.min, probeTime, probeTime, AVSEEK_FLAG_BACKWARD) >= 0
        else { throw DolbyVisionPacketPairer.Failure.invalidTimestamp }
        var reachedFirst = false
        while count < 4096, bytes < 32 * 1024 * 1024, ProcessInfo.processInfo.systemUptime < (colorProbeDeadline ?? 0) {
            guard av_read_frame(formatCtx, packet) >= 0 else { break }
            count += 1; bytes += max(0, Int(packet.pointee.size))
            if packet.pointee.stream_index == pairer.enhancementTrackID {
                let matchesPTS = firstPTS != .min && packet.pointee.pts != .min
                    && av_compare_ts(firstPTS, base.pointee.time_base, packet.pointee.pts, timebase) == 0
                let matchesDTS = (firstPTS == .min || packet.pointee.pts == .min)
                    && firstDTS != .min && packet.pointee.dts != .min
                    && av_compare_ts(firstDTS, base.pointee.time_base, packet.pointee.dts, timebase) == 0
                if matchesPTS || matchesDTS {
                    // A generic TS seek can begin at the base after its EL
                    // was physically passed. Retain this exact converted RPU
                    // to pair after restore, and skip one identical reread.
                    try pairer.seedFirstMetadata(packet: packet)
                    seeded = true
                    reachedFirst = true
                    av_packet_unref(packet)
                    break
                }
                // An arbitrary prior keyframe can begin with an unresolved
                // previous reference; a later full source RPU restores it.
                do { _ = try pairer.warmMetadata(packet: packet) }
                catch { }
            }
            av_packet_unref(packet)
        }
        guard reachedFirst else { throw DolbyVisionPacketPairer.Failure.missingRPU }
    }

    /// Inline P7 can reference an earlier RPU even on a video keyframe.
    /// Rebuild source references in decode order, retain the exact first
    /// converted AU, then let the caller restore its original demux seek.
    private func warmInlineDolbyMetadata(at target: TimeInterval) throws {
        guard target > 0, let formatCtx,
              let track = assetTracks.first(where: { $0.mediaType == .video && $0.isEnabled }),
              let converter = inlineDolbyConverters[track.trackID],
              let stream = formatCtx.pointee.streams[Int(track.trackID)] else { return }
        let timebase = stream.pointee.time_base
        guard timebase.num > 0, timebase.den > 0 else { throw DolbyVisionPacketPairer.Failure.invalidTimestamp }
        colorProbeDeadline = ProcessInfo.processInfo.systemUptime + 2
        defer { colorProbeDeadline = nil }
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        guard let packet else { throw DolbyVisionPacketPairer.Failure.allocation }
        var firstPTS = Int64.min, firstDTS = Int64.min, firstPos = Int64(-1)
        var firstData = Data(), count = 0, bytes = 0
        while count < 512, bytes < 4 * 1024 * 1024, ProcessInfo.processInfo.systemUptime < (colorProbeDeadline ?? 0) {
            guard av_read_frame(formatCtx, packet) >= 0 else { break }
            count += 1; bytes += max(0, Int(packet.pointee.size))
            if packet.pointee.stream_index == track.trackID, packet.pointee.size > 0, let source = packet.pointee.data {
                firstPTS = packet.pointee.pts; firstDTS = packet.pointee.dts; firstPos = packet.pointee.pos
                firstData = Data(bytes: source, count: Int(packet.pointee.size))
                av_packet_unref(packet)
                break
            }
            av_packet_unref(packet)
        }
        let time = firstDTS != .min ? firstDTS : firstPTS
        guard time != .min else { throw DolbyVisionPacketPairer.Failure.invalidTimestamp }
        let seconds = Double(time) * Double(timebase.num) / Double(timebase.den)
        let before = Int64(max(startTime.seconds, seconds - 5) * Double(timebase.den) / Double(timebase.num))
        guard avformat_seek_file(formatCtx, track.trackID, Int64.min, before, before, AVSEEK_FLAG_BACKWARD) >= 0 else {
            throw DolbyVisionPacketPairer.Failure.invalidTimestamp
        }
        while count < 4096, bytes < 32 * 1024 * 1024, ProcessInfo.processInfo.systemUptime < (colorProbeDeadline ?? 0) {
            guard av_read_frame(formatCtx, packet) >= 0 else { break }
            count += 1; bytes += max(0, Int(packet.pointee.size))
            if packet.pointee.stream_index == track.trackID, packet.pointee.size > 0, let source = packet.pointee.data {
                let ptsMatch = firstPTS != .min && packet.pointee.pts == firstPTS
                let dtsMatch = (firstPTS == .min || packet.pointee.pts == .min) && packet.pointee.dts == firstDTS
                let positionMatch = firstPos < 0 || packet.pointee.pos < 0 || packet.pointee.pos == firstPos
                if (ptsMatch || dtsMatch), positionMatch,
                   Data(bytes: source, count: Int(packet.pointee.size)) == firstData {
                    try converter.seedFirst(packet: packet)
                    av_packet_unref(packet)
                    return
                }
                // An unresolved reference at the arbitrary prior keyframe can
                // recover at the next source full RPU. Never output probe AUs.
                do { try converter.warm(packet: packet) } catch { }
            }
            av_packet_unref(packet)
        }
        throw DolbyVisionPacketPairer.Failure.missingRPU
    }

    /// Matroska's video-index seek skips long subtitle cues beginning in an
    /// earlier cluster. Fetch only the selected cue through its subtitle index,
    /// then let the ordinary video seek restore the demuxer. No A/V pre-roll is
    /// decoded or queued here, and all reads share the existing authenticated IO.
    private func readSubtitlePreroll(at target: TimeInterval) -> [Packet] {
        let requestedTrackIDs = options.subtitlePrerollTrackIDs
        guard options.isAccurateSeek, options.formatName.contains("matroska"),
              !requestedTrackIDs.isEmpty, let formatCtx else { return [] }
        let selected = assetTracks.filter {
            $0.mediaType == .subtitle && !$0.isImageSubtitle && requestedTrackIDs.contains($0.trackID)
        }.prefix(2)
        let absoluteTarget = target + startTime.seconds
        var packets: [Packet] = [], bytes = 0, attempts = 0
        subtitlePrerollDeadline = CACurrentMediaTime() + 2
        defer { subtitlePrerollDeadline = nil }
        for track in selected {
            guard attempts < 512, bytes < 4 * 1024 * 1024,
                  CACurrentMediaTime() < (subtitlePrerollDeadline ?? 0) else { break }
            guard state == .seeking, seekTime == target, let stream = formatCtx.pointee.streams[Int(track.trackID)],
                  avformat_index_get_entries_count(stream) > 0 else { continue }
            let timestamp = Int64((absoluteTarget * Double(track.timebase.den) / Double(track.timebase.num)).rounded())
            guard avformat_seek_file(formatCtx, track.trackID, Int64.min, timestamp, timestamp, AVSEEK_FLAG_BACKWARD) >= 0 else { continue }
            while attempts < 512, bytes < 4 * 1024 * 1024, state == .seeking, seekTime == target,
                  CACurrentMediaTime() < (subtitlePrerollDeadline ?? 0) {
                let packet = Packet()
                guard let native = packet.corePacket, av_read_frame(formatCtx, native) >= 0 else { break }
                attempts += 1; bytes += max(0, Int(native.pointee.size))
                guard native.pointee.stream_index == track.trackID else { continue }
                packet.assetTrack = track
                let start = packet.seconds
                let duration = track.timebase.cmtime(for: packet.duration).seconds
                if start <= absoluteTarget, duration > 0, start + duration >= absoluteTarget { packets.append(packet) }
                // The indexed subtitle packet is either the containing cue or
                // its successor. Do not scan a long empty subtitle interval.
                break
            }
        }
        return packets
    }

    private func consumesInjectedSubtitleDuplicate(_ packet: Packet) -> Bool {
        guard let incoming = packet.corePacket?.pointee, let data = incoming.data, incoming.size > 0,
              let index = injectedSubtitlePackets.firstIndex(where: { saved in
                  guard let previous = saved.corePacket?.pointee, let bytes = previous.data else { return false }
                  return previous.stream_index == incoming.stream_index && previous.pts == incoming.pts
                      && previous.dts == incoming.dts && previous.pos == incoming.pos
                      && previous.duration == incoming.duration && previous.size == incoming.size
                      && Data(bytes: bytes, count: Int(previous.size)) == Data(bytes: data, count: Int(incoming.size))
              }) else { return false }
        injectedSubtitlePackets.remove(at: index)
        return true
    }

    /// Demux on the reader thread. Dolby EL access units supply only RPU;
    /// the output contains the unchanged base AU and converted single-layer RPU.
    private func readColorPacket(into packet: UnsafeMutablePointer<AVPacket>) throws -> Int32 {
        while true {
            if let ready = try dolbyPacketPairer?.takeReady() {
                av_packet_move_ref(packet, ready.packet)
                return 0
            }
            let status: Int32
            if colorProbePacketIndex < colorProbePackets.count {
                colorProbePackets[colorProbePacketIndex].move(to: packet)
                colorProbePacketIndex += 1
                if colorProbePacketIndex == colorProbePackets.count {
                    colorProbePackets.removeAll(); colorProbePacketIndex = 0
                }
                status = 0
            } else {
                status = av_read_frame(formatCtx, packet)
            }
            guard status == 0 else {
                if status == AVError.eof.code, dolbyPacketPairer?.hasUnmatchedBase == true {
                    throw DolbyVisionPacketPairer.Failure.missingRPU
                }
                return status
            }
            if let converter = inlineDolbyConverters[packet.pointee.stream_index] {
                try converter.convert(packet: packet)
                return status
            }
            guard let pairer = dolbyPacketPairer,
                  packet.pointee.stream_index == pairer.baseTrackID || packet.pointee.stream_index == pairer.enhancementTrackID
            else { return status }
            try pairer.append(packet: packet)
            av_packet_unref(packet)
        }
    }

    private func reading() -> Int32 {
        defer { cacheInputIO.publishBytes() }
        let packet = Packet()
        guard let corePacket = packet.corePacket else {
            return 0
        }
        let readResult: Int32
        do { readResult = try readColorPacket(into: corePacket) }
        catch {
            if state == .closed { return 0 }
            self.error = NSError(description: "杜比视界 P7 转 P8.1 失败：原始 RPU 或对应视频帧不可用，请切换线路。")
            return AVError.invalidData.code
        }
        if state == .closed {
            return 0
        }
        if readResult == 0 {
            if let outputFormatCtx, let formatCtx {
                let index = Int(corePacket.pointee.stream_index)
                if let outputIndex = streamMapping[index],
                   let inputTb = formatCtx.pointee.streams[index]?.pointee.time_base,
                   let outputTb = outputFormatCtx.pointee.streams[outputIndex]?.pointee.time_base,
                   let outputPacket
                {
                    av_packet_ref(outputPacket, corePacket)
                    outputPacket.pointee.stream_index = Int32(outputIndex)
                    av_packet_rescale_ts(outputPacket, inputTb, outputTb)
                    outputPacket.pointee.pos = -1
                    let ret = av_interleaved_write_frame(outputFormatCtx, outputPacket)
                    if ret < 0 {
                        KSLog("can not av_interleaved_write_frame")
                    }
                }
            }
            if corePacket.pointee.size <= 0 {
                return 0
            }
            let first = assetTracks.first { $0.trackID == corePacket.pointee.stream_index }
            if let first, first.isEnabled {
                // 区间无缝循环触发（与下方 isLoopPlay EOF 触发平行）：
                // packet PTS 越过 loopRange.upperBound 即把 audio/video track 切到 loopModel，
                // av_seek_frame 回 lowerBound——后续 packet 进 loopPacketQueue，等当前
                // packetQueue 播完由 codecDidFinished swap，实现区间无 decode-forward 循环。
                //
                // 触发判断只看 audio/video 的 isLoopModel：subtitle 用 SyncPlayerItemTrack，
                // 没有 loopPacketQueue 与 swap，其 isLoopModel 一旦被置 true 也没有路径翻回 false——
                // 用 allPlayerItemTracks.allSatisfy 会让带内嵌字幕的视频在第二圈无法重触发。
                if let loopRange = options.loopRange,
                   !options.isLoopPlay,
                   first.mediaType == .video || first.mediaType == .audio,
                   corePacket.pointee.pts != .min,  // AV_NOPTS_VALUE
                   audioTrack?.isLoopModel != true,
                   videoTrack?.isLoopModel != true
                {
                    let tb = first.timebase
                    let pktPlaybackSec = Double(corePacket.pointee.pts) * Double(tb.num) / Double(tb.den) - startTime.seconds
                    if pktPlaybackSec > loopRange.upperBound {
                        audioTrack?.isLoopModel = true
                        videoTrack?.isLoopModel = true
                        let target = startTime + CMTime(seconds: loopRange.lowerBound, preferredTimescale: CMTimeScale(AV_TIME_BASE))
                        do { try seekLoopDemux(to: target, relativeTime: loopRange.lowerBound) }
                        catch {
                            self.error = NSError(description: "杜比视界循环元数据恢复失败，请重新播放。")
                            return AVError.invalidData.code
                        }
                        return readResult  // 当前 packet 已越界，丢弃；下一次 read 从 lowerBound 关键帧开始
                    }
                }
                packet.assetTrack = first
                #if DEBUG
                if seekTracePacketsRemaining > 0, first.mediaType == .video || first.mediaType == .audio {
                    seekTracePacketsRemaining -= 1
                    let timebase = first.timebase
                    seekTrace += ";\(first.mediaType == .video ? "v" : "a")=\(timebase.cmtime(for: corePacket.pointee.pts).seconds)/\(timebase.cmtime(for: corePacket.pointee.dts).seconds)/\(packet.isKeyFrame ? 1 : 0)"
                }
                #endif
                if first.mediaType == .video {
                    if options.readVideoTime == 0 {
                        options.readVideoTime = CACurrentMediaTime()
                    }
                    videoTrack?.putPacket(packet: packet)
                } else if first.mediaType == .audio {
                    if options.readAudioTime == 0 {
                        options.readAudioTime = CACurrentMediaTime()
                    }
                    audioTrack?.putPacket(packet: packet)
                } else {
                    if !consumesInjectedSubtitleDuplicate(packet) { first.subtitle?.putPacket(packet: packet) }
                }
            }
        } else {
            // AVIO also sets eof_reached after transport/seek errors. Preserve
            // the demuxer's error so recovery can reopen a failed Range read;
            // otherwise a partial MP4 before its first packet waits forever.
            if readResult == AVError.eof.code {
                if options.isLoopPlay, allPlayerItemTracks.allSatisfy({ !$0.isLoopModel }) {
                    allPlayerItemTracks.forEach { $0.isLoopModel = true }
                    do { try seekLoopDemux(to: startTime, relativeTime: 0) }
                    catch {
                        self.error = NSError(description: "杜比视界循环元数据恢复失败，请重新播放。")
                        return AVError.invalidData.code
                    }
                } else {
                    allPlayerItemTracks.forEach { $0.isEndOfFile = true }
                    state = .finished
                }
            } else {
                //                        if IS_AVERROR_INVALIDDATA(readResult)
                error = .init(errorCode: .readFrame, avErrorCode: readResult)
            }
        }
        return readResult
    }

    /// The seamless-loop queues keep their existing ownership. Only the
    /// demux/RPU epoch resets when the input jumps backwards.
    private func seekLoopDemux(to target: CMTime, relativeTime: TimeInterval) throws {
        guard dolbyPacketPairer != nil || !inlineDolbyConverters.isEmpty else {
            _ = av_seek_frame(formatCtx, -1, target.value, AVSEEK_FLAG_BACKWARD)
            return
        }
        colorProbePackets.removeAll(); colorProbePacketIndex = 0
        dolbyPacketPairer?.reset()
        inlineDolbyConverters.values.forEach { $0.reset() }
        guard av_seek_frame(formatCtx, -1, target.value, AVSEEK_FLAG_BACKWARD) >= 0 else {
            throw DolbyVisionPacketPairer.Failure.invalidTimestamp
        }
        try warmDolbyMetadata(at: relativeTime)
        guard av_seek_frame(formatCtx, -1, target.value, AVSEEK_FLAG_BACKWARD) >= 0 else {
            throw DolbyVisionPacketPairer.Failure.invalidTimestamp
        }
    }

    private func pause() {
        if state == .reading {
            state = .paused
        }
    }

    private func resume() {
        if state == .paused {
            state = .reading
            condition.signal()
        }
    }
}

// MARK: MediaPlayback

extension MEPlayerItem: MediaPlayback {
    var seekable: Bool {
        guard let formatCtx else {
            return false
        }
        guard formatCtx.pointee.ctx_flags & AVFMTCTX_UNSEEKABLE == 0 else { return false }
        // HLS/DASH seek in their segment demuxers. The manifest's HTTP AVIO
        // may be a streamed/chunked response and cannot answer byte seeks.
        if options.formatName == "hls" || options.formatName == "dash" {
            return duration.isFinite && duration > 0
        }
        var seekable = true
        if let ioContext = formatCtx.pointee.pb {
            seekable = ioContext.pointee.seekable > 0
        }
        return seekable
    }

    public func prepareToPlay() {
        state = .opening
        openOperation = BlockOperation { [weak self] in
            guard let self else { return }
            Thread.current.name = (self.operationQueue.name ?? "") + "_open"
            Thread.current.stackSize = KSOptions.stackSize
            self.openThread()
        }
        openOperation?.queuePriority = .veryHigh
        openOperation?.qualityOfService = .userInteractive
        if let openOperation {
            operationQueue.addOperation(openOperation)
        }
    }

    public func shutdown() {
        guard state != .closed else { return }
        invalidateAudioClockUpdates()
        state = .closed
        av_packet_free(&outputPacket)
        stopRecord()
        // 故意循环引用。等结束了。才释放
        let closeOperation = BlockOperation {
            Thread.current.name = (self.operationQueue.name ?? "") + "_close"
            self.allPlayerItemTracks.forEach { $0.shutdown() }
            self.colorProbePackets.removeAll(); self.colorProbePacketIndex = 0
            self.dolbyPacketPairer = nil
            self.inlineDolbyConverters.removeAll()
            KSLog("清空formatCtx")
            // 自定义的协议才会av_class为空
            if let formatCtx = self.formatCtx, (formatCtx.pointee.flags & AVFMT_FLAG_CUSTOM_IO) != 0, let opaque = formatCtx.pointee.pb.pointee.opaque {
                let value = Unmanaged<AbstractAVIOContext>.fromOpaque(opaque).takeRetainedValue()
                value.close()
            }
            // 不要自己来释放pb。不然第二次播放同一个url会出问题
//            self.formatCtx?.pointee.pb = nil
            self.formatCtx?.pointee.interrupt_callback.opaque = nil
            self.formatCtx?.pointee.interrupt_callback.callback = nil
            avformat_close_input(&self.formatCtx)
            avformat_close_input(&self.outputFormatCtx)
            self.duration = 0
            self.closeOperation = nil
            self.operationQueue.cancelAllOperations()
        }
        closeOperation.queuePriority = .veryHigh
        closeOperation.qualityOfService = .userInteractive
        if let readOperation {
            readOperation.cancel()
            closeOperation.addDependency(readOperation)
        } else if let openOperation {
            openOperation.cancel()
            closeOperation.addDependency(openOperation)
        }
        operationQueue.addOperation(closeOperation)
        condition.signal()
        if options.syncDecodeVideo || options.syncDecodeAudio {
            DispatchQueue.global().async { [weak self] in
                self?.allPlayerItemTracks.forEach { $0.shutdown() }
            }
        }
        self.closeOperation = closeOperation
    }

    func stopRecord() {
        if let outputFormatCtx {
            av_write_trailer(outputFormatCtx)
        }
    }

    public func seek(time: TimeInterval, completion: @escaping ((Bool) -> Void)) {
        if state == .reading || state == .paused || state == .finished || state == .seeking {
            invalidateAudioClockUpdates()
        }
        if state == .reading || state == .paused {
            seekTime = time
            state = .seeking
            seekingCompletionHandler = completion
            condition.broadcast()
            allPlayerItemTracks.forEach { $0.seek(time: time + startTime.seconds) }
        } else if state == .finished {
            seekTime = time
            state = .seeking
            seekingCompletionHandler = completion
            read()
        } else if state == .seeking {
            seekTime = time
            seekingCompletionHandler = completion
        } else {
            DispatchQueue.main.async { completion(false) }
            return
        }
        isAudioStalled = audioTrack == nil
    }
}

extension MEPlayerItem: CodecCapacityDelegate {
    func codecDidChangeCapacity() {
        let loadingState = options.playable(capacitys: videoAudioTracks, isFirst: isFirst, isSeek: isSeek)
        delegate?.sourceDidChange(loadingState: loadingState)
        if loadingState.isPlayable {
            isFirst = false
            isSeek = false
            if loadingState.loadedTime > options.maxBufferDuration {
                adaptableVideo(loadingState: loadingState)
                pause()
            } else if loadingState.loadedTime < options.maxBufferDuration / 2 {
                resume()
            }
        } else {
            resume()
            adaptableVideo(loadingState: loadingState)
        }
    }

    func codecDidFinished(track: some CapacityProtocol) {
        if track.mediaType == .audio {
            isAudioStalled = true
        }
        let allSatisfy = videoAudioTracks.allSatisfy { $0.isEndOfFile && $0.frameCount == 0 && $0.packetCount == 0 }
        if allSatisfy {
            // 区间循环 swap：当前 iteration 的 packet/frame 全播完，把 loopPacketQueue 切换为活动 queue。
            // 与 isLoopPlay 整文件循环的差异：
            // 1. 不调 delegate?.sourceDidFinished()——避免上层把 playbackState 翻成 .finished
            // 2. 不停 capacity timer（timer.fireDate = .distantFuture）——下一圈仍要继续工作
            // 3. 设 track.seekTime 让 decoder 丢弃 loopPacketQueue 头部不需要的预滚帧
            //
            // 判断条件用 audioTrack?.isLoopModel / videoTrack?.isLoopModel 而非 options.loopRange != nil：
            // 调用方中途清空 loopRange 时，若刚好处于"trigger 已发生 swap 还没发生"窗口内，
            // tracks 仍处 loopModel——此时若不走本分支，会掉到下方 delegate?.sourceDidFinished()
            // 把 playbackState 置为 .finished，且无法通过 play() 恢复（所有 track 已 EOF 无帧可解）。
            if !options.isLoopPlay && (audioTrack?.isLoopModel == true || videoTrack?.isLoopModel == true) {
                isAudioStalled = audioTrack == nil
                let trimSec: TimeInterval
                if let loopRange = options.loopRange {
                    // 仍在循环：trim 到 lowerBound（AVSEEK_FLAG_BACKWARD 落到 ≤ lowerBound 的关键帧，
                    // 不设 seekTime decoder 会把 lowerBound 之前的内容也播出来）
                    trimSec = loopRange.lowerBound + startTime.seconds
                } else {
                    // 已退出循环：trim 到当前播放点，让 decoder 跳过 loopPacketQueue 里
                    // lowerBound→当前位置 的预读，从当前位置接续往后播（避免回跳到 lowerBound）
                    trimSec = currentPlaybackTime + startTime.seconds
                }
                audioTrack?.seekTime = trimSec
                videoTrack?.seekTime = trimSec
                audioTrack?.isLoopModel = false
                videoTrack?.isLoopModel = false
                return
            }
            delegate?.sourceDidFinished()
            timer.fireDate = Date.distantFuture
            if options.isLoopPlay {
                isAudioStalled = audioTrack == nil
                audioTrack?.isLoopModel = false
                videoTrack?.isLoopModel = false
                if state == .finished {
                    seek(time: 0) { _ in }
                }
            }
        }
    }

    private func adaptableVideo(loadingState: LoadingState) {
        if options.videoDisable || videoAdaptation == nil || loadingState.isEndOfFile || loadingState.isSeek || state == .seeking {
            return
        }
        guard let track = videoTrack else {
            return
        }
        videoAdaptation?.loadedCount = track.packetCount + track.frameCount
        videoAdaptation?.currentPlaybackTime = currentPlaybackTime
        videoAdaptation?.isPlayable = loadingState.isPlayable
        guard let (oldBitRate, newBitrate) = options.adaptable(state: videoAdaptation), oldBitRate != newBitrate,
              let newFFmpegAssetTrack = assetTracks.first(where: { $0.mediaType == .video && $0.bitRate == newBitrate })
        else {
            return
        }
        assetTracks.first { $0.mediaType == .video && $0.bitRate == oldBitRate }?.isEnabled = false
        newFFmpegAssetTrack.isEnabled = true
        findBestAudio(videoTrack: newFFmpegAssetTrack)
        let bitRateState = VideoAdaptationState.BitRateState(bitRate: newBitrate, time: CACurrentMediaTime())
        videoAdaptation?.bitRateStates.append(bitRateState)
        delegate?.sourceDidChange(oldBitRate: oldBitRate, newBitrate: newBitrate)
    }

    private func findBestAudio(videoTrack: FFmpegAssetTrack) {
        guard videoAdaptation != nil, let first = assetTracks.first(where: { $0.mediaType == .audio && $0.isEnabled }) else {
            return
        }
        let index = av_find_best_stream(formatCtx, AVMEDIA_TYPE_AUDIO, -1, videoTrack.trackID, nil, 0)
        if index != first.trackID {
            first.isEnabled = false
            assetTracks.first { $0.mediaType == .audio && $0.trackID == index }?.isEnabled = true
        }
    }
}

extension MEPlayerItem: OutputRenderSourceDelegate {
    func mainClock() -> KSClock {
        if let clock = externalAudioClock?() { return clock.shifted(by: startTime.seconds) }
        return isAudioStalled ? videoClock : audioClockLock.withLock { audioClock }
    }

    func relativeAudioClock() -> KSClock? {
        guard !isAudioStalled else { return nil }
        return audioClockLock.withLock { audioClock.shifted(by: -startTime.seconds) }
    }

    public func setVideo(time: CMTime, position: Int64) {
//        print("[video] video interval \(CACurrentMediaTime() - videoClock.lastMediaTime) video diff \(time.seconds - videoClock.time.seconds)")
        videoClock.time = time
        videoClock.position = position
        videoDisplayCount += 1
        let diff = videoClock.lastMediaTime - lastVideoDisplayTime
        if diff > 1 {
            dynamicInfo.displayFPS = Double(videoDisplayCount) / diff
            videoDisplayCount = 0
            lastVideoDisplayTime = videoClock.lastMediaTime
        }
    }

    public func setAudio(time: CMTime, position: Int64) {
        // The PTS describes this render callback, not a later main-queue task.
        // Publish a value snapshot under the existing short clock lock; no UI
        // work, decoding, waiting for queues or task allocation belongs here.
        audioClockLock.lock(); defer { audioClockLock.unlock() }
        guard audioClockUpdatesEnabled else { return }
        audioClock.time = time
        audioClock.position = position
    }

    func updateAudioClockPlayback(isPlaying: Bool, rate: Double) {
        audioClockLock.lock(); defer { audioClockLock.unlock() }
        audioClock.updatePlayback(isPlaying: isPlaying, rate: rate)
    }

    private func invalidateAudioClockUpdates() {
        audioClockLock.lock(); defer { audioClockLock.unlock() }
        audioClockGeneration &+= 1
        audioClockUpdatesEnabled = false
    }

    private func finishAudioClockSeek(time: CMTime, generation: UInt64) {
        audioClockLock.lock(); defer { audioClockLock.unlock() }
        guard audioClockGeneration == generation else { return }
        audioClock.time = time
        audioClockUpdatesEnabled = true
    }

    public func getVideoOutputRender(force: Bool) -> VideoVTBFrame? {
        guard let videoTrack else {
            return nil
        }
        var type: ClockProcessType = force ? .next : .remain
        var recoveryFrameCount = 0
        let predicate: ((VideoVTBFrame, Int) -> Bool)? = force ? nil : { [weak self] frame, count -> Bool in
            guard let self else { return true }
            recoveryFrameCount = max(0, count - 1)
            (self.dynamicInfo.audioVideoSyncDiff, type) = self.options.videoClockSync(main: self.mainClock(), nextVideoTime: frame.seconds, fps: Double(frame.fps), frameCount: count, videoOnly: self.isAudioStalled && self.externalAudioClock?() == nil)
            return type != .remain
        }
        var frame = videoTrack.getOutputRender(where: predicate)
        switch type {
        case .remain:
            break
        case .next:
            break
        case .dropNextFrame:
            // Catch up by replacing the stale picture with a newer due one.
            // Dropping the next picture while showing the old one reverses
            // recovery and can lose the only frame after a segment/PTS gap.
            // Reuse the clock snapshot that classified the stale picture;
            // a future candidate stays in the queue until it becomes due.
            let desiredTime = frame.map { $0.seconds - dynamicInfo.audioVideoSyncDiff }
            if let desiredTime {
                // A missed display tick can leave several already-decoded
                // pictures behind audio. Replacing only one cannot recover a
                // 60 fps source at 30 Hz and eventually flushes the backlog.
                // Limit work to the queue snapshot so a refilling decoder
                // cannot keep this display callback spinning indefinitely.
                // The first predicate captured the count under the queue lock.
                for _ in 0 ..< recoveryFrameCount {
                    guard let next = videoTrack.getOutputRender(where: { candidate, _ in
                        let fps = candidate.fps.isFinite && candidate.fps > 0 ? Double(candidate.fps) : 60
                        return candidate.seconds - desiredTime < 1 / fps / 2
                    }) else { break }
                    frame = next
                    dynamicInfo.audioVideoSyncDiff = next.seconds - desiredTime
                    dynamicInfo.droppedVideoFrameCount += 1
                }
                if let frame {
                    options.videoClockDidCatchUp(diff: dynamicInfo.audioVideoSyncDiff, fps: Double(frame.fps))
                }
            }
        case .flush:
            let count = videoTrack.outputRenderQueue.count
            videoTrack.outputRenderQueue.flush()
            dynamicInfo.droppedVideoFrameCount += UInt32(count)
        case .seek:
            videoTrack.outputRenderQueue.flush()
            videoTrack.seekTime = mainClock().time.seconds
        case .dropNextPacket:
            if let videoTrack = videoTrack as? AsyncPlayerItemTrack {
                let packet = videoTrack.packetQueue.pop { item, _ -> Bool in
                    !item.isKeyFrame
                }
                if packet != nil {
                    dynamicInfo.droppedVideoPacketCount += 1
                }
            }
        case .dropGOPPacket:
            if let videoTrack = videoTrack as? AsyncPlayerItemTrack {
                var packet: Packet? = nil
                repeat {
                    packet = videoTrack.packetQueue.pop { item, _ -> Bool in
                        !item.isKeyFrame
                    }
                    if packet != nil {
                        dynamicInfo.droppedVideoPacketCount += 1
                    }
                } while packet != nil
            }
        }
        return frame
    }

    public func getAudioOutputRender() -> AudioFrame? {
        if let frame = audioTrack?.getOutputRender(where: nil) {
            SubtitleModel.audioRecognizes.first {
                $0.isEnabled
            }?.append(frame: frame)
            return frame
        } else {
            return nil
        }
    }
}

extension AbstractAVIOContext {
    func getContext() -> UnsafeMutablePointer<AVIOContext> {
        // 需要持有ioContext，不然会被释放掉,等到shutdown在清空
        avio_alloc_context(av_malloc(Int(bufferSize)), bufferSize, writable ? 1 : 0, Unmanaged.passRetained(self).toOpaque()) { opaque, buffer, size -> Int32 in
            let value = Unmanaged<AbstractAVIOContext>.fromOpaque(opaque!).takeUnretainedValue()
            let ret = value.read(buffer: buffer, size: size)
            return Int32(ret)
        } _: { opaque, buffer, size -> Int32 in
            let value = Unmanaged<AbstractAVIOContext>.fromOpaque(opaque!).takeUnretainedValue()
            let ret = value.write(buffer: buffer, size: size)
            return Int32(ret)
        } _: { opaque, offset, whence -> Int64 in
            let value = Unmanaged<AbstractAVIOContext>.fromOpaque(opaque!).takeUnretainedValue()
            if whence == AVSEEK_SIZE {
                return value.fileSize()
            }
            return value.seek(offset: offset, whence: whence)
        }
    }
}
