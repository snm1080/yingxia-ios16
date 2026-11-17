#if os(iOS)
import AVKit
import CoreImage
import CoreText
import UIKit
import TVCore

/// Feeds system PiP from the same AVPlayer clock, with the native subtitle/danmaku renderer.
/// AVPlayer owns the only audio stream; this presenter never starts another media player.
@MainActor final class CompositedPictureInPicture: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate {
    let layer = AVSampleBufferDisplayLayer()
    private let session: PlaybackSession
    private weak var item: AVPlayerItem?
    private var output: AVPlayerItemVideoOutput?
    private var timer: Timer?
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let engine = DanmakuEngine()
    private var revision = ""
    private var lastFrame: CVPixelBuffer?
    private var timestamp: Double = 0
    private var timebase: CMTimebase?
    nonisolated private let state = State()
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var paused = false
        var duration = 0.0
        func update(paused: Bool, duration: Double) { lock.withLock { self.paused = paused; self.duration = duration } }
    }

    init(session: PlaybackSession) {
        self.session = session
        super.init()
        layer.videoGravity = .resizeAspect
        var base: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &base)
        timebase = base
        if let base { CMTimebaseSetTime(base, time: .zero); CMTimebaseSetRate(base, rate: 1); layer.controlTimebase = base }
    }
    func attach(to view: UIView) {
        if layer.superlayer !== view.layer { layer.removeFromSuperlayer(); view.layer.addSublayer(layer) }
        // Kept as a visible source layer behind the inline video; PiP uses the buffer's aspect ratio.
        layer.frame = view.bounds
        layer.isHidden = false
    }
    func start() {
        guard timer == nil else { return }
        attachOutput()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.draw() }
        }
        draw()
    }
    func stop() {
        timer?.invalidate(); timer = nil
        if let item, let output { item.remove(output) }
        item = nil; output = nil; lastFrame = nil
        layer.flushAndRemoveImage()
    }
    private func attachOutput() {
        guard item !== session.player.currentItem else { return }
        if let item, let output { item.remove(output) }
        item = session.player.currentItem
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true])
        item?.add(output); self.output = output; lastFrame = nil
    }
    private func draw() {
        attachOutput()
        guard let output, let item else { return }
        let currentTime = session.player.currentTime()
        state.update(paused: session.player.rate == 0, duration: item.duration.seconds.isFinite ? item.duration.seconds : 0)
        if output.hasNewPixelBuffer(forItemTime: currentTime), let buffer = output.copyPixelBuffer(forItemTime: currentTime, itemTimeForDisplay: nil) { lastFrame = buffer }
        guard let original = lastFrame else { return }
        let width = CVPixelBufferGetWidth(original), height = CVPixelBufferGetHeight(original)
        guard width > 0, height > 0 else { return }
        let scale = min(1, 960.0 / Double(width), 540.0 / Double(height))
        let size = CGSize(width: max(2, Int(Double(width) * scale) / 2 * 2), height: max(2, Int(Double(height) * scale) / 2 * 2))
        var made: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true,
             kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &made)
        guard let buffer = made else { return }
        let image = CIImage(cvPixelBuffer: original).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        context.render(image, to: buffer, bounds: CGRect(origin: .zero, size: size), colorSpace: CGColorSpaceCreateDeviceRGB())
        CVPixelBufferLockBaseAddress(buffer, [])
        if let address = CVPixelBufferGetBaseAddress(buffer), let drawing = CGContext(data: address, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            let time = currentTime.seconds
            let next = session.danmakuRevision + ":" + String(session.danmaku.count)
            if revision != next { revision = next; engine.load(session.danmaku) }
            if session.catalogDanmaku.enabled, time.isFinite {
                let area = DanmakuArea(rawValue: UserDefaults.standard.integer(forKey: DanmakuArea.key)) ?? .standard
                for sprite in engine.frame(time: time - UserDefaults.standard.double(forKey: "danmakuDelay"), size: size, scale: 1, area: area, textScale: DanmakuStyle.textScale(session.catalogDanmaku.fontSize)) {
                    drawing.saveGState()
                    drawing.setAlpha(session.danmakuOpacity * sprite.opacity)
                    var rect = sprite.frame; rect.origin.y = size.height - rect.maxY
                    if sprite.rotation != 0 {
                        drawing.translateBy(x: rect.midX, y: rect.midY)
                        drawing.rotate(by: -sprite.rotation * .pi / 180)
                        drawing.translateBy(x: -rect.midX, y: -rect.midY)
                    }
                    drawing.draw(sprite.image, in: rect)
                    drawing.restoreGState()
                }
            }
            let lines = session.subtitles.lines
            if !lines.isEmpty {
                drawing.setAlpha(1)
                let font = CTFontCreateUIFontForLanguage(.system, max(14, size.height * 0.047), nil)!
                let attributes: [NSAttributedString.Key: Any] = [.init(kCTFontAttributeName as String): font, .init(kCTForegroundColorAttributeName as String): UIColor.white.cgColor,
                    .init(kCTStrokeColorAttributeName as String): UIColor.black.cgColor, .init(kCTStrokeWidthAttributeName as String): -3]
                for (index, text) in lines.reversed().enumerated() {
                    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
                    let textWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
                    drawing.textPosition = CGPoint(x: max(8, (size.width - textWidth) / 2), y: max(12, size.height * 0.09) + CGFloat(index) * max(18, size.height * 0.06))
                    CTLineDraw(line, drawing)
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format) == noErr, let format else { return }
        let now = timebase.map { CMTimebaseGetTime($0).seconds } ?? timestamp
        timestamp = max(timestamp + 1.0 / 25, now)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 25), presentationTimeStamp: CMTime(seconds: timestamp, preferredTimescale: 600), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        if CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample {
            if layer.status == .failed { layer.flush() }
            if layer.isReadyForMoreMediaData { layer.enqueue(sample) }
        }
        _ = item
    }
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
        Task { @MainActor in if playing { self.session.player.play() } else { self.session.player.pause() } }
    }
    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        let duration = state.lock.withLock { state.duration }
        return duration > 0 ? CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600)) : CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }
    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool { state.lock.withLock { state.paused } }
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion: @escaping () -> Void) {
        let reply = Completion(completion)
        let seconds = skipInterval.seconds
        Task { @MainActor in self.session.skip(seconds); reply.call() }
    }
    private final class Completion: @unchecked Sendable {
        private let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        func call() { action() }
    }
}
#endif
