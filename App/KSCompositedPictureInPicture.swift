#if os(iOS)
import AVKit
import CoreImage
import KSPlayer
import TVCore
import UIKit

/// Owns presentation buffers only. Audio, decode, seeks and the original decoded picture
/// remain with the existing KS player while AVKit displays this independent layer.
@MainActor final class KSCompositedPictureInPicture {
    let layer = AVSampleBufferDisplayLayer()
    let controller: AVPictureInPictureController
    private let sourceView = UIView()
    private weak var inlineHost: UIView?
    private weak var parkedFrom: UIView?
    private weak var engine: KSPlaybackEngine?
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let subtitles = PictureInPictureSubtitleRenderer()
    private var pool: CVPixelBufferPool?
    private var poolSize = CGSize.zero
    private var format: CMVideoFormatDescription?
    private var lastFrame: PixelBufferProtocol?
    private var lastTime = 0.0
    private var lastPrimed = -Double.infinity
    private var lastPausedRefresh = -Double.infinity
    private var hasPresented = false
    private var diagnosticEvents = Set<String>()
    private var diagnosticTask: Task<Void, Never>?
    private var diagnosticEpoch = UUID()
    private var diagnosticActive = false
    private var inputCount = 0
    private var enqueueCount = 0
    private var lastInputAt = -Double.infinity
    private var lastEnqueueAt = -Double.infinity
    private var nextRenderProbe: String? = "inline"
    private var renderProbeID: UUID?
    private var applicationObservers: [NSObjectProtocol] = []

