#if os(iOS)
import SwiftUI
import UIKit
import Perception
import TVCore

/// NotificationCenter permits removal on any executor. Keep the non-Sendable
/// Foundation token behind a lifetime owner so a view's nonisolated deinit
/// never reads actor-isolated state during Swift 6 teardown.
private final class DanmakuPreferenceObservation: @unchecked Sendable {
    private let token: NSObjectProtocol
    init(_ token: NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
}

/// MacCat's scheduler prepares glyphs ahead of the playhead and lets the
/// compositor move their textures. UIKit/CoreAnimation provides that same
/// separation on iOS without rebuilding a SwiftUI Canvas for every frame.
struct NativeDanmakuSurface: UIViewRepresentable {
    let clock: DanmakuPlaybackClock
    let renderer: DanmakuEngine
    let comments: [Danmaku]
    let revision: String
    let sourceID: String
    let area: DanmakuArea
    let textScale: Double
    let scale: CGFloat
    let delay: Double
    let opacity: Double

    func makeUIView(context: Context) -> NativeDanmakuView { NativeDanmakuView() }
    func updateUIView(_ view: NativeDanmakuView, context: Context) {
        view.configure(self)
    }
    static func dismantleUIView(_ view: NativeDanmakuView, coordinator: ()) { view.stop() }
}

@MainActor final class NativeDanmakuView: UIView {
    @MainActor private final class DisplayTarget: NSObject {
        weak var owner: NativeDanmakuView?
        @objc func display(_ link: CADisplayLink) { owner?.display(link) }
    }
    private struct Tile {
        let layer: CALayer
        var image: CGImage
        var motion: DanmakuEngine.Motion?
        var opacity: Double
    }
    private struct VisibleGeometry: Equatable {
        let frame: CGRect
        let rotation: Double
        let alpha: Double
    }
    private struct Configuration: Equatable, Sendable {
        let revision: String, sourceID: String
        let count: Int
        let area: DanmakuArea
        let textScale: Double, delay: Double, opacity: Double
        let scale: CGFloat
    }
    private let scene = CALayer()
    private let drawing = DispatchQueue(label: "yingxia.danmaku.prepare", qos: .userInitiated)
    private var tiles: [UInt64: Tile] = [:]
    private var geometry: [UInt64: VisibleGeometry] = [:]
    private var clock: DanmakuPlaybackClock?
    private var renderer: DanmakuEngine?
    private var configuration: Configuration?
    private var displayLink: CADisplayLink?
    private var displayTarget: DisplayTarget?
    private var preferenceObserver: DanmakuPreferenceObservation?
    private var activityObservers: [DanmakuPreferenceObservation] = []
    private var transportObservationGeneration = 0
    private var suspended = false
    private var needsFrame = true
    private var preparing = false
    private var hasAdvanced = false
    private var lastPreparation = -Double.infinity
    private var generation: UInt64 = 0
    private var revision = -1
    private var layerClock = DanmakuLayerClock()
    private var sceneStopped = true
    private var viewport = CGSize.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false; backgroundColor = .clear; isUserInteractionEnabled = false
        layer.addSublayer(scene)
        scene.masksToBounds = true
        // Keep opacity on each glyph. Group opacity would flatten the entire
        // scrolling surface into a fresh offscreen texture on every frame.
        scene.allowsGroupOpacity = false
        preferenceObserver = DanmakuPreferenceObservation(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.renderer?.refreshPreferences(); self.needsFrame = true
                self.updateDisplaySchedule()
            }
        })
        suspended = UIApplication.shared.applicationState == .background
        activityObservers = [
            DanmakuPreferenceObservation(NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.suspended = true
                    self?.displayLink?.isPaused = true
                    self?.layerClock.invalidate()
                    CATransaction.begin(); CATransaction.setDisableActions(true)
                    self?.scene.isHidden = true
                    CATransaction.commit()
                }
            }),
            DanmakuPreferenceObservation(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.suspended = false; self.needsFrame = true
                    self.layerClock.invalidate(); self.updateDisplaySchedule()
                }
            })
        ]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ input: NativeDanmakuSurface) {
        let next = Configuration(revision: input.revision, sourceID: input.sourceID, count: input.comments.count,
            area: input.area, textScale: input.textScale, delay: input.delay, opacity: input.opacity, scale: input.scale)
        let clockChanged = clock !== input.clock
        clock = input.clock; renderer = input.renderer
        if clockChanged, displayLink != nil {
            transportObservationGeneration += 1
            observeTransport()
        }
        input.renderer.refreshPreferences()
        guard configuration != next else {
            if clockChanged { layerClock.invalidate(); needsFrame = true; updateDisplaySchedule() }
            return
        }
        if configuration?.revision != next.revision || configuration?.sourceID != next.sourceID || configuration?.count != next.count {
            input.renderer.load(input.comments, sourceID: input.sourceID)
        }
        if configuration?.delay != next.delay { layerClock.invalidate() }
        if configuration?.sourceID != next.sourceID {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            for tile in tiles.values { tile.layer.removeFromSuperlayer() }
            tiles.removeAll(keepingCapacity: true)
            geometry.removeAll(keepingCapacity: true)
            CATransaction.commit()
        }
        configuration = next; generation &+= 1; needsFrame = true
        updateDisplaySchedule()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard viewport != bounds.size else { return }
        viewport = bounds.size; generation &+= 1; needsFrame = true
        CATransaction.begin(); CATransaction.setDisableActions(true)
        scene.frame = bounds
        CATransaction.commit()
        updateDisplaySchedule()
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stop(); return }
        guard displayLink == nil else { return }
        let target = DisplayTarget(); target.owner = self; displayTarget = target
        let link = CADisplayLink(target: target, selector: #selector(DisplayTarget.display(_:)))
        link.add(to: .main, forMode: .common); displayLink = link
        layerClock.invalidate(); needsFrame = true
        transportObservationGeneration += 1
        observeTransport(); updateDisplaySchedule()
    }
    func stop() {
        displayLink?.invalidate(); displayLink = nil; displayTarget = nil
        transportObservationGeneration += 1
        generation &+= 1; layerClock.invalidate()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        scene.speed = 0
        for tile in tiles.values { tile.layer.removeFromSuperlayer() }
        tiles.removeAll(keepingCapacity: true)
        geometry.removeAll(keepingCapacity: true)
        CATransaction.commit()
    }

    private func observeTransport() {
        guard let clock, clock.observesTransport, window != nil else { return }
        let observed = transportObservationGeneration
        withPerceptionTracking {
            _ = clock.stoppedValue(); _ = clock.speedValue()
            _ = clock.revisionValue(); _ = clock.seekingValue()
            _ = clock.stoppedPictureRevisionValue()
        } onChange: { [weak self, weak clock] in
            Task { @MainActor [weak self, weak clock] in
                guard let self, let clock, self.clock === clock,
                      self.transportObservationGeneration == observed, self.window != nil else { return }
                self.needsFrame = true
                self.updateDisplaySchedule()
                self.observeTransport()
            }
        }
    }

    private func updateDisplaySchedule() {
        guard let link = displayLink else { return }
        let empty = configuration?.count == 0 && tiles.isEmpty
        // An actual transport pause can sleep until observation wakes it. A
        // picture stall still polls so the first arriving frame resumes motion.
        let paused = clock?.observesTransport == true && clock?.stoppedValue() == true
        link.isPaused = suspended || empty || (paused && !needsFrame && !preparing)
        let maximum = Float(window?.screen.maximumFramesPerSecond ?? 60)
        // Dense first-window rasterization is sliced by the renderer. Drain its
        // outstanding slices promptly before settling into the 100 ms cadence.
        let preferred = needsFrame || (hasAdvanced && !paused) ? maximum : min(10, maximum)
        if link.preferredFrameRateRange.preferred != preferred {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: min(30, preferred), maximum: preferred, preferred: preferred)
        }
    }

    private func display(_ link: CADisplayLink) {
        guard !suspended else { return }
        guard let clock, let renderer, let configuration, viewport.width > 0, viewport.height > 0 else { return }
        let snapshot = clock.snapshot()
        let time = snapshot.position - configuration.delay
        guard time.isFinite else { return }
        let rate = snapshot.stopped || snapshot.seeking ? 0 : snapshot.speed
        let transportChanged = revision != snapshot.revision || sceneStopped != (rate == 0)
        if let anchor = layerClock.synchronize(media: time, rate: rate, revision: snapshot.revision, at: CACurrentMediaTime()) {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            scene.speed = Float(anchor.rate); scene.timeOffset = anchor.media; scene.beginTime = anchor.wall
            if revision != snapshot.revision {
                for tile in tiles.values { tile.layer.removeFromSuperlayer() }
                tiles.removeAll(keepingCapacity: true)
                geometry.removeAll(keepingCapacity: true)
                generation &+= 1
            }
            scene.isHidden = snapshot.seeking
            CATransaction.commit()
            revision = snapshot.revision
            if transportChanged { needsFrame = true }
        }
        sceneStopped = rate == 0
        if scene.isHidden != snapshot.seeking { scene.isHidden = snapshot.seeking; needsFrame = true }
        guard !snapshot.seeking, !preparing else { return }
        // Advanced paths need the display cadence; ordinary transforms already
        // run independently in CoreAnimation and only need 100 ms scheduling.
        let interval = hasAdvanced ? max(1.0 / 120, link.duration) : 0.1
        guard needsFrame || (!snapshot.stopped && link.timestamp - lastPreparation + 0.000001 >= interval) else {
            updateDisplaySchedule(); return
        }
        needsFrame = false; preparing = true; lastPreparation = link.timestamp
        let epoch = generation, size = viewport
        let ticket = renderer.nextDrawTicket()
        drawing.async { [weak self] in
            let sprites = renderer.frame(time: time, size: size, scale: configuration.scale, area: configuration.area,
                textScale: configuration.textScale, timelineRevision: snapshot.revision, drawTicket: ticket, preload: 1)
            let pending = renderer.hasPendingPreparation(through: time + 1)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.preparing = false
                guard self.window != nil, self.generation == epoch,
                      self.clock?.timelineRevision == snapshot.revision, self.clock?.seeking != true else {
                    self.needsFrame = true; self.updateDisplaySchedule(); return
                }
                self.finishPreparation(pending: pending)
                self.present(sprites, opacity: configuration.opacity)
                self.updateDisplaySchedule()
            }
        }
    }

    private func finishPreparation(pending: Bool) {
        // A paused/style/transport update can request one last frame while the
        // worker is running. Completion may add work, never erase that request.
        needsFrame = needsFrame || pending
    }

    private func present(_ sprites: [DanmakuEngine.Sprite], opacity: Double) {
        hasAdvanced = sprites.contains { $0.motion == nil }
        let current = Set(sprites.map(\.id))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for id in tiles.keys where !current.contains(id) {
            tiles.removeValue(forKey: id)?.layer.removeFromSuperlayer(); geometry[id] = nil
        }
        for sprite in sprites {
            let alpha = min(1, max(0, sprite.opacity * opacity))
            var tile: Tile
            if let retained = tiles[sprite.id] { tile = retained }
            else {
                let glyph = CALayer(); glyph.contentsScale = configuration?.scale ?? 1
                glyph.contentsGravity = .resize; glyph.allowsGroupOpacity = false
                scene.addSublayer(glyph)
                tile = Tile(layer: glyph, image: sprite.image, motion: nil, opacity: -1)
                glyph.contents = sprite.image
            }
            if tile.image !== sprite.image { tile.layer.contents = sprite.image; tile.image = sprite.image }
            if let motion = sprite.motion {
                if tile.motion != motion || tile.opacity != alpha {
                    tile.layer.bounds = CGRect(origin: .zero, size: sprite.frame.size)
                    tile.layer.position = motion.to; tile.layer.opacity = 0
                    let move = CABasicAnimation(keyPath: "position")
                    move.fromValue = NSValue(cgPoint: motion.from); move.toValue = NSValue(cgPoint: motion.to)
                    move.duration = motion.duration
                    let visible = CABasicAnimation(keyPath: "opacity")
                    visible.fromValue = alpha; visible.toValue = alpha
                    visible.duration = motion.duration
                    let group = CAAnimationGroup()
                    group.animations = [move, visible]; group.duration = motion.duration
                    // CoreAnimation interprets exactly zero as "start now".
                    // A cue at media zero loaded after a seek must keep its age.
                    group.beginTime = motion.start == 0 ? 0.000001 : motion.start
                    group.isRemovedOnCompletion = false; group.fillMode = .removed
                    group.timingFunction = CAMediaTimingFunction(name: .linear)
                    tile.layer.add(group, forKey: "danmaku-motion")
                }
            } else {
                let next = VisibleGeometry(frame: sprite.frame, rotation: sprite.rotation, alpha: alpha)
                if geometry[sprite.id] != next {
                    tile.layer.removeAnimation(forKey: "danmaku-motion")
                    tile.layer.bounds = CGRect(origin: .zero, size: sprite.frame.size)
                    tile.layer.position = CGPoint(x: sprite.frame.midX, y: sprite.frame.midY)
                    tile.layer.setAffineTransform(CGAffineTransform(rotationAngle: sprite.rotation * .pi / 180))
                    tile.layer.opacity = Float(alpha)
                    geometry[sprite.id] = next
                }
            }
            tile.motion = sprite.motion; tile.opacity = alpha; tiles[sprite.id] = tile
        }
        CATransaction.commit()
    }
}
#endif
