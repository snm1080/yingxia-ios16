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

    init(engine: KSPlaybackEngine, player: KSMEPlayer) {
        self.engine = engine
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.black.cgColor
        var timebase: CMTimebase?
        if CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &timebase) == noErr, let timebase {
            layer.controlTimebase = timebase
            CMTimebaseSetTime(timebase, time: .zero)
            CMTimebaseSetRate(timebase, rate: 0)
        }
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: player)
        controller = AVPictureInPictureController(contentSource: source)
        controller.canStartPictureInPictureAutomaticallyFromInline = false
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
    }

    func detach(from view: UIView) {
        if inlineHost === view { inlineHost = nil }
        guard sourceView.superview === view else { return }
        sourceView.removeFromSuperview()
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
    }

    /// A bounded warm-up keeps AVKit possible without compositing every inline video frame.
    /// During PiP, every accepted decoded frame uses its own media time and selected cues.
    func submit(_ original: PixelBufferProtocol, time: Double, active: Bool, force: Bool = false) -> Bool {
        lastFrame = original
        lastTime = time
        let now = ProcessInfo.processInfo.systemUptime
        guard force || active || !hasPresented || now - lastPrimed >= 0.5 else { return true }
        guard original.width > 0, original.height > 0, time.isFinite else { return false }
        if layer.status == .failed || layer.requiresFlushToResumeDecoding { layer.flush() }
        guard layer.isReadyForMoreMediaData else { return !active }
        let pixelRatio = original.aspectRatio
        let ratio = pixelRatio.width.isFinite && pixelRatio.height.isFinite && pixelRatio.width > 0 && pixelRatio.height > 0
            ? pixelRatio.width / pixelRatio.height : 1
        let sourceWidth = CGFloat(original.width) * ratio
        let sourceHeight = CGFloat(original.height)
        let scale = min(1, 960 / sourceWidth, 540 / sourceHeight)
        let size = CGSize(width: max(2, Int(sourceWidth * scale) / 2 * 2), height: max(2, Int(sourceHeight * scale) / 2 * 2))
        guard let buffer = makeBuffer(size: size) else { return false }
        let source: CIImage
        if let pixelBuffer = original.cvPixelBuffer {
            source = CIImage(cvPixelBuffer: pixelBuffer, options: [.toneMapHDRtoSDR: true])
        } else if let image = original.cgImage() {
            source = CIImage(cgImage: image, options: [.toneMapHDRtoSDR: true])
        } else { return false }
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
        context.render(rendered, to: buffer, bounds: CGRect(origin: .zero, size: size), colorSpace: colorSpace)
        if format == nil {
            guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                imageBuffer: buffer, formatDescriptionOut: &format) == noErr else { return false }
        }
        guard let format else { return false }
        var timing = CMSampleTimingInfo(duration: .invalid,
            presentationTimeStamp: CMTime(seconds: max(0, time), preferredTimescale: 60_000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
            formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return false }
        if let entries = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary],
           let entry = entries.first { entry[kCMSampleAttachmentKey_DisplayImmediately] = true }
        layer.enqueue(sample)
        guard layer.status != .failed else { return false }
        synchronizeClock(time: time, rate: engine.map { $0.paused || $0.buffering || $0.seeking ? 0 : Double($0.speed) } ?? 0)
        lastPrimed = now
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
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess else { return nil }
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        let limits = [kCVPixelBufferPoolAllocationThresholdKey as String: 4] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, limits, &buffer) == kCVReturnSuccess else { return nil }
        return buffer
    }
}
#endif
