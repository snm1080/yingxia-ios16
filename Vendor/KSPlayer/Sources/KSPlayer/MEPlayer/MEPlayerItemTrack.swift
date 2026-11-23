//
//  Decoder.swift
//  KSPlayer
//
//  Created by kintan on 2018/3/9.
//
import AVFoundation
import CoreMedia
import FFmpegKit
protocol PlayerItemTrackProtocol: CapacityProtocol, AnyObject {
    init(mediaType: AVFoundation.AVMediaType, frameCapacity: UInt8, options: KSOptions)
    // 是否无缝循环
    var isLoopModel: Bool { get set }
    var isEndOfFile: Bool { get set }
    var delegate: CodecCapacityDelegate? { get set }
    func decode()
    func seek(time: TimeInterval)
    func putPacket(packet: Packet)
//    func getOutputRender<Frame: ObjectQueueItem>(where predicate: ((Frame) -> Bool)?) -> Frame?
    func shutdown()
    func shutdownAndWait()
}

class SyncPlayerItemTrack<Frame: MEFrame>: PlayerItemTrackProtocol, CustomStringConvertible {
    var seekTime = 0.0
    fileprivate let options: KSOptions
    private let decoderLock = NSLock()
    private var ownedDecoders = [Int32: DecodeProtocol]()
    fileprivate var decoderMap: [Int32: DecodeProtocol] {
        get { decoderLock.withLock { ownedDecoders } }
        set { decoderLock.withLock { ownedDecoders = newValue } }
    }
    private func isCurrentDecoder(_ decoder: DecodeProtocol, trackID: Int32) -> Bool {
        decoderLock.withLock { ownedDecoders[trackID] === decoder }
    }
    /// Synchronous FFmpeg callbacks run on the demux/decode owner. The async
    /// track overrides this to wake its existing worker; native VT callbacks
    /// must never create or feed another codec themselves.
    fileprivate func scheduleDecoderFailure(_ decoder: DecodeProtocol, generation: UInt64,
                                             work: @escaping () -> Void) { work() }
    fileprivate var state = MECodecState.idle {
        didSet {
            if state == .finished {
                seekTime = 0
            }
        }
    }

    var isEndOfFile: Bool = false
    var packetCount: Int { 0 }
    var packetByteCount: Int64 { 0 }
    var loadedTime: TimeInterval { TimeInterval(frameCount) / TimeInterval(fps) }
    let description: String
    weak var delegate: CodecCapacityDelegate?
    let mediaType: AVFoundation.AVMediaType
    let outputRenderQueue: CircularBuffer<Frame>
    var isLoopModel = false
    var frameCount: Int { outputRenderQueue.count }
    var frameMaxCount: Int {
        outputRenderQueue.maxCount
    }

    var fps: Float {
        outputRenderQueue.fps
    }

    required init(mediaType: AVFoundation.AVMediaType, frameCapacity: UInt8, options: KSOptions) {
        self.options = options
        self.mediaType = mediaType
        description = mediaType.rawValue
        // 默认缓存队列大小跟帧率挂钩,经测试除以4，最优
        if mediaType == .audio {
            outputRenderQueue = CircularBuffer(initialCapacity: Int(frameCapacity), expanding: false)
        } else if mediaType == .video {
            outputRenderQueue = CircularBuffer(initialCapacity: Int(frameCapacity), sorted: true, expanding: false)
        } else {
            // 有的图片字幕不按顺序来输出，所以要排序下。
            outputRenderQueue = CircularBuffer(initialCapacity: Int(frameCapacity), sorted: true)
        }
    }

    func decode() {
        isEndOfFile = false
        state = .decoding
    }

    func seek(time: TimeInterval) {
        // Changing the timeline and accepting a decoded frame share the output
        // queue lock. Its blocking producer wait releases that lock normally.
        outputRenderQueue.flush(advanceGeneration: true) {
            // Subtitles have intervals (including indefinite bitmap updates),
            // and a cue can begin before the target while remaining visible.
            // Their SubtitlePart search owns expiry/selection; MEFrame's zero
            // duration must not discard the active cue during decode pre-roll.
            self.seekTime = self.options.isAccurateSeek && self.mediaType != .subtitle ? time : 0
            self.isEndOfFile = false
            self.state = .flush
        }
        isLoopModel = false
    }

