//
//  MetalPlayView.swift
//  KSPlayer
//
//  Created by kintan on 2018/3/11.
//

import AVFoundation
import Combine
import CoreMedia
#if canImport(MetalKit)
import MetalKit
#endif
public protocol DisplayLayerDelegate: NSObjectProtocol {
    func change(displayLayer: AVSampleBufferDisplayLayer)
}

public protocol VideoOutput: FrameOutput {
    var displayLayerDelegate: DisplayLayerDelegate? { get set }
    var options: KSOptions { get set }
    var displayLayer: AVSampleBufferDisplayLayer { get }
    var pixelBuffer: PixelBufferProtocol? { get }
    var playbackRate: Float { get set }
    init(options: KSOptions)
    func invalidate()
    func discardPendingFrame()
    @discardableResult func readNextFrame() -> Bool
}

public extension VideoOutput {
    var playbackRate: Float {
        get { 1 }
        set {}
    }
    func discardPendingFrame() {}
}

public final class MetalPlayView: UIView, VideoOutput {
    /// A separate PiP presenter consumes the same decoded frame. When it owns presentation,
    /// accepting that frame must not wait for an offscreen inline Metal drawable.
    public var pictureInPictureFrame: ((PixelBufferProtocol, CMTime) -> Bool)?
    public var pictureInPictureActive = false {
        didSet { if oldValue != pictureInPictureActive { updatePictureInPictureTimer() } }
    }
    private var pictureInPictureTimer: DispatchSourceTimer?
    private var outputPlaying = false
    public var displayLayer: AVSampleBufferDisplayLayer {
        displayView.displayLayer
    }

    private var isDovi: Bool = false
    private var formatDescription: CMFormatDescription? {
        didSet {
            options.updateVideo(refreshRate: fps, isDovi: isDovi, formatDescription: formatDescription)
        }
    }

    private var fps = Float(60) {
        didSet {
            if fps != oldValue {
                updateDisplayCadence()
                options.updateVideo(refreshRate: fps, isDovi: isDovi, formatDescription: formatDescription)
            }
        }
    }

    public var playbackRate: Float = 1 {
        didSet { if playbackRate != oldValue { updateDisplayCadence() } }
    }
    private var displayCadence: VideoDisplayCadence?
    private var pendingFrame: VideoVTBFrame?
    private var pendingForcedPicture = false
    private var forcedPictureAccepted = false
    private var forcedPictureRetry: DispatchWorkItem?
    private var forcedPictureRetryDeadline: CFTimeInterval?
    private var forcedPictureRetryEpoch: UInt64 = 0
    private var outputInvalidated = false
    private var outputUsesDisplayLayer: Bool?
    private var outputDisplay: DisplayEnum?

    public private(set) var pixelBuffer: PixelBufferProtocol?
    /// 用displayLink会导致锁屏无法draw，
    /// 用DispatchSourceTimer的话，在播放4k视频的时候repeat的时间会变长,
    /// 用MTKView的draw(in:)也是不行，会卡顿
    private var displayLink: CADisplayLink!
//    private let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
    public var options: KSOptions
    public weak var renderSource: OutputRenderSourceDelegate? {
        didSet { discardPendingFrame() }
    }
    // AVSampleBufferAudioRenderer AVSampleBufferRenderSynchronizer AVSampleBufferDisplayLayer
    var displayView = AVSampleBufferDisplayView() {
        didSet {
            displayLayerDelegate?.change(displayLayer: displayView.displayLayer)
        }
    }