    init(engine: KSPlaybackEngine, player: KSMEPlayer) {
        self.engine = engine
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.black.cgColor
        var timebase: CMTimebase?
        let result = CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &timebase)
        if result == noErr, let timebase {
            layer.controlTimebase = timebase
            CMTimebaseSetTime(timebase, time: .zero)
            CMTimebaseSetRate(timebase, rate: 0)
        }
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: player)
        controller = AVPictureInPictureController(contentSource: source)
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        if result != noErr { recordDiagnostic("clock-create-failed", failure: true, detail: "code=\(result)") }
    }

    func attach(to view: UIView) {
        // A final SwiftUI layout from the disappearing cover must not move the
        // source back out of the window after the successful PiP handoff.
        guard parkedFrom !== view else { return }
        inlineHost = view
        parkedFrom = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if sourceView.superview !== view {
            sourceView.removeFromSuperview()
            sourceView.isUserInteractionEnabled = false
            view.insertSubview(sourceView, at: 0)
        }
        sourceView.frame = view.bounds
        if layer.superlayer !== sourceView.layer {
            layer.removeFromSuperlayer()
            sourceView.layer.addSublayer(layer)
        }
        layer.frame = sourceView.bounds
        layer.isHidden = false
        recordDiagnostic("source-attached")
    }

    func detach(from view: UIView) {
        if inlineHost === view { inlineHost = nil }
        guard sourceView.superview === view else { return }
        sourceView.removeFromSuperview()
        recordDiagnostic("source-detached")
    }

    /// The app's full-screen cover is disposable. Keep AVKit's source attached
    /// to its original scene/window until a restored player takes it back.
    func retainSource() {
        guard let inlineHost, let window = inlineHost.window,
              sourceView.superview === inlineHost else { return }
        let frame = inlineHost.convert(inlineHost.bounds, to: window)
        guard frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        parkedFrom = inlineHost
        sourceView.removeFromSuperview()
        window.insertSubview(sourceView, at: 0)
        sourceView.frame = frame
        layer.frame = sourceView.bounds
        recordDiagnostic("source-parked")
    }

    func prepareToStart() {
        diagnosticEpoch = UUID()
        diagnosticEvents.removeAll(keepingCapacity: true)
        nextRenderProbe = "prepare"
        recordDiagnostic("prepare")
        observeApplicationState()
        scheduleDiagnostics()
        refresh(active: false)
    }

    func setActive(_ active: Bool) {
        if !active {
            diagnosticTask?.cancel(); diagnosticTask = nil
            nextRenderProbe = nil
            applicationObservers.forEach(NotificationCenter.default.removeObserver)
            applicationObservers.removeAll()
        }
        if active != diagnosticActive {
            diagnosticActive = active
            recordDiagnostic(active ? "active" : "inactive")
            if active {
                nextRenderProbe = "active"
                if diagnosticTask == nil { scheduleDiagnostics() }
            }
        }
        if active || UIApplication.shared.applicationState == .active { refresh(active: active) }
    }

    /// A bounded warm-up keeps AVKit possible without compositing every inline video frame.
    /// During PiP, every accepted decoded frame uses its own media time and selected cues.
    func submit(_ original: PixelBufferProtocol, time: Double, active: Bool, force: Bool = false) -> Bool {
        let newInput = !force && (lastFrame !== original || lastTime != time)
        lastFrame = original
        lastTime = time
        let now = ProcessInfo.processInfo.systemUptime
        if newInput {
            inputCount += 1; lastInputAt = now
            recordDiagnostic("first-input")
        }
        if !force && !active {
            guard !hasPresented || layer.status == .failed || layer.requiresFlushToResumeDecoding else { return true }
            guard now - lastPrimed >= 0.5 else { return true }
            lastPrimed = now
        }
        guard original.width > 0, original.height > 0, time.isFinite else {
            recordDiagnostic("invalid-input", failure: true); return false
        }
        if layer.status == .failed || layer.requiresFlushToResumeDecoding {
            // Read the error before flush clears AVFoundation's evidence.
            recordDiagnostic("layer-recovery", failure: true)
            layer.flush()
            hasPresented = false
        }
        guard layer.isReadyForMoreMediaData else {
            recordDiagnostic("backpressure", failure: true); return !active
        }
        let pixelRatio = original.aspectRatio
        let ratio = pixelRatio.width.isFinite && pixelRatio.height.isFinite && pixelRatio.width > 0 && pixelRatio.height > 0
            ? pixelRatio.width / pixelRatio.height : 1
        let sourceWidth = CGFloat(original.width) * ratio
        let sourceHeight = CGFloat(original.height)
        let scale = min(1, 960 / sourceWidth, 540 / sourceHeight)
        let size = CGSize(width: max(2, Int(sourceWidth * scale) / 2 * 2), height: max(2, Int(sourceHeight * scale) / 2 * 2))
        guard let buffer = makeBuffer(size: size) else { return false }
        let source: CIImage
        // KS requests legacy three-plane y420 for ordinary 8-bit H.264/HEVC,
        // including VideoToolbox output. Core Image cannot import that layout
        // reliably and can produce transparent black pixels without an error.
        // VideoToolbox's CGImage conversion understands the planar layout;
        // retain the direct Core Image path for packed and bi-planar buffers.
        if let pixelBuffer = original.cvPixelBuffer, CVPixelBufferGetPlaneCount(pixelBuffer) < 3 {
            source = CIImage(cvPixelBuffer: pixelBuffer, options: [.toneMapHDRtoSDR: true])
        } else if let image = original.cgImage() {
            source = CIImage(cgImage: image, options: [.toneMapHDRtoSDR: true])
        } else {
            recordDiagnostic("image-unavailable", failure: true); return false
        }
        var rendered = source.transformed(by: CGAffineTransform(scaleX: size.width / CGFloat(original.width),
                                                                y: size.height / CGFloat(original.height)))
        if let snapshot = engine?.pictureInPictureSubtitles(at: time),
           let overlay = subtitles.image(primary: snapshot.primary, secondary: snapshot.secondary,
                                         style: snapshot.style, size: size) {
            rendered = CIImage(cgImage: overlay).composited(over: rendered)
        }
        // PiP is a bounded SDR presentation. CoreImage converts source color attachments;
        // decoder-owned HDR/Dolby buffers and the inline renderer are never modified.
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        // Keep the existing synchronous render boundary: a ready sample must
        // never expose an output whose Core Image work was only scheduled.
        context.render(rendered, to: buffer, bounds: CGRect(origin: .zero, size: size), colorSpace: colorSpace)
        probeRenderedBuffer(buffer)
        if format == nil {
            let result = CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                imageBuffer: buffer, formatDescriptionOut: &format)
            guard result == noErr else {
                recordDiagnostic("format-failed", failure: true, detail: "code=\(result)"); return false
            }
        }
        guard let format else { return false }
        var timing = CMSampleTimingInfo(duration: .invalid,
            presentationTimeStamp: CMTime(seconds: max(0, time), preferredTimescale: 60_000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let result = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
            formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
        guard result == noErr, let sample else {
            recordDiagnostic("sample-failed", failure: true, detail: "code=\(result)"); return false
        }
        // Use one scheduling mode. AVSampleBufferDisplayLayer does not recommend
        // DisplayImmediately together with a control timebase. Anchor before
        // enqueue, including a paused entry at a nonzero playback position.
        synchronizeClock(time: time, rate: engine.map { $0.paused || $0.buffering || $0.seeking ? 0 : Double($0.speed) } ?? 0)
        if layer.controlTimebase == nil,
           let entries = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary],
           let entry = entries.first {
            // If CoreMedia could not create a clock, immediate presentation is
            // the standalone fallback; media PTS must not use the host epoch.
            entry[kCMSampleAttachmentKey_DisplayImmediately] = true
            recordDiagnostic("clock-unavailable", failure: true)
        }
        layer.enqueue(sample)
        guard layer.status != .failed else {
            recordDiagnostic("enqueue-failed", failure: true); return false
        }
        enqueueCount += 1; lastEnqueueAt = now
        recordDiagnostic("first-enqueue")
        hasPresented = true
        return true
    }

    func refresh(active: Bool) {
        guard let lastFrame else { return }
        _ = submit(lastFrame, time: lastTime, active: active, force: true)
    }

    func refreshPaused() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPausedRefresh >= 0.2 else { return }
        lastPausedRefresh = now
        refresh(active: true)
    }

    func invalidatePicture(at time: Double) {
        lastFrame = nil; hasPresented = false; lastPrimed = -Double.infinity
        lastTime = time
        layer.flushAndRemoveImage()
        subtitles.reset()
        synchronizeClock(time: time, rate: 0)
    }

    func synchronizeClock(time: Double, rate: Double) {
        guard time.isFinite, rate.isFinite, let timebase = layer.controlTimebase else { return }
        CMTimebaseSetTime(timebase, time: CMTime(seconds: max(0, time), preferredTimescale: 60_000))
        CMTimebaseSetRate(timebase, rate: min(8, max(0, rate)))
    }

    func reset() {
        diagnosticTask?.cancel(); diagnosticTask = nil
        diagnosticEpoch = UUID()
        applicationObservers.forEach(NotificationCenter.default.removeObserver)
        applicationObservers.removeAll()
        controller.stopPictureInPicture()
        layer.flushAndRemoveImage()
        layer.removeFromSuperlayer()
        sourceView.removeFromSuperview(); inlineHost = nil; parkedFrom = nil
        pool = nil; format = nil; poolSize = .zero
        lastFrame = nil; hasPresented = false
        subtitles.reset()
    }

    private func makeBuffer(size: CGSize) -> CVPixelBuffer? {
        if pool == nil || poolSize != size {
            pool = nil; format = nil; poolSize = size
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferCGImageCompatibilityKey as String: true, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
            ]
            let result = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
            guard result == kCVReturnSuccess else {
                recordDiagnostic("pool-failed", failure: true, detail: "code=\(result)"); return nil
            }
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        let limits = [kCVPixelBufferPoolAllocationThresholdKey as String: 4] as CFDictionary
        let result = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, limits, &buffer)
        guard result == kCVReturnSuccess else {
            recordDiagnostic("buffer-unavailable", failure: true, detail: "code=\(result)"); return nil
        }
        return buffer
    }

    private func probeRenderedBuffer(_ buffer: CVPixelBuffer) {
        guard let stage = nextRenderProbe, renderProbeID == nil else { return }
        nextRenderProbe = nil
        let identity = UUID(), epoch = diagnosticEpoch
        renderProbeID = identity
        let probe = RenderProbe(buffer: buffer)
        // Inspect only an already rendered, retained output. Numeric sampling
        // stays off the playback/UI actor and owns at most one buffer at a time.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = probe.inspect()
            Task { @MainActor [weak self] in
                guard let self, self.renderProbeID == identity else { return }
                self.renderProbeID = nil
                guard self.diagnosticEpoch == epoch else { return }
                self.recordDiagnostic("render-\(stage)", failure: result.failed, detail: result.detail)
            }
        }
    }

    private func scheduleDiagnostics() {
        diagnosticTask?.cancel()
        let epoch = diagnosticEpoch
        diagnosticTask = Task { @MainActor [weak self] in
            var previous = 0.0
            for elapsed in [0.5, 2.0, 5.0, 15.0] {
                do { try await Task.sleep(for: .seconds(elapsed - previous)) } catch { return }
                guard let self, self.diagnosticEpoch == epoch else { return }
                let stage = "after-\(elapsed)s"
                self.recordDiagnostic(stage)
                self.nextRenderProbe = stage
                previous = elapsed
            }
            self?.diagnosticTask = nil
        }
    }

    private func observeApplicationState() {
        guard applicationObservers.isEmpty else { return }
        for (notification, event) in [(UIApplication.didEnterBackgroundNotification, "background"),
                                      (UIApplication.willEnterForegroundNotification, "foreground")] {
            let observer = NotificationCenter.default.addObserver(forName: notification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.diagnosticActive, !self.diagnosticEvents.contains(event) else { return }
                    self.recordDiagnostic(event)
                    self.nextRenderProbe = event
                }
            }
            applicationObservers.append(observer)
        }
    }

    private func recordDiagnostic(_ event: String, failure: Bool = false, detail: String = "") {
        // A stalled decoder/layer may retry at 60 Hz. Each stage is logged once,
        // with a hard cap per start attempt, rather than once per frame.
        guard diagnosticEvents.count < 32, diagnosticEvents.insert(event).inserted else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let frame = lastFrame
        let format = frame?.cvPixelBuffer.map { CVPixelBufferGetPixelFormatType($0) } ?? 0
        let timebase = layer.controlTimebase
        let baseTime = timebase.map { CMTimebaseGetTime($0).seconds } ?? .nan
        let rate = timebase.map { CMTimebaseGetRate($0) } ?? 0
        let error = layer.error.map { PlaybackFailureDiagnostics.codes($0) } ?? "none"
        let inputAge = lastInputAt.isFinite ? max(0, now - lastInputAt) : -1
        let outputAge = lastEnqueueAt.isFinite ? max(0, now - lastEnqueueAt) : -1
        var displayed = "unavailable"
        if #available(iOS 17.4, *) { displayed = String(layer.isReadyForDisplay) }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        Diagnostics.shared.record(failure ? .warning : .info, "player.pip",
            "event=\(event) attempt=\(diagnosticEpoch.uuidString.prefix(8)) os=\(os.majorVersion).\(os.minorVersion).\(os.patchVersion) device=\(UIDevice.current.model) app=\(UIApplication.shared.applicationState.rawValue) possible=\(controller.isPictureInPicturePossible) active=\(controller.isPictureInPictureActive) suspended=\(controller.isPictureInPictureSuspended) mounted=\(sourceView.window != nil) bounds=\(layer.bounds) input=\(frame?.width ?? 0)x\(frame?.height ?? 0)/\(format)/\(frame?.bitDepth ?? 0)bit output=\(poolSize) frames=\(inputCount)/\(enqueueCount) age=\(inputAge)/\(outputAge) pts=\(lastTime) clock=\(baseTime)/\(rate) state=\(layer.status.rawValue) ready=\(layer.isReadyForMoreMediaData) displayed=\(displayed) flush=\(layer.requiresFlushToResumeDecoding) error=\(error) \(detail)")
    }

    private final class RenderProbe: @unchecked Sendable {
        let buffer: CVPixelBuffer
        init(buffer: CVPixelBuffer) { self.buffer = buffer }

        func inspect() -> (failed: Bool, detail: String) {
            let result = CVPixelBufferLockBaseAddress(buffer, .readOnly)
            guard result == kCVReturnSuccess else { return (true, "pixel-lock=\(result)") }
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return (true, "pixels=unavailable") }
            let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
            let stride = CVPixelBufferGetBytesPerRow(buffer), bytes = base.assumingMemoryBound(to: UInt8.self)
            var low = 255, high = 0, alpha = 255
            for row in 1...4 { for column in 1...4 {
                let index = min(height - 1, height * row / 5) * stride + min(width - 1, width * column / 5) * 4
                let light = (Int(bytes[index]) + Int(bytes[index + 1]) + Int(bytes[index + 2])) / 3
                low = min(low, light); high = max(high, light); alpha = min(alpha, Int(bytes[index + 3]))
            } }
            // Numeric evidence only: no screenshot, subtitle text or media URL.
            return (false, "pixels16=\(low)...\(high) alphaMin=\(alpha)")
        }
    }
}
#endif