    func putPacket(packet: Packet) {
        let generation = outputRenderQueue.generation
        packet.decodeGeneration = generation
        if state == .flush {
            decoderMap.values.forEach { $0.doFlushCodec() }
            guard outputRenderQueue.perform(ifGeneration: generation, { self.state = .decoding }) else { return }
        }
        if state == .decoding {
            doDecode(packet: packet)
        }
    }

    func getOutputRender(where predicate: ((Frame, Int) -> Bool)?) -> Frame? {
        let outputFecthRender = outputRenderQueue.pop(where: predicate)
        if outputFecthRender == nil {
            if state == .finished, frameCount == 0 {
                delegate?.codecDidFinished(track: self)
            }
        }
        return outputFecthRender
    }

    func shutdown() {
        state = .closed
        outputRenderQueue.shutdown()
    }

    /// Called only on the reader's closing worker, after demuxing has stopped.
    func shutdownAndWait() {
        shutdown()
        decoderMap.values.forEach { $0.shutdown() }
        decoderMap.removeAll()
    }

    private var lastPacketBytes = Int32(0)
    private var lastPacketSeconds = Double(-1)
    var bitrate = Double(0)
    #if DEBUG
    private let diagnosticLock = NSLock()
    private var diagnosticGeneration: UInt64?
    private var diagnosticCounts: [String: Int] = [:]
    private var diagnosticTrace = ""
    var decodeDiagnostic: String { diagnosticLock.withLock { diagnosticTrace } }
    private func traceDecode(_ event: String, generation: UInt64, detail: @autoclosure () -> String) {
        diagnosticLock.withLock {
            if diagnosticGeneration != generation {
                diagnosticGeneration = generation; diagnosticCounts = [:]; diagnosticTrace = "g=\(generation)"
            }
            let count = diagnosticCounts[event, default: 0]
            guard count < (event == "in" ? 8 : 3) else { return }
            diagnosticCounts[event] = count + 1
            diagnosticTrace += ";\(event)=\(detail())"
        }
    }
    #endif
    fileprivate func doDecode(packet: Packet) {
        let generation = packet.decodeGeneration ?? outputRenderQueue.generation
        if packet.isKeyFrame, packet.assetTrack.mediaType != .subtitle {
            let seconds = packet.seconds
            let diff = seconds - lastPacketSeconds
            if lastPacketSeconds < 0 || diff < 0 {
                bitrate = 0
                lastPacketBytes = 0
                lastPacketSeconds = seconds
            } else if diff > 1 {
                bitrate = Double(lastPacketBytes) / diff
                lastPacketBytes = 0
                lastPacketSeconds = seconds
            }
        }
        lastPacketBytes += packet.size
        let decoder = decoderLock.withLock {
            ownedDecoders.value(for: packet.assetTrack.trackID, default: makeDecode(assetTrack: packet.assetTrack))
        }
        #if DEBUG
        if mediaType == .video {
            traceDecode("in", generation: generation, detail: "\(packet.seconds)/\(packet.corePacket?.pointee.flags ?? 0)/\(type(of: decoder))")
        }
        #endif
//        var startTime = CACurrentMediaTime()
        decoder.decodeFrame(from: packet) { [weak self] result in
            guard let self else {
                return
            }
            guard self.state != .closed, self.state != .failed,
                  self.outputRenderQueue.generation == generation,
                  self.isCurrentDecoder(decoder, trackID: packet.assetTrack.trackID) else { return }
            do {
//                if packet.assetTrack.mediaType == .video {
//                    print("[video] decode time: \(CACurrentMediaTime()-startTime)")
//                    startTime = CACurrentMediaTime()
//                }
                let frame = try result.get()
                if self.state == .flush || self.state == .closed {
                    return
                }
                if let frame = frame as? Frame {
                    let timestamp = frame.timestamp + frame.duration
                    let endTime = frame.timebase.cmtime(for: timestamp).seconds
                    #if DEBUG
                    if self.mediaType == .video {
                        self.traceDecode("out", generation: generation, detail: "\(frame.timebase.cmtime(for: frame.timestamp).seconds)/limit=\(self.seekTime)")
                    }
                    #endif
                    self.outputRenderQueue.push(frame, generation: generation) {
                        guard self.state != .flush, self.state != .closed, self.state != .failed,
                              self.isCurrentDecoder(decoder, trackID: packet.assetTrack.trackID) else { return false }
                        if self.seekTime > 0 {
                            guard timestamp > 0, endTime >= self.seekTime else { return false }
                            self.seekTime = 0
                        }
                        #if DEBUG
                        if self.mediaType == .video {
                            self.traceDecode("accepted", generation: generation, detail: "\(frame.timebase.cmtime(for: frame.timestamp).seconds)")
                        }
                        #endif
                        return true
                    }
                    self.outputRenderQueue.fps = packet.assetTrack.nominalFrameRate
                }
            } catch {
                self.scheduleDecoderFailure(decoder, generation: generation) { [weak self] in
                    guard let self, self.state != .closed, self.state != .failed,
                          self.outputRenderQueue.generation == generation,
                          self.isCurrentDecoder(decoder, trackID: packet.assetTrack.trackID) else { return }
                    KSLog("Decoder did Failed : \(error)")
                    if self.mediaType == .video {
                        let failure = error as NSError
                        // AVError is a Swift value: bridging it directly to NSError
                        // loses its native status. Preserve that numeric code only.
                        var details: [String: Any] = [:]
                        if let cause = failure.userInfo[NSUnderlyingErrorKey] as? AVError {
                            details[NSUnderlyingErrorKey] = NSError(domain: "KSPlayer.NativeCodec", code: Int(cause.code))
                        } else if let cause = failure.userInfo[NSUnderlyingErrorKey] as? NSError {
                            details[NSUnderlyingErrorKey] = NSError(domain: cause.domain, code: cause.code)
                        }
                        self.options.onVideoDecoderError?(NSError(domain: failure.domain, code: failure.code, userInfo: details))
                    }
                    if decoder is VideoToolboxDecode, !packet.assetTrack.requiresNativeDolbyVision {
                        // Deliberate local deviation (see Vendor/KSPlayer/UPSTREAM.md):
                        // on the user's A12/iOS 16.6 the native VT decoder can trip on
                        // streams that FFmpeg's VT hwaccel handles fine, and build 23's
                        // behavior was proven on-device, so the replacement inherits
                        // options and may use VideoToolbox hwaccel.
                        let replacement = FFmpegDecode(assetTrack: packet.assetTrack, options: self.options)
                        var replaced = false
                        let changed = self.outputRenderQueue.perform(ifGeneration: generation) {
                            self.decoderLock.withLock {
                                guard self.ownedDecoders[packet.assetTrack.trackID] === decoder else { return }
                                self.ownedDecoders[packet.assetTrack.trackID] = replacement
                                replaced = true
                            }
                        }
                        guard changed, replaced else { replacement.shutdown(); return }
                        // A prior native success callback can still be waiting
                        // on a full/paused output queue. Retire those pictures
                        // before joining VT callbacks; identity checks reject
                        // any late frame without invalidating queued packets.
                        self.outputRenderQueue.flush()
                        decoder.shutdown()
                        self.options.onVideoDecoderChanged?("FFmpeg")
                        KSLog("VideoCodec switch to software decompression")
                        if self.outputRenderQueue.generation == generation { self.doDecode(packet: packet) }
                    } else {
                        guard self.outputRenderQueue.perform(ifGeneration: generation, { self.state = .failed }) else { return }
                        if self.mediaType == .video {
                            let message = packet.assetTrack.requiresNativeDolbyVision
                                ? "当前设备无法解码这条杜比视界视频，请选择其他画质或线路。" : "视频解码失败，请切换解码方式或线路。"
                            self.options.onVideoDecoderFailed?(message)
                        } else if self.mediaType == .audio {
                            // A dead audio queue otherwise keeps common readiness
                            // false while the demuxer continues downloading video.
                            let failure = NSError(
                                domain: KSPlayerErrorDomain, code: KSPlayerErrorCode.codecAudioReceiveFrame.rawValue,
                                userInfo: [NSLocalizedDescriptionKey: "音频解码失败，请切换音轨或线路。",
                                           NSUnderlyingErrorKey: error as NSError])
                            DispatchQueue.main.async { [weak self] in
                                guard let self, self.state == .failed,
                                      self.outputRenderQueue.generation == generation else { return }
                                self.delegate?.codecDidFailed(track: self, error: failure)
                            }
                        }
                    }
                }
            }
        }
        if options.decodeAudioTime == 0, mediaType == .audio {
            options.decodeAudioTime = CACurrentMediaTime()
        }
        if options.decodeVideoTime == 0, mediaType == .video {
            options.decodeVideoTime = CACurrentMediaTime()
        }
    }
}