    private let metalView = MetalView()
    public weak var displayLayerDelegate: DisplayLayerDelegate?
    public init(options: KSOptions) {
        self.options = options
        super.init(frame: .zero)
        addSubview(displayView)
        addSubview(metalView)
        metalView.isHidden = true
        metalView.onDrawableReady = { [weak self] in self?.retryPendingPicture() }
        metalView.onClearRequested = { [weak self] in
            self?.cancelForcedPictureRetry()
            self?.pendingFrame = nil; self?.pendingForcedPicture = false; self?.forcedPictureAccepted = false
        }
        //        displayLink = CADisplayLink(block: renderFrame)
        displayLink = CADisplayLink(target: self, selector: #selector(renderFrame))
        // 一定要用common。不然在视频上面操作view的话，那就会卡顿了。
        displayLink.add(to: .main, forMode: .common)
        pause()
    }

    public func play() {
        outputPlaying = true
        cancelForcedPictureRetry()
        metalView.invalidateDrawable()
        forcedPictureAccepted = false
        updateDisplayCadence()
        displayLink.isPaused = false
        updatePictureInPictureTimer()
    }

    public func pause() {
        outputPlaying = false
        updatePictureInPictureTimer()
        cancelForcedPictureRetry()
        displayLink.isPaused = true
        pendingForcedPicture = false
        metalView.invalidateDrawable()
        forcedPictureAccepted = false
    }

    override public func didMoveToWindow() {
        super.didMoveToWindow()
        metalView.invalidateDrawable()
        if window == nil { pendingForcedPicture = false; cancelForcedPictureRetry() }
        updateDisplayCadence()
    }

    @available(*, unavailable)
    required init(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public func didAddSubview(_ subview: UIView) {
        super.didAddSubview(subview)
        subview.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            subview.leftAnchor.constraint(equalTo: leftAnchor),
            subview.topAnchor.constraint(equalTo: topAnchor),
            subview.bottomAnchor.constraint(equalTo: bottomAnchor),
            subview.rightAnchor.constraint(equalTo: rightAnchor),
        ])
    }

    override public var contentMode: UIViewContentMode {
        didSet {
            metalView.contentMode = contentMode
            switch contentMode {
            case .scaleToFill:
                displayView.displayLayer.videoGravity = .resize
            case .scaleAspectFit, .center:
                displayView.displayLayer.videoGravity = .resizeAspect
            case .scaleAspectFill:
                displayView.displayLayer.videoGravity = .resizeAspectFill
            default:
                break
            }
        }
    }

    #if canImport(UIKit)
    override public func touchesMoved(_ touches: Set<UITouch>, with: UIEvent?) {
        if options.display == .plane {
            super.touchesMoved(touches, with: with)
        } else {
            options.display.touchesMoved(touch: touches.first!)
        }
    }
    #else
    override public func touchesMoved(with event: NSEvent) {
        if options.display == .plane {
            super.touchesMoved(with: event)
        } else {
            options.display.touchesMoved(touch: event.allTouches().first!)
        }
    }
    #endif

    public func flush() {
        discardPendingFrame()
        pixelBuffer = nil
        if displayView.isHidden {
            metalView.clear()
        } else {
            displayView.displayLayer.flushAndRemoveImage()
        }
    }

    public func invalidate() {
        outputInvalidated = true
        outputPlaying = false
        updatePictureInPictureTimer()
        discardPendingFrame()
        displayLink.invalidate()
    }

    public func discardPendingFrame() {
        cancelForcedPictureRetry()
        pendingFrame = nil; pendingForcedPicture = false; forcedPictureAccepted = false
        metalView.invalidateDrawable()
    }

    @discardableResult public func readNextFrame() -> Bool {
        if forcedPictureAccepted { forcedPictureAccepted = false; return true }
        return draw(force: true)
    }

//    deinit {
//        print()
//    }
}

extension MetalPlayView {
    private func updatePictureInPictureTimer() {
        let enabled = pictureInPictureActive && outputPlaying && !outputInvalidated
        guard enabled else {
            pictureInPictureTimer?.setEventHandler {}
            pictureInPictureTimer?.cancel(); pictureInPictureTimer = nil
            return
        }
        guard pictureInPictureTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            guard let self, self.pictureInPictureActive, self.outputPlaying, !self.outputInvalidated else { return }
            self.draw(force: false)
        }
        pictureInPictureTimer = timer
        timer.resume()
    }

    private func updateDisplayCadence() {
        guard KSOptions.preferredFrame, displayLink != nil else { return }
        #if canImport(UIKit)
        let screenMaximum = window?.screen.maximumFramesPerSecond ?? 60
        #else
        let screenMaximum = 60
        #endif
        let cadence = VideoDisplayCadence(sourceFPS: fps, playbackRate: playbackRate, screenMaximum: screenMaximum)
        guard cadence != displayCadence else { return }
        displayCadence = cadence
        let refreshRate = Float(cadence.framesPerSecond)
        if #available(iOS 15.0, tvOS 15.0, macOS 14.0, *) {
            displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: refreshRate, maximum: refreshRate, __preferred: refreshRate)
        } else {
            displayLink.preferredFramesPerSecond = cadence.framesPerSecond
        }
    }

    @objc private func renderFrame() {
        guard pictureInPictureTimer == nil else { return }
        draw(force: false)
    }

    private func retryPendingPicture() {
        guard !outputInvalidated, pendingFrame != nil,
              !displayLink.isPaused || pendingForcedPicture else { return }
        let forced = pendingForcedPicture
        if draw(force: forced), forced { forcedPictureAccepted = true }
    }

    private func cancelForcedPictureRetry() {
        forcedPictureRetryEpoch &+= 1
        forcedPictureRetry?.cancel(); forcedPictureRetry = nil
        forcedPictureRetryDeadline = nil
    }

    private func scheduleForcedPictureRetry() {
        guard !outputInvalidated, displayLink.isPaused, pendingForcedPicture,
              let picture = pendingFrame, forcedPictureRetry == nil,
              let deadline = forcedPictureRetryDeadline, CACurrentMediaTime() < deadline else { return }
        let epoch = forcedPictureRetryEpoch
        let retry = DispatchWorkItem { [weak self, weak picture] in
            guard let self, let picture, self.forcedPictureRetryEpoch == epoch,
                  self.pendingFrame === picture else { return }
            self.forcedPictureRetry = nil
            guard self.displayLink.isPaused, self.pendingForcedPicture,
                  !self.outputInvalidated, CACurrentMediaTime() < deadline else { return }
            self.retryPendingPicture()
        }
        forcedPictureRetry = retry
        // A paused seek has no display tick after a nil drawable or layer
        // backpressure. Retry its same picture for at most one second; native
        // drawable-ready events can still deliver it after that deadline.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: retry)
    }

    @discardableResult private func draw(force: Bool) -> Bool {
        autoreleasepool {
            guard !outputInvalidated else { return false }
            defer { scheduleForcedPictureRetry() }
            let usesDisplayLayer = options.isUseDisplayLayer()
            if outputUsesDisplayLayer != usesDisplayLayer || outputDisplay != options.display {
                metalView.invalidateDrawable()
                outputUsesDisplayLayer = usesDisplayLayer; outputDisplay = options.display
            }
            guard let frame = pendingFrame ?? renderSource?.getVideoOutputRender(force: force) else {
                return false
            }
            if force && !pendingForcedPicture {
                cancelForcedPictureRetry()
                forcedPictureRetryDeadline = CACurrentMediaTime() + 1
            }
            pendingFrame = frame
            pendingForcedPicture = pendingForcedPicture || force
            guard let pixelBuffer = frame.corePixelBuffer else {
                pendingFrame = nil
                pendingForcedPicture = false
                cancelForcedPictureRetry()
                return false
            }
            isDovi = frame.isDovi
            fps = frame.fps
            let cmtime = frame.cmtime
            let par = pixelBuffer.size
            let sar = pixelBuffer.aspectRatio
            if pictureInPictureActive, let pictureInPictureFrame {
                guard pictureInPictureFrame(pixelBuffer, cmtime) else { return false }
            } else if let pixelBuffer = pixelBuffer.cvPixelBuffer, usesDisplayLayer, frame.dolbyVision == nil {
                if let dar = options.customizeDar(sar: sar, par: par) {
                    pixelBuffer.aspectRatio = CGSize(width: dar.width, height: dar.height * par.width / par.height)
                }
                checkFormatDescription(pixelBuffer: pixelBuffer)
                guard set(pixelBuffer: pixelBuffer, time: cmtime) else { return false }
                if displayView.isHidden {
                    displayView.isHidden = false
                    metalView.isHidden = true
                    metalView.clear()
                }
            } else {
                let size: CGSize
                if options.display == .plane {
                    if let dar = options.customizeDar(sar: sar, par: par) {
                        size = CGSize(width: par.width, height: par.width * dar.height / dar.width)
                    } else {
                        size = CGSize(width: par.width, height: par.height * sar.height / sar.width)
                    }
                } else {
                    size = KSOptions.sceneSize
                }
                checkFormatDescription(pixelBuffer: pixelBuffer)
                #if !os(tvOS)
                if #available(iOS 16, *) {
                    // Dolby frames are tone-mapped to SDR by the colour
                    // stage; never attach the HDR10 EDR metadata for them.
                    metalView.metalLayer.edrMetadata = frame.dolbyVision == nil ? frame.edrMetadata : nil
                }
                #endif
                guard metalView.draw(pixelBuffer: pixelBuffer, display: options.display, size: size, dolbyVision: frame.dolbyVision) else { return false }
                if !displayView.isHidden {
                    displayView.isHidden = true
                    metalView.isHidden = false
                    displayView.displayLayer.flushAndRemoveImage()
                }
            }
            pendingFrame = nil
            pendingForcedPicture = false
            cancelForcedPictureRetry()
            self.pixelBuffer = pixelBuffer
            renderSource?.setVideo(time: cmtime, position: frame.position)
            if !pictureInPictureActive { _ = pictureInPictureFrame?(pixelBuffer, cmtime) }
            return true
        }
    }

    private func checkFormatDescription(pixelBuffer: PixelBufferProtocol) {
        if formatDescription == nil || !pixelBuffer.matche(formatDescription: formatDescription!) {
            if formatDescription != nil {
                metalView.invalidateDrawable()
                displayView.removeFromSuperview()
                displayView = AVSampleBufferDisplayView()
                displayView.frame = frame
                addSubview(displayView)
            }
            formatDescription = pixelBuffer.formatDescription
        }
    }

    private func set(pixelBuffer: CVPixelBuffer, time: CMTime) -> Bool {
        guard let formatDescription else { return false }
        return displayView.enqueue(imageBuffer: pixelBuffer, formatDescription: formatDescription, time: time)
    }
}