final class AsyncPlayerItemTrack<Frame: MEFrame>: SyncPlayerItemTrack<Frame> {
    private let operationQueue = OperationQueue()
    private var decodeOperation: BlockOperation!
    private let decoderWorkLock = NSLock()
    private var decoderWork: [ObjectIdentifier: (UInt64, () -> Void)] = [:]
    override fileprivate func scheduleDecoderFailure(_ decoder: DecodeProtocol, generation: UInt64,
                                                       work: @escaping () -> Void) {
        decoderWorkLock.withLock {
            let key = ObjectIdentifier(decoder)
            if decoderWork[key]?.0 != generation { decoderWork[key] = (generation, work) }
        }
        packetQueue.wake()
    }
    private func drainDecoderWork() {
        let work = decoderWorkLock.withLock { () -> [() -> Void] in
            let pending = decoderWork.values.map { $0.1 }
            decoderWork.removeAll()
            return pending
        }
        for body in work { body() }
    }
    // 无缝播放使用的PacketQueue
    private var loopPacketQueue: CircularBuffer<Packet>?
    var packetQueue = AsyncPlayerItemTrack<Frame>.makePacketQueue()
    override var packetCount: Int { packetQueue.count }
    override var packetByteCount: Int64 { packetQueue.byteCount }
    override var loadedTime: TimeInterval { packetQueue.bufferedDuration + super.loadedTime }
    private static func makePacketQueue() -> CircularBuffer<Packet> {
        CircularBuffer<Packet>(sizeOf: { Int64($0.size) }, durationOf: { packet in
            let duration = packet.timebase.cmtime(for: packet.duration).seconds
            if duration.isFinite, duration > 0 { return duration }
            let fps = packet.assetTrack.nominalFrameRate
            return fps.isFinite && fps > 0 ? 1 / TimeInterval(fps) : 0
        })
    }
    override var isLoopModel: Bool {
        didSet {
            if isLoopModel {
                loopPacketQueue = Self.makePacketQueue()
                isEndOfFile = true
            } else {
                if let loopPacketQueue {
                    packetQueue.shutdown()
                    packetQueue = loopPacketQueue
                    self.loopPacketQueue = nil
                    if decodeOperation.isFinished {
                        decode()
                    }
                }
            }
        }
    }