/// CAMetalLayer permits nextDrawable on a rendering thread. All configuration
/// remains on the main actor; the worker only calls that acquisition API.
private final class MetalLayerDrawableProvider: @unchecked Sendable {
    let layer: CAMetalLayer
    init(_ layer: CAMetalLayer) { self.layer = layer }
    func acquire() -> CAMetalDrawable? { layer.nextDrawable() }
}

class MetalView: UIView {
    private let render = MetalRender()
    private let drawableAcquisition = MetalDrawableAcquisition<CAMetalDrawable>()
    private var drawableDisplay: DisplayEnum?
    private var pendingClear = false
    private var clearRetry: DispatchWorkItem?
    private var clearEpoch: UInt64 = 0
    var onDrawableReady: (() -> Void)?
    var onClearRequested: (() -> Void)?
    #if canImport(UIKit)
    override public class var layerClass: AnyClass { CAMetalLayer.self }
    #endif
    var metalLayer: CAMetalLayer {
        // swiftlint:disable force_cast
        layer as! CAMetalLayer
        // swiftlint:enable force_cast
    }

    init() {
        super.init(frame: .zero)
        #if !canImport(UIKit)
        layer = CAMetalLayer()
        #endif
        metalLayer.device = MetalRender.device
        metalLayer.framebufferOnly = true
//        metalLayer.displaySyncEnabled = false
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func clear() {
        onClearRequested?()
        invalidateDrawable()
        pendingClear = true
        submitPendingClear()
    }

    func invalidateDrawable() {
        clearEpoch &+= 1
        clearRetry?.cancel(); clearRetry = nil
        pendingClear = false
        drawableAcquisition.invalidate()
    }

    private func drawableReady() {
        if pendingClear { submitPendingClear() }
        else { onDrawableReady?() }
    }

    private func nextReadyDrawable() -> CAMetalDrawable? {
        let provider = MetalLayerDrawableProvider(metalLayer)
        return drawableAcquisition.takeOrRequest(acquire: { provider.acquire() },
                                                 completion: { [weak self] in self?.drawableReady() })
    }

    private func submitPendingClear() {
        guard pendingClear else { return }
        guard render.hasCapacity else { scheduleClearRetry(); return }
        if let drawable = nextReadyDrawable() {
            clearRetry?.cancel(); clearRetry = nil
            if render.clear(drawable: drawable) {
                pendingClear = false
            } else {
                scheduleClearRetry()
            }
        } else {
            scheduleClearRetry()
        }
    }

    private func scheduleClearRetry() {
        guard pendingClear, clearRetry == nil else { return }
        let epoch = clearEpoch
        let retry = DispatchWorkItem { [weak self] in
            guard let self, self.clearEpoch == epoch, self.pendingClear else { return }
            self.clearRetry = nil
            self.submitPendingClear()
        }
        clearRetry = retry
        // Paused/flush/stop has no display-link tick. One cancellable 50 ms
        // retry waits for GPU/drawable recovery without spinning or queuing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: retry)
    }

    func draw(pixelBuffer: PixelBufferProtocol, display: DisplayEnum, size: CGSize, dolbyVision: DolbyVisionFrameMetadata? = nil) -> Bool {
        if pendingClear { invalidateDrawable() }
        guard render.hasCapacity else { return false }
        if drawableDisplay != display { invalidateDrawable(); drawableDisplay = display }
        if metalLayer.drawableSize != size { invalidateDrawable(); metalLayer.drawableSize = size }
        let pixelFormat = KSOptions.colorPixelFormat(bitDepth: pixelBuffer.bitDepth)
        if metalLayer.pixelFormat != pixelFormat { invalidateDrawable(); metalLayer.pixelFormat = pixelFormat }
        let colorspace = pixelBuffer.colorspace
        if colorspace != nil, metalLayer.colorspace != colorspace {
            invalidateDrawable()
            metalLayer.colorspace = colorspace
            KSLog("[video] CAMetalLayer colorspace \(String(describing: colorspace))")
            #if !os(tvOS)
            if #available(iOS 16.0, *) {
                if let name = colorspace?.name, name != CGColorSpace.sRGB {
                    #if os(macOS)
                    metalLayer.wantsExtendedDynamicRangeContent = window?.screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0 > 1.0
                    #else
                    metalLayer.wantsExtendedDynamicRangeContent = true
                    #endif
                } else {
                    metalLayer.wantsExtendedDynamicRangeContent = false
                }
                KSLog("[video] CAMetalLayer wantsExtendedDynamicRangeContent \(metalLayer.wantsExtendedDynamicRangeContent)")
            }
            #endif
        }
        if let dolbyVision {
            // Build 42: the Dolby colour stage outputs display-referred
            // sRGB. The layer must not reinterpret the frame's BT.2020/PQ
            // attachments, and EDR stays off so the shader's tone map is
            // the only mapping applied.
            let srgb = CGColorSpace(name: CGColorSpace.sRGB)
            if metalLayer.colorspace != srgb {
                invalidateDrawable()
                metalLayer.colorspace = srgb
            }
            #if !os(tvOS)
            if #available(iOS 16.0, *) {
                metalLayer.wantsExtendedDynamicRangeContent = false
            }
            #endif
            guard let drawable = nextReadyDrawable() else { return false }
            // Same normalization YUVColorConversion performs: a texture
            // sample is the stored code over (2^texelDepth - 1), shifted
            // back to the top of its texel; the shader wants the sample
            // code over 2^bl_bit_depth.
            let depth = Int(pixelBuffer.bitDepth)
            let storedShift = depth > 8 ? max(0, 16 - depth - Int(pixelBuffer.leftShift)) : 0
            let texelDenominator: Float = depth > 8 ? 65535 : 255
            let inputScale = texelDenominator / Float(1 << storedShift) / Float(1 << dolbyVision.blBitDepth)
            let uniform = dolbyVision.uniformData(inputScale: inputScale)
            return render.draw(pixelBuffer: pixelBuffer, display: display, drawable: drawable, dolbyVision: uniform)
        }
        guard let drawable = nextReadyDrawable() else { return false }
        return render.draw(pixelBuffer: pixelBuffer, display: display, drawable: drawable)
    }
}

class AVSampleBufferDisplayView: UIView {
    #if canImport(UIKit)
    override public class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    #endif
    var displayLayer: AVSampleBufferDisplayLayer {
        // swiftlint:disable force_cast
        layer as! AVSampleBufferDisplayLayer
        // swiftlint:enable force_cast
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        #if !canImport(UIKit)
        layer = AVSampleBufferDisplayLayer()
        #endif
        var controlTimebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &controlTimebase)
        if let controlTimebase {
            displayLayer.controlTimebase = controlTimebase
            CMTimebaseSetTime(controlTimebase, time: .zero)
            CMTimebaseSetRate(controlTimebase, rate: 1.0)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func enqueue(imageBuffer: CVPixelBuffer, formatDescription: CMVideoFormatDescription, time: CMTime) -> Bool {
        // Recover the layer before enqueueing: a post-enqueue flush would
        // discard the very picture whose PTS was just published to overlays.
        if #available(macOS 11.0, iOS 14, tvOS 14, *), displayLayer.requiresFlushToResumeDecoding {
            displayLayer.flush()
        }
        if displayLayer.status == .failed { displayLayer.flush() }
        guard displayLayer.isReadyForMoreMediaData else { return false }
        let timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        //        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: imageBuffer, formatDescription: formatDescription, sampleTiming: [timing], sampleBufferOut: &sampleBuffer)
        if let sampleBuffer {
            if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) as? [NSMutableDictionary], let dic = attachmentsArray.first {
                dic[kCMSampleAttachmentKey_DisplayImmediately] = true
            }
            displayLayer.enqueue(sampleBuffer)
            return displayLayer.status != .failed
        }
        return false
    }
}