    required init(mediaType: AVFoundation.AVMediaType, frameCapacity: UInt8, options: KSOptions) {
        super.init(mediaType: mediaType, frameCapacity: frameCapacity, options: options)
        operationQueue.name = "KSPlayer_" + mediaType.rawValue
        operationQueue.maxConcurrentOperationCount = 1
        operationQueue.qualityOfService = .userInteractive
    }

    override func putPacket(packet: Packet) {
        guard state != .failed, state != .closed else { return }
        packet.decodeGeneration = outputRenderQueue.generation
        if isLoopModel {
            loopPacketQueue?.push(packet)
        } else {
            packetQueue.push(packet)
        }
    }

    override func decode() {
        isEndOfFile = false
        guard operationQueue.operationCount == 0 else { return }
        decodeOperation = BlockOperation { [weak self] in
            guard let self else { return }
            Thread.current.name = self.operationQueue.name
            Thread.current.stackSize = KSOptions.stackSize
            self.decodeThread()
        }
        decodeOperation.queuePriority = .veryHigh
        decodeOperation.qualityOfService = .userInteractive
        operationQueue.addOperation(decodeOperation)
    }

    private func decodeThread() {
        defer {
            decoderMap.values.forEach { $0.shutdown() }
            decoderMap.removeAll()
            decoderWorkLock.withLock { decoderWork.removeAll() }
        }
        guard state != .closed else { return }
        state = .decoding
        isEndOfFile = false
        decoderMap.values.forEach { $0.decode() }
        outerLoop: while !decodeOperation.isCancelled {
            drainDecoderWork()
            switch state {
            case .idle:
                break outerLoop
            case .finished, .closed, .failed:
                break outerLoop
            case .flush:
                let generation = outputRenderQueue.generation
                decoderMap.values.forEach { $0.doFlushCodec() }
                outputRenderQueue.perform(ifGeneration: generation) { self.state = .decoding }
            case .decoding:
                if isEndOfFile, packetQueue.count == 0 {
                    state = .finished
                } else {
                    guard let packet = packetQueue.pop(wait: true), state != .closed,
                          let generation = packet.decodeGeneration,
                          outputRenderQueue.generation == generation else {
                        continue
                    }
                    // A seek can occur while pop sleeps. Its first new packet
                    // may wake that call while the decoder still needs flushing.
                    // Keep that packet (especially a GOP keyframe), flush, and
                    // reject it only if another seek has superseded its timeline.
                    if state == .flush {
                        decoderMap.values.forEach { $0.doFlushCodec() }
                        guard outputRenderQueue.perform(ifGeneration: generation, { self.state = .decoding }) else { continue }
                    }
                    guard state == .decoding, outputRenderQueue.generation == generation else { continue }
                    autoreleasepool {
                        doDecode(packet: packet)
                    }
                }
            }
        }
    }