#if os(macOS)
import CoreVideo

class CADisplayLink {
    private let displayLink: CVDisplayLink
    private var runloop: RunLoop?
    private var mode = RunLoop.Mode.default
    public var preferredFramesPerSecond = 60
    @available(macOS 12.0, *)
    public var preferredFrameRateRange: CAFrameRateRange {
        get {
            CAFrameRateRange()
        }
        set {}
    }

    public var timestamp: TimeInterval {
        var timeStamp = CVTimeStamp()
        if CVDisplayLinkGetCurrentTime(displayLink, &timeStamp) == kCVReturnSuccess, (timeStamp.flags & CVTimeStampFlags.hostTimeValid.rawValue) != 0 {
            return TimeInterval(timeStamp.hostTime / NSEC_PER_SEC)
        }
        return 0
    }

    public var duration: TimeInterval {
        CVDisplayLinkGetActualOutputVideoRefreshPeriod(displayLink)
    }

    public var targetTimestamp: TimeInterval {
        duration + timestamp
    }

    public var isPaused: Bool {
        get {
            !CVDisplayLinkIsRunning(displayLink)
        }
        set {
            if newValue {
                CVDisplayLinkStop(displayLink)
            } else {
                CVDisplayLinkStart(displayLink)
            }
        }
    }

    public init(target: NSObject, selector: Selector) {
        var displayLink: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        self.displayLink = displayLink!
        CVDisplayLinkSetOutputHandler(self.displayLink) { [weak self] _, _, _, _, _ in
            guard let self else { return kCVReturnSuccess }
            self.runloop?.perform(selector, target: target, argument: self, order: 0, modes: [self.mode])
            return kCVReturnSuccess
        }
        CVDisplayLinkStart(self.displayLink)
    }

    public init(block: @escaping (() -> Void)) {
        var displayLink: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        self.displayLink = displayLink!
        CVDisplayLinkSetOutputHandler(self.displayLink) { _, _, _, _, _ in
            block()
            return kCVReturnSuccess
        }
        CVDisplayLinkStart(self.displayLink)
    }

    open func add(to runloop: RunLoop, forMode mode: RunLoop.Mode) {
        self.runloop = runloop
        self.mode = mode
    }

    public func invalidate() {
        isPaused = true
        runloop = nil
        CVDisplayLinkSetOutputHandler(displayLink) { _, _, _, _, _ in
            kCVReturnError
        }
    }
}
#endif