    override func seek(time: TimeInterval) {
        if decodeOperation.isFinished {
            decode()
        }
        packetQueue.flush()
        super.seek(time: time)
        loopPacketQueue = nil
    }

    override func shutdown() {
        operationQueue.cancelAllOperations()
        super.shutdown()
        packetQueue.shutdown()
    }

    override func shutdownAndWait() {
        // A native completion may be blocked on the bounded picture queue.
        // Release both waits before joining its sole decode worker.
        shutdown()
        operationQueue.waitUntilAllOperationsAreFinished()
        decoderMap.values.forEach { $0.shutdown() }
        decoderMap.removeAll()
        decoderWorkLock.withLock { decoderWork.removeAll() }
    }
}

private final class UnavailableDolbyVisionDecode: DecodeProtocol {
    func decode() {}
    func doFlushCodec() {}
    func shutdown() {}
    func decodeFrame(from packet: Packet, completionHandler: @escaping (Result<MEFrame, Error>) -> Void) {
        completionHandler(.failure(NSError(domain: "KSPlayer.DolbyVision", code: -1,
            userInfo: [NSLocalizedDescriptionKey: "This Dolby Vision stream requires a compatible native decoder."])))
    }
}

public extension Dictionary {
    mutating func value(for key: Key, default defaultValue: @autoclosure () -> Value) -> Value {
        if let value = self[key] {
            return value
        } else {
            let value = defaultValue()
            self[key] = value
            return value
        }
    }
}

protocol DecodeProtocol: AnyObject {
    func decode()
    func decodeFrame(from packet: Packet, completionHandler: @escaping (Result<MEFrame, Error>) -> Void)
    func doFlushCodec()
    func shutdown()
}

extension SyncPlayerItemTrack {
    func makeDecode(assetTrack: FFmpegAssetTrack) -> DecodeProtocol {
        autoreleasepool {
            if mediaType == .subtitle {
                return SubtitleDecode(assetTrack: assetTrack, options: options)
            } else {
                if mediaType == .video, self is AsyncPlayerItemTrack<Frame>,
                   options.asynchronousDecompression, options.hardwareDecode,
                   let session = DecompressionSession(assetTrack: assetTrack, options: options)
                {
                    options.onVideoDecoderChanged?("VideoToolbox")
                    return VideoToolboxDecode(options: options, session: session)
                } else if mediaType == .video, assetTrack.requiresNativeDolbyVision {
                    // P5 and converted P8.1 require their native Dolby/RPU
                    // processing; ordinary software HEVC would lose that work.
                    return UnavailableDolbyVisionDecode()
                } else {
                    if mediaType == .video { options.onVideoDecoderChanged?("FFmpeg") }
                    return FFmpegDecode(assetTrack: assetTrack, options: options)
                }
            }
        }
    }
}
