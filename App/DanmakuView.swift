import SwiftUI
import Perception
import AVFoundation
import CoreText
import TVCore

/// A single clock adapter for the comment renderer and seekable comment list.
@MainActor final class DanmakuPlaybackClock {
    struct Snapshot: Sendable {
        let position: Double
        let speed: Double
        let stopped: Bool
        let seeking: Bool
        let revision: Int
    }
    let positionValue: () -> Double
    let durationValue: () -> Double
    let seekValue: (Double) -> Void
    let playValue: () -> Void
    let revisionValue: () -> Int
    let stoppedPictureRevisionValue: () -> Int
    let seekingValue: () -> Bool
    let stoppedValue: () -> Bool
    let speedValue: () -> Double
    /// KS exposes transport changes through Perception; the AV adapter retains polling.
    let observesTransport: Bool
    private var clock = DanmakuTimelineClock()
    var position: Double {
        clock.sample(position: positionValue(), stopped: stoppedValue(), speed: speedValue(),
                     revision: revisionValue(), at: ProcessInfo.processInfo.systemUptime)
    }
    func snapshot() -> Snapshot {
        let now = ProcessInfo.processInfo.systemUptime
        let revision = revisionValue(), seeking = seekingValue(), stopped = stoppedValue(), speed = speedValue()
        let position = clock.sample(position: positionValue(), stopped: stopped, speed: speed, revision: revision, at: now)
        return Snapshot(position: position, speed: clock.playbackRate,
                        stopped: stopped || clock.isWaitingForPicture(at: now), seeking: seeking, revision: revision)
    }
    var duration: Double { durationValue() }
    var timelineRevision: Int { revisionValue() }
    var seeking: Bool { seekingValue() }
    func seek(_ time: Double) { seekValue(time) }
    func play() { playValue() }
    init(player: AVPlayer) {
        observesTransport = false
        positionValue = { player.currentTime().seconds }
        durationValue = { player.currentItem?.duration.seconds ?? .nan }
        seekValue = { player.seek(to: CMTime(seconds: $0, preferredTimescale: 600)) }
        playValue = { player.play() }
        revisionValue = { 0 }
        stoppedPictureRevisionValue = { 0 }
        seekingValue = { false }
        stoppedValue = { player.timeControlStatus != .playing }
        speedValue = { Double(player.rate) }
    }
    #if os(iOS)
    init(engine: KSPlaybackEngine) {
        observesTransport = true
        positionValue = { engine.displayPosition }; durationValue = { engine.duration }
        seekValue = { engine.seek(to: $0) }; playValue = { engine.play() }
        revisionValue = { engine.timelineRevision }
        stoppedPictureRevisionValue = { engine.stoppedPictureRevision }
        seekingValue = { engine.seeking }
        stoppedValue = { engine.paused || engine.buffering || engine.seeking }
        speedValue = { Double(engine.speed) }
    }
    #endif
}

/// Bullet comments over the video. Positions come from the player's clock on every frame, so the
/// comments pause, seek and change speed with the video; each comment's text is drawn once.
struct DanmakuOverlay: View {
    @State private var playbackClock: DanmakuPlaybackClock
    let comments: [Danmaku]
    var opacity = 0.9
    var revision = ""
    var sourceID: String?
    @AppStorage(DanmakuArea.key) private var area = DanmakuArea.standard
    @AppStorage(DanmakuStyle.fontSizeKey) private var fontSize = DanmakuStyle.standardFontSize
    @AppStorage("danmakuDelay") private var delay = 0.0
    @State private var engine = DanmakuEngine()
    @Environment(\.displayScale) private var scale

    init(player: AVPlayer, comments: [Danmaku], opacity: Double = 0.9, revision: String = "", sourceID: String? = nil) {
        _playbackClock = State(initialValue: DanmakuPlaybackClock(player: player))
        self.comments = comments; self.opacity = opacity; self.revision = revision; self.sourceID = sourceID
    }
    #if os(iOS)
    init(engine: KSPlaybackEngine, comments: [Danmaku], opacity: Double = 0.9, revision: String = "", sourceID: String? = nil) {
        _playbackClock = State(initialValue: DanmakuPlaybackClock(engine: engine))
        self.comments = comments; self.opacity = opacity; self.revision = revision; self.sourceID = sourceID
    }
    #endif

    var body: some View {
        WithPerceptionTracking {
            #if os(iOS)
            NativeDanmakuSurface(clock: playbackClock, renderer: engine, comments: comments,
                revision: revision, sourceID: sourceID ?? revision, area: area,
                textScale: DanmakuStyle.textScale(fontSize), scale: scale, delay: delay, opacity: opacity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            #else
            TimelineView(.animation) { timeline in
                WithPerceptionTracking {
                    // Snapshot observed/UI state in the view update. The asynchronous canvas only
                    // consumes values and the renderer's locked state, so it never reads the player
                    // or SwiftUI property wrappers from its drawing callback.
                    let _ = timeline.date
                    let time = playbackClock.position - delay
                    let seeking = playbackClock.seeking
                    let timelineRevision = playbackClock.timelineRevision
                    let renderer = engine, renderScale = scale, renderArea = area
                    let textScale = DanmakuStyle.textScale(fontSize)
                    let _ = renderer.refreshPreferences()
                    let drawTicket = renderer.nextDrawTicket()
                    Canvas(rendersAsynchronously: true) { context, size in
                        guard time.isFinite, !seeking else { return }
                        for sprite in renderer.frame(time: max(0, time), size: size, scale: renderScale, area: renderArea, textScale: textScale, timelineRevision: timelineRevision, drawTicket: drawTicket) {
                            var layer = context
                            layer.opacity = sprite.opacity
                            if sprite.rotation != 0 {
                                layer.translateBy(x: sprite.frame.midX, y: sprite.frame.midY)
                                layer.rotate(by: .degrees(sprite.rotation))
                                layer.translateBy(x: -sprite.frame.midX, y: -sprite.frame.midY)
                            }
                            layer.draw(Image(decorative: sprite.image, scale: renderScale), in: sprite.frame)
                        }
                    }
                }
            }
            .opacity(opacity)
            // No `ignoresSafeArea` here: it would win over the caller's, and the iPhone keeps comments below the Dynamic Island.
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task(id: "\(sourceID ?? revision):\(revision):\(comments.count)") {
                engine.load(comments, sourceID: sourceID ?? revision)
            }
            #endif
        }
    }
}

/// Whether comments are shown, from Settings and the player's own toggle.
enum DanmakuPreference {
    static let key = "danmakuEnabled"
}

#if !os(tvOS)
/// Text size and opacity for the player's danmaku menu, next to the area, for whatever comments are playing.
struct DanmakuStylePickers: View {
    @AppBindable var model: CatalogDanmakuModel

    var body: some View {
        WithPerceptionTracking {
            Picker(selection: $model.fontSize) {
                ForEach(DanmakuStyle.fontSizes(including: model.fontSize), id: \.self) { perceptionArgument0 in WithPerceptionTracking { Text(verbatim: "\(Int(perceptionArgument0.rounded()))").tag(perceptionArgument0) } }
            } label: { Label(L10n.text("Text Size"), systemImage: "textformat.size") }
            .pickerStyle(.menu)
            Picker(selection: $model.opacity) {
                ForEach(DanmakuStyle.opacities(including: model.opacity), id: \.self) { perceptionArgument0 in WithPerceptionTracking { Text(verbatim: "\(Int((perceptionArgument0 * 100).rounded()))%").tag(perceptionArgument0) } }
            } label: { Label(L10n.text("Opacity"), systemImage: "circle.lefthalf.filled") }
            .pickerStyle(.menu)
        }
    }
}
#endif

final class DanmakuEngine: @unchecked Sendable {
    struct Motion: Equatable, Sendable {
        let start: Double, duration: Double
        let from: CGPoint, to: CGPoint
    }
    struct Sprite: @unchecked Sendable {
        let image: CGImage
        let frame: CGRect
        var opacity = 1.0
        var rotation = 0.0
        var id: UInt64 = 0
        var motion: Motion?
        var animated = false
    }
    private struct Active {
        let id: UInt64
        var placement: DanmakuLayout.Placement
        var image: CGImage
        let size: CGSize
        let animatedEffect: NativeFancyDanmakuPainter.Effect?
        var animationFrame = 0
    }
    private let lock = NSLock()
    private let sourceLock = NSLock()
    private struct SourceInput {
        let comments: [Danmaku]
        let sourceID: String?
        let revision: UInt64
        let continuityRevision: UInt64
    }
    // One latest immutable input; intermediate source changes survive coalescing in the epoch.
    private var publishedInput: SourceInput?
    private var receivedInputRevision: UInt64 = 0
    private var appliedContinuityRevision: UInt64 = 0
    private let drawTicketLock = NSLock()
    private var allocatedDrawTicket: UInt64 = 0
    private var highestAcceptedDraw: UInt64 = 0
    private var comments: [Danmaku] = []
    private var sourceID: String?
    private var reloadedConsumed: [Danmaku: Int] = [:]
    private var layout: DanmakuLayout?
    private var size = CGSize.zero
    private var area = DanmakuArea.standard
    private var textScale = 1.0
    private var fontSize: CGFloat = 24
    private var next = 0
    private var active: [Active] = []
    private var lastTime = -1.0
    private var reconstructionTime = -1.0
    /// Rendered text, reused: busy tracks repeat the same few words, and drawing text is the costly part.
    private var images: [String: CGImage] = [:]
    private var imageBytes = 0
    private var positioned: [Danmaku] = []
    private var positionedIDs: [UInt64] = []
    private var nextSpriteID: UInt64 = 0
    private var positionedStart = 0
    private var positionedLifetime = 120.0
    private var configuredRows = -1
    private var configuredSpeed = -1.0
    private var configuredTimeline = -1
    private var highestAcceptedTimeline = -1
    private var configuredScale: CGFloat = 0
    private var positionedCache = NativeBASRenderer.Cache()
    private let preferenceLock = NSLock()
    private var pendingPreferences: RenderPreferences?
    private var preferences: RenderPreferences?
    private var preferencesDirty = true
    private var styleChanged = false
    private var preferencesObserver: NSObjectProtocol?
    private struct RenderPreferences: Equatable {
        let rows: Int
        let speed: Double
        let spacing: Double
        let areaPercent: Double?
        let hasArea: Bool
        let fancyEnabled: Bool
        let style: [String]
        let text: DanmakuText.Preferences
        let fancy: FancyDanmakuPreferences
        init() {
            let defaults = UserDefaults.standard
            rows = defaults.integer(forKey: "danmakuMaxRows")
            let storedSpeed = defaults.double(forKey: "danmakuSpeed")
            speed = storedSpeed == 0 ? 1 : storedSpeed
            spacing = defaults.object(forKey: "danmakuLineSpacing") as? Double ?? 7
            let percent = defaults.object(forKey: "danmakuAreaPercent") as? Double
            areaPercent = percent.flatMap { $0.isFinite ? $0 : nil }
            hasArea = defaults.object(forKey: DanmakuArea.key) != nil
            fancyEnabled = defaults.bool(forKey: "danmakuFancyEnabled")
            text = DanmakuText.Preferences()
            fancy = FancyDanmakuPreferences.load()
            let keys = ["danmakuFontFamily", "danmakuFontWeight", "danmakuFancyRatio", "danmakuFancyKinds", "danmakuFancyWeights", "danmakuFancyNames", "danmakuFancyIcons", "danmakuColorMode", "danmakuGradientStart", "danmakuGradientEnd"]
            style = keys.map { String(describing: defaults.object(forKey: $0) ?? "") }
        }
    }

    init() {
        preferencesObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.preferenceLock.withLock { self?.preferencesDirty = true }
        }
        refreshPreferences()
    }
    deinit { if let preferencesObserver { NotificationCenter.default.removeObserver(preferencesObserver) } }
    /// Called during the view update, before an asynchronous canvas reads the prepared values.
    func refreshPreferences() {
        let needsRefresh = preferenceLock.withLock {
            guard preferencesDirty else { return false }
            preferencesDirty = false
            return true
        }
        guard needsRefresh else { return }
        // Do not acquire the rendering lock here: the UI must keep accepting touches while a
        // previous canvas is rasterizing. Publish one immutable value using a separate short lock.
        let current = RenderPreferences()
        preferenceLock.withLock { pendingPreferences = current }
    }
    private func applyPendingPreferences() {
        let pending = preferenceLock.withLock {
            let value = pendingPreferences
            pendingPreferences = nil
            return value
        }
        if let pending, pending != preferences {
            if let previous = preferences {
                styleChanged = previous.rows != pending.rows || previous.spacing != pending.spacing || previous.areaPercent != pending.areaPercent
                    || previous.hasArea != pending.hasArea || previous.fancyEnabled != pending.fancyEnabled
                    || previous.style != pending.style || previous.text != pending.text || previous.fancy != pending.fancy
            } else { styleChanged = true }
            preferences = pending
            NativeFancyDanmakuPainter.refreshPreferences(pending.fancy)
        }
    }
    /// Dense tracks (Dandanplay merges several sites, up to 30,000 comments) would otherwise measure and draw
    /// dozens of comments in one frame and stall it; the rest wait a frame, and those a second late are dropped.
    private static let perFrame = 4, onScreen = 150

    /// The UI publishes array storage without waiting for text rasterization. Identity checks for
    /// legacy callers without a source ID happen outside both locks; an explicit ID is constant work.
    func load(_ comments: [Danmaku], sourceID: String? = nil) {
        while true {
            let previous = sourceLock.withLock { publishedInput }
            let sameSource: Bool
            if let previous {
                sameSource = sourceID == previous.sourceID &&
                    (sourceID != nil || comments == previous.comments || !Set(previous.comments).isDisjoint(with: comments))
            } else { sameSource = false }
            let published = sourceLock.withLock {
                // A concurrent publisher may win while the legacy identity check runs.
                guard publishedInput?.revision == previous?.revision else { return false }
                publishedInput = SourceInput(comments: comments, sourceID: sourceID,
                    revision: (previous?.revision ?? 0) + 1,
                    continuityRevision: (previous?.continuityRevision ?? 0) + (sameSource ? 0 : 1))
                return true
            }
            if published { return }
        }
    }
    /// Only an accepted drawing callback consumes the latest window, while it owns the raster lock.
    private func applyPendingSource() {
        let input = sourceLock.withLock { () -> SourceInput? in
            guard let input = publishedInput, input.revision != receivedInputRevision else { return nil }
            receivedInputRevision = input.revision
            return input
        }
        guard let input else { return }
        let comments = input.comments, sourceID = input.sourceID
        let sameSource = input.continuityRevision == appliedContinuityRevision && sourceID == self.sourceID
        appliedContinuityRevision = input.continuityRevision
            let lifetime = max(layout?.scrollDuration ?? 8, layout?.fixedDuration ?? 4)
            let resumeTime = max(0, min(lastTime - lifetime, self.comments.indices.contains(next) ? self.comments[next].time : lastTime))
            let pendingConsumed = reloadedConsumed
            reloadedConsumed.removeAll(keepingCapacity: true)
            if sameSource {
                for comment in self.comments.prefix(next) where comment.time >= resumeTime {
                    reloadedConsumed[comment, default: 0] += 1
                }
                // Several network batches can arrive between display ticks. Keep acknowledgements
                // which the previous replacement has not yet advanced past.
                for (comment, count) in pendingConsumed where comment.time >= resumeTime {
                    reloadedConsumed[comment] = max(reloadedConsumed[comment] ?? 0, count)
                }
            }
            var retainedIDs: [Danmaku: [UInt64]] = [:]
            if sameSource {
                for (index, comment) in positioned.enumerated() { retainedIDs[comment, default: []].append(positionedIDs[index]) }
            }
            positioned = comments.filter { $0.position == .positioned }; positionedStart = 0
            positionedIDs = positioned.map { comment in
                if var ids = retainedIDs[comment], !ids.isEmpty {
                    let id = ids.removeLast(); retainedIDs[comment] = ids; return id
                }
                nextSpriteID &+= 1; return nextSpriteID << 8
            }
            positionedLifetime = min(3600, max(120, positioned.compactMap { $0.effect?.lifetime }.max() ?? 120))
            self.comments = comments; self.sourceID = sourceID
            if sameSource, layout != nil {
                // Window replacement and live trimming do not change already placed comments.
                // Resume at the pending timestamp, retaining per-comment duplicate counts for bursts.
                var low = 0, high = comments.count
                while low < high { let mid = (low + high) / 2; if comments[mid].time < resumeTime { low = mid + 1 } else { high = mid } }
                next = low
                reconstructionTime = lastTime
                return
            }
            layout = nil; active.removeAll(keepingCapacity: true)
    }

    /// Reserve when the UI snapshots media time, before an asynchronous drawing callback.
    /// This lock never nests the raster lock, so snapshotting cannot hold up playback controls.
    func nextDrawTicket() -> UInt64 {
        drawTicketLock.withLock { allocatedDrawTicket += 1; return allocatedDrawTicket }
    }
    func hasPendingPreparation(through time: Double) -> Bool {
        lock.withLock { next < comments.count && comments[next].time <= time }
    }
    func frame(time: Double, size: CGSize, scale: CGFloat, area: DanmakuArea = .standard, textScale: Double = 1,
               timelineRevision: Int = 0, drawTicket: UInt64? = nil, preload: Double = 0) -> [Sprite] {
        let ticket = drawTicket ?? nextDrawTicket()
        return lock.withLock { frameLocked(time: time, size: size, scale: scale, area: area, textScale: textScale,
                                           timelineRevision: timelineRevision, drawTicket: ticket, preload: preload) }
    }
    private func frameLocked(time: Double, size: CGSize, scale: CGFloat, area: DanmakuArea, textScale: Double,
                             timelineRevision: Int, drawTicket: UInt64, preload: Double) -> [Sprite] {
            // Canvas callbacks can finish out of order around a seek. Their captured epoch
            // must never rewind the current renderer or reintroduce a previous target window.
            guard time.isFinite, timelineRevision >= highestAcceptedTimeline, drawTicket >= highestAcceptedDraw else { return [] }
            highestAcceptedDraw = drawTicket
            // An empty or temporarily unmeasured canvas still observes the seek epoch.
            // Keep layout configuration separate so the first target-window draw restarts it.
            highestAcceptedTimeline = timelineRevision
            applyPendingSource()
            applyPendingPreferences()
            guard !comments.isEmpty || !active.isEmpty, size.width > 0, size.height > 0 else { return [] }
            // A new size, area or text size, or a seek (any jump the clock would not make by itself), starts over at `time`.
            guard let preferences else { return [] }
            let styleChanged = self.styleChanged
            self.styleChanged = false
            if styleChanged || scale != configuredScale || textScale != self.textScale || size != self.size {
                images.removeAll(keepingCapacity: true); imageBytes = 0; positionedCache.removeAll()
            }
            if layout == nil || timelineRevision != configuredTimeline || scale != configuredScale || styleChanged || size != self.size || area != self.area || textScale != self.textScale
                || time < lastTime - 0.3 {
                configuredRows = preferences.rows; configuredSpeed = preferences.speed
                configuredTimeline = timelineRevision; configuredScale = scale
                restart(at: time, size: size, area: area, textScale: textScale)
            } else if configuredSpeed != preferences.speed, var layout {
                layout.retime(scrollDuration: 8 / max(0.25, min(3, preferences.speed)), at: time)
                for index in active.indices { active[index].placement = layout.retimed(active[index].placement, at: time) }
                self.layout = layout; configuredSpeed = preferences.speed
            }
            lastTime = time
            active.removeAll { time - $0.placement.start >= (layout?.duration($0.placement) ?? 0) }
            var budget = preload > 0 ? 64 : Self.perFrame
            let started = ProcessInfo.processInfo.systemUptime
            while next < comments.count, comments[next].time <= time + max(0, min(1, preload)) {
                let comment = comments[next]
                if let consumed = reloadedConsumed[comment], consumed > 0 {
                    if consumed == 1 { reloadedConsumed[comment] = nil }
                    else { reloadedConsumed[comment] = consumed - 1 }
                    next += 1; continue
                }
                if comment.position == .positioned { next += 1; continue }
                // A target window can arrive after the seek. Restore its still-visible comments
                // at their actual ages; ordinary backlog older than one second remains bounded.
                guard active.count < Self.onScreen, var layout else { next += 1; continue }
                let lifetime = comment.position == .top || comment.position == .bottom ? layout.fixedDuration : layout.scrollDuration
                guard time - comment.time < lifetime,
                      preload > 0 || comment.time <= reconstructionTime || time - comment.time < 1 else { next += 1; continue }
                guard budget > 0, preload <= 0 || budget == 64 || ProcessInfo.processInfo.systemUptime - started < 0.004 else { break }
                budget -= 1; next += 1
                let font = fontSize * comment.scale
                let effect = NativeFancyDanmakuPainter.effect(comment)
                let width = NativeFancyDanmakuPainter.width(comment, effect: effect, size: font, preferences: preferences.text)
                // A queued glyph belongs to its media timestamp, including after a seek. Its
                // first draw uses its real age rather than restarting at the edge of the picture.
                guard let placement = layout.place(comment, width: width, at: comment.time),
                      let image = image(comment, effect: effect, size: font, scale: scale) else { self.layout = layout; continue }
                self.layout = layout
                nextSpriteID &+= 1
                active.append(Active(id: nextSpriteID << 8, placement: placement, image: image,
                    size: CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale),
                    animatedEffect: effect.flatMap { NativeFancyDanmakuPainter.isAnimated($0) ? $0 : nil }))
            }
            guard let layout else { return [] }
            let lane = layout.laneHeight
            let top = size.height * 4 / 720
            var sprites: [Sprite] = []
            for index in active.indices {
                let item = active[index]
                let placement = item.placement
                let x: Double, y: Double
                switch placement.comment.position {
                case .positioned: x = 0; y = 0
                case .reverse: x = -item.size.width + (time - placement.start) * placement.speed; y = top + Double(placement.lane) * lane
                case .scroll: x = layout.width - (time - placement.start) * placement.speed; y = top + Double(placement.lane) * lane
                case .top: x = (layout.width - item.size.width) / 2; y = top + Double(placement.lane) * lane
                case .bottom: x = (layout.width - item.size.width) / 2; y = top + Double(placement.lane) * lane
                }
                // Keep only the current animated tile per placement. Static badges keep their first
                // tile, and motion never reselects effects or hashes the entire comment again.
                let animationFrame = Int(max(0, time - placement.start) * 10)
                if let effect = item.animatedEffect, item.animationFrame != animationFrame {
                    if let bitmap = NativeFancyDanmakuPainter.image(placement.comment, effect: effect,
                        size: fontSize * placement.comment.scale, scale: scale, age: time - placement.start, preferences: preferences.text) {
                        active[index].image = bitmap
                    }
                    active[index].animationFrame = animationFrame
                }
                let rect = CGRect(x: x, y: y + (lane - item.size.height) / 2, width: item.size.width, height: item.size.height)
                let duration = layout.duration(placement)
                let fromX = placement.comment.position == .reverse ? -item.size.width : placement.speed > 0 ? layout.width : x
                let toX = placement.comment.position == .reverse ? layout.width : placement.speed > 0 ? -item.size.width : x
                let motion = Motion(start: placement.start, duration: duration,
                    from: CGPoint(x: fromX + item.size.width / 2, y: rect.midY), to: CGPoint(x: toX + item.size.width / 2, y: rect.midY))
                sprites.append(Sprite(image: active[index].image, frame: rect, id: item.id, motion: motion, animated: item.animatedEffect != nil))
            }
            // Positioned Bilibili effects use normalized 1280×720 coordinates and their own lifetime.
            var pixelBudget = 8_000_000
            let earliest = time - positionedLifetime
            // A monotonic cursor bounds expired advanced events; seeks binary-search the window.
            if time < lastTime - 0.3 { positionedStart = 0 }
            while positionedStart < positioned.count, positioned[positionedStart].time < earliest { positionedStart += 1 }
            let end = min(positioned.count, positionedStart + 2000)
            for index in positionedStart..<end {
                let comment = positioned[index]
                if comment.time > time { break }
                if sprites.count >= Self.onScreen { break }
                guard let effect = comment.effect,
                      time >= comment.time, time - comment.time <= effect.lifetime else { continue }
                if effect.kind == "bas" {
                    let remaining = Self.onScreen - sprites.count
                    let generated = NativeBASRenderer.sprites(effect, age: time - comment.time, size: size, scale: scale, textScale: textScale * 22 / 25, maxCount: remaining, pixelBudget: pixelBudget, cache: positionedCache, preferences: preferences.text, identity: positionedIDs[index])
                    for sprite in generated { pixelBudget -= sprite.image.width * sprite.image.height }
                    sprites.append(contentsOf: generated)
                    if sprites.count >= Self.onScreen { break }
                    continue
                }
                let proposedSize = CGFloat(effect.fontSize) * textScale * 22 / 25
                guard let bitmap = positionedCache.image(key: "positioned:\(comment.text):\(comment.color):\(effect.font):\(effect.outline):\(proposedSize):\(scale)", make: {
                          DanmakuText.image(comment.text, color: comment.color, size: proposedSize, scale: scale, family: effect.font, outlined: effect.outline, preferences: preferences.text)
                      }), bitmap.width <= 4096, bitmap.height <= 4096, bitmap.width * bitmap.height <= pixelBudget else { continue }
                pixelBudget -= bitmap.width * bitmap.height
                let elapsed = time - comment.time
                let progress = min(1, max(0, (elapsed - effect.moveDelay) / max(0.001, effect.moveDuration)))
                let coordinate = effect.coordinate(progress: progress)
                let frame = CGRect(x: coordinate.x * size.width / 1280,
                    y: coordinate.y * size.height / 720,
                    width: CGFloat(bitmap.width) / scale * size.width / 1280 * max(0.001, abs(cos(effect.rotateY * .pi / 180))),
                    height: CGFloat(bitmap.height) / scale * size.height / 720)
                sprites.append(Sprite(image: bitmap, frame: frame,
                    opacity: effect.opacity + (effect.endOpacity - effect.opacity) * min(1, elapsed / max(0.1, effect.lifetime)), rotation: effect.rotateZ, id: positionedIDs[index]))
                if sprites.count >= Self.onScreen { break }
            }
            return sprites
    }

    private func image(_ comment: Danmaku, effect: NativeFancyDanmakuPainter.Effect?, size: CGFloat, scale: CGFloat) -> CGImage? {
        guard let preferences else { return nil }
        if let effect {
            let key = "fancy:\(comment.hashValue):\(size):\(scale)"
            if let image = images[key] { return image }
            guard let bitmap = NativeFancyDanmakuPainter.image(comment, effect: effect, size: size, scale: scale, preferences: preferences.text) else { return nil }
            cache(bitmap, for: key); return bitmap
        }

        let decorated = comment.text
        let key = "\(comment.color):\(size):\(scale):\(decorated)"
        if let image = images[key] { return image }
        guard let image = DanmakuText.image(decorated, color: comment.effect?.kind == "positioned" ? comment.color : comment.effect?.foreground ?? comment.color, size: size, scale: scale, preferences: preferences.text) else { return nil }
        cache(image, for: key)
        return image
    }

    private func cache(_ image: CGImage, for key: String) {
        let bytes = image.bytesPerRow * image.height
        if images.count >= 400 || imageBytes + bytes > 24 * 1024 * 1024 {
            images.removeAll(keepingCapacity: true); imageBytes = 0
        }
        if bytes <= 24 * 1024 * 1024 { images[key] = image; imageBytes += bytes }
    }

    private func areaShare(_ fallback: DanmakuArea) -> Double {
        guard let percent = preferences?.areaPercent else {
            return preferences?.hasArea == true ? fallback.share : 0.5
        }
        return min(1, max(0.1, percent / 100))
    }

    private func restart(at time: Double, size: CGSize, area: DanmakuArea, textScale: Double) {
        reloadedConsumed.removeAll(keepingCapacity: true)
        self.size = size; self.area = area; self.textScale = textScale
        // MacCat measures on a 1280x720 stage. Keep its font/pitch/area relation
        // when the iPhone rotates instead of independently inflating its text.
        let stageScale = min(size.width / 1280, size.height / 720)
        let verticalScale = size.height / 720
        fontSize = 22 * textScale * stageScale
        let spacing = max(-28, min(32, preferences?.spacing ?? 7))
        // The lane pitch is the text size plus the user's spacing, nothing else.
        // The fancy-tile allowance (x1.7 with fancy on, x1.42 when the comments
        // carry effects) used to be added to EVERY lane's pitch, so at the user's
        // settings (text size 25, fancy on) the pitch started at 42.5 stage units
        // and even the slider's -28 minimum could only pull it to 14.5 — two
        // rounds of widening the slider (builds 8 and 10) never reached the
        // floor, and on device the rows still measured ~80 pt apart. Fancy tiles
        // keep their own painter and heights; they no longer tax the shared
        // lanes. The 25% floor stays: DanmakuLayout divides the usable height
        // by the lane height, and even the worst case (smallest text, tallest
        // screen, full area) keeps that at ~5.7 pt and the lane count ~250.
        let stagePitch = max(22 * textScale * 0.25, 22 * textScale + spacing)
        // Lua: floor((areaHeight - 8 + lineSpacing) / pitch).
        let usableHeight = max(1, size.height * areaShare(area) - (8 - spacing) * verticalScale)
        layout = DanmakuLayout(width: size.width, height: usableHeight, laneHeight: stagePitch * verticalScale, scrollArea: 1,
            scrollDuration: 8 / max(0.25, min(3, configuredSpeed)), maxRows: configuredRows)
        // The inputs behind every layout restart, so a diagnostics capture shows
        // the size and spacing the engine actually ran with (build 11 diagnosis:
        // the point-size surface the code assumes predicts a ~21 pt pitch at
        // spacing -28, while the device rendered ~80 pt rows).
        Diagnostics.shared.record(.info, "danmaku.layout",
            "size=\(Int(size.width))x\(Int(size.height)) spacing=\(spacing) textScale=\(textScale) stagePitch=\(stagePitch) laneHeight=\(stagePitch * verticalScale) lanes=\(layout?.scrollLanes ?? 0)")
        active = []
        reconstructionTime = time
        var effectLow = 0, effectHigh = positioned.count
        while effectLow < effectHigh { let mid = (effectLow + effectHigh) / 2; if positioned[mid].time < time - positionedLifetime { effectLow = mid + 1 } else { effectHigh = mid } }
        positionedStart = effectLow
        var low = 0, high = comments.count
        while low < high { let mid = (low + high) / 2; if comments[mid].time < max(0, time - max(layout?.scrollDuration ?? 8, layout?.fixedDuration ?? 4)) { low = mid + 1 } else { high = mid } }
        next = low
    }
}

/// Comment text as an image: semibold system type with a thin contrasting outline, as Bilibili draws it.
enum DanmakuText {
    enum VerticalAlignment { case typographic, inkCenter }
    struct Preferences: Equatable, Sendable {
        let family: String
        let weight: Int
        let mode: String
        let gradient: [String]
        init() {
            let defaults = UserDefaults.standard
            family = defaults.string(forKey: "danmakuFontFamily") ?? ""
            let storedWeight = defaults.integer(forKey: "danmakuFontWeight")
            weight = storedWeight == 0 ? 400 : storedWeight
            mode = defaults.string(forKey: "danmakuColorMode") ?? "source"
            gradient = [defaults.string(forKey: "danmakuGradientStart") ?? "#FFB86C", defaults.string(forKey: "danmakuGradientEnd") ?? "#8BE9FD"]
            #if os(iOS)
            PlayerFontLibrary.ensureRegistered()
            #endif
        }
    }
    // NSCache and CoreText support asynchronous canvas rasterization.
    nonisolated(unsafe) private static let fonts = NSCache<NSString, CTFont>()
    /// Creating the font is far slower than laying out a line, and every comment is measured: keep one per size.
    private static func font(_ size: CGFloat, family: String = "", preferences: Preferences) -> CTFont {
        let family = family.isEmpty ? preferences.family : family
        let weight = preferences.weight
        let key = "\(family):\(size):\(weight)" as NSString
        if let font = fonts.object(forKey: key) { return font }
        let base = family.isEmpty ? CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil) : CTFontCreateWithName(family as CFString, size, nil)
        let normalized = Double(min(900, max(100, weight)) - 400) / 500
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontTraitsAttribute: [kCTFontWeightTrait: normalized]] as CFDictionary)
        let font = CTFontCreateCopyWithAttributes(base, size, nil, descriptor)
        fonts.setObject(font, forKey: key)
        return font
    }
    private static func line(_ text: String, _ attributes: [NSAttributedString.Key: Any]) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }
    private static let padding: CGFloat = 3

    static func width(_ text: String, size: CGFloat, includeOverhang: Bool = false, preferences: Preferences = Preferences()) -> Double {
        let shaped = line(text, [.init(kCTFontAttributeName as String): font(size, preferences: preferences)])
        let advance = CGFloat(CTLineGetTypographicBounds(shaped, nil, nil, nil))
        guard includeOverhang else { return Double(advance + padding * 2) }
        let ink = CTLineGetBoundsWithOptions(shaped, [.useGlyphPathBounds])
        guard !ink.isNull, !ink.isEmpty else { return Double(advance + padding * 2) }
        return Double(max(advance, ink.maxX) - min(0, ink.minX) + padding * 2)
    }

    static func image(_ text: String, color: UInt32, size: CGFloat, scale: CGFloat, family: String = "", outlined: Bool = true,
                      gradient: [String]? = nil, outlineColor: String? = nil, outlineWidth: Double? = nil, usePreferences: Bool = true,
                      verticalAlignment: VerticalAlignment = .typographic, preferences: Preferences = Preferences()) -> CGImage? {
        let font = font(size, family: family, preferences: preferences)
        let mode = usePreferences ? preferences.mode : "source"
        let color = mode == "white" ? 0xffffff : mode == "random" ? PlayerStyleColor.randomColor(text: text) : color
        let gradient = gradient ?? (mode == "gradient" ? preferences.gradient : nil)
        let red = CGFloat(color >> 16 & 0xFF) / 255, green = CGFloat(color >> 8 & 0xFF) / 255, blue = CGFloat(color & 0xFF) / 255
        let dark = 0.299 * red + 0.587 * green + 0.114 * blue < 0.25
        let fill = line(text, [.init(kCTFontAttributeName as String): font, .init(kCTForegroundColorAttributeName as String): CGColor(srgbRed: red, green: green, blue: blue, alpha: 1)])
        let strokeColor = outlineColor.map(NativeFancyDanmakuPainter.color) ?? CGColor(gray: dark ? 1 : 0, alpha: dark ? 0.8 : 0.7)
        let strokePercent = outlineWidth.map { $0 / max(1, Double(size)) * 100 } ?? 6
        let outline = line(text, [.init(kCTFontAttributeName as String): font, .init(kCTStrokeWidthAttributeName as String): strokePercent,
                                  .init(kCTStrokeColorAttributeName as String): strokeColor])
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CTLineGetTypographicBounds(fill, &ascent, &descent, nil)
        let ink = verticalAlignment == .inkCenter ? CTLineGetBoundsWithOptions(fill, [.useGlyphPathBounds]) : .null
        let hasInk = !ink.isNull && !ink.isEmpty && ink.midY.isFinite
        // Combining marks and italic glyphs can exceed the typographic advance.
        // Retain them in fancy tiles before centering the complete ink bounds.
        let left = hasInk ? min(0, ink.minX) : 0
        let contentWidth = hasInk ? max(width, ink.maxX) - left : width
        let contentHeight = hasInk ? max(ascent + descent, ink.height) : ascent + descent
        let pixelsWide = Int(((contentWidth + padding * 2) * scale).rounded(.up)), pixelsHigh = Int(((contentHeight + padding * 2) * scale).rounded(.up))
        guard pixelsWide > 0, pixelsHigh > 0, pixelsWide <= 8192, pixelsHigh <= 2048, pixelsWide * pixelsHigh <= 2 * 1024 * 1024,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale); context.setLineJoin(.round)
        var baseline = CGPoint(x: padding - left, y: padding + descent)
        if hasInk {
            // Fancy panels align the visible glyphs, not the font's ascent or
            // this bitmap's safety padding. Measure the already-shaped line;
            // ordinary and positioned comments keep their original baseline.
            baseline.y = CGFloat(pixelsHigh) / scale / 2 - ink.midY
        }
        if outlined && strokePercent > 0 { context.textPosition = baseline; CTLineDraw(outline, context) }
        if let gradient, gradient.count >= 2 {
            let colors = gradient.prefix(2).map { NativeFancyDanmakuPainter.color($0) } as CFArray
            if let fillGradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]),
               let maskContext = CGContext(data: nil, width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8, bytesPerRow: 0,
                   space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                maskContext.scaleBy(x: scale, y: scale); maskContext.textPosition = baseline
                CTLineDraw(fill, maskContext)
                guard let mask = maskContext.makeImage() else { return nil }
                context.saveGState()
                context.clip(to: CGRect(x: 0, y: 0, width: CGFloat(pixelsWide) / scale, height: CGFloat(pixelsHigh) / scale), mask: mask)
                context.drawLinearGradient(fillGradient, start: CGPoint(x: padding, y: 0), end: CGPoint(x: contentWidth + padding, y: 0), options: [])
                context.restoreGState()
            }
        } else { context.textPosition = baseline; CTLineDraw(fill, context) }
        return context.makeImage()
    }

}

/// Every comment in time order, following the video. Choosing one plays from just before it.
/// On iPhone and Mac: a dark sheet with the comment count, a density strip of the whole episode
/// (tap it to jump), a search field, and rows marked with each comment's own colour. A playhead line
/// sits among the rows at the current moment, comments still to come are dimmed, and the list keeps up
/// with playback until you scroll it yourself.
struct DanmakuListView: View {
    @Environment(\.colorScheme) private var inheritedScheme
    var embedded = false
    private let playbackClock: DanmakuPlaybackClock
    let comments: [Danmaku]
    var chosen: () -> Void = {}
    @State private var query = ""
    @State private var now: Double = 0
    @State private var following = true
    @State private var anchor: Int?
    init(player: AVPlayer, comments: [Danmaku], chosen: @escaping () -> Void = {}) {
        playbackClock = DanmakuPlaybackClock(player: player); self.comments = comments; self.chosen = chosen
    }
    #if os(iOS)
    init(engine: KSPlaybackEngine, comments: [Danmaku], embedded: Bool = false, chosen: @escaping () -> Void = {}) {
        playbackClock = DanmakuPlaybackClock(engine: engine); self.comments = comments; self.embedded = embedded; self.chosen = chosen
    }
    #endif
    private var shown: [(offset: Int, element: Danmaku)] {
        let all = Array(comments.enumerated())
        let text = query.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? all : all.filter { $0.element.text.localizedCaseInsensitiveContains(text) }
    }

    #if os(tvOS)
    /// The rows that exist: a page around the current moment, grown a page at a time at either end. A lazy stack
    /// alone still kept an identity for every comment (thousands in a busy episode) and, to open at the current
    /// moment, sized every row above it.
    @State private var window: Range<Int> = 0..<0
    /// Rows are added above only once the list has opened at the current moment.
    @State private var placed = false
    private static let page = 100

    var body: some View {
        WithPerceptionTracking {
            ScrollViewReader { proxy in
                WithPerceptionTracking {
                    // Not a List: tvOS puts a square focus background behind list cells. Not glass rows either: the list sits
                    // over the playing video and its moving comments, so a glass row blurred a changing picture on every frame
                    // and every press of the remote lagged. A plain white plate, as in the TV's own lists.
                    ScrollView {
                        WithPerceptionTracking {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                WithPerceptionTracking {
                                    ForEach(window, id: \.self) { index in
                                        WithPerceptionTracking {
                                            Button { jump(to: comments[index].time) } label: { tvRow(comments[index]) }
                                                .buttonStyle(TVDanmakuRowStyle())
                                                .id(index)
                                                .onAppear { grow(reaching: index, proxy) }
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 40).padding(.vertical, 24)
                        }
                    }
                    // Readable over a bright picture.
                    .background(.black.opacity(0.55))
                    // A TV scroll view draws its rows past its edges; these would run outside the panel.
                    .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                    .onAppear {
                        let now = playbackClock.position
                        let start = now.isFinite ? comments.firstIndex { $0.time >= now - 1 } ?? max(0, comments.count - 1) : 0
                        window = max(0, start - 20)..<min(comments.count, start + Self.page)
                        Task { @MainActor in
                            proxy.scrollTo(start, anchor: .top)
                            placed = true
                        }
                    }
                }
            }
        }
    }

    private func grow(reaching index: Int, _ proxy: ScrollViewProxy) {
        if index == window.upperBound - 1, window.upperBound < comments.count {
            window = window.lowerBound..<min(comments.count, window.upperBound + Self.page)
        } else if placed, index == window.lowerBound, window.lowerBound > 0 {
            // Rows added above push the ones shown down: keep the first one where it was.
            let first = window.lowerBound
            window = max(0, first - Self.page)..<window.upperBound
            Task { @MainActor in proxy.scrollTo(first, anchor: .top) }
        }
    }

    private struct TVDanmakuRowStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View { WithPerceptionTracking { Row(configuration: configuration) } }
        private struct Row: View {
            let configuration: ButtonStyleConfiguration
            @Environment(\.isFocused) private var focused
            var body: some View {
                WithPerceptionTracking {
                    configuration.label
                        .foregroundStyle(focused ? Color.black : Color.white)
                        .padding(.horizontal, 28).padding(.vertical, 10)
                        .background { WithPerceptionTracking { if focused { Capsule().fill(.white) } } }
                        .scaleEffect(configuration.isPressed ? 0.99 : 1)
                }
            }
        }
    }

    private func tvRow(_ comment: Danmaku) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(Self.clock(comment.time)).monospacedDigit().foregroundStyle(.secondary)
            Circle().fill(Self.tint(comment.color)).frame(width: 10, height: 10)
            Text(comment.text).lineLimit(2).foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
    #else
    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 0) {
                if embedded {
                    HStack {
                        Button(action: chosen) { Label("弹幕设置", systemImage: "chevron.left") }.buttonStyle(.plain)
                        Spacer()
                        Text(L10n.text("%d comments", comments.count)).foregroundStyle(.secondary)
                    }.font(.system(size: 19)).padding(.horizontal, 16).padding(.top, 12)
                } else { header.padding(.horizontal, 20).padding(.top, 22) }
                DanmakuDensity(bins: density, progress: duration > 0 ? now / duration : 0) { fraction in
                    following = true
                    jump(to: fraction * duration, dismiss: false)
                }
                .padding(.horizontal, 20).padding(.top, 16)
                search.padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 8)
                list
            }
            .foregroundStyle(.primary)
            .environment(\.colorScheme, embedded ? inheritedScheme : .dark)
            .task {
                // The playhead, twice a second: highlights what is on screen and keeps the list with it.
                while !Task.isCancelled {
                    let time = playbackClock.position
                    if time.isFinite { now = time }
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text("Danmaku")).font(.title2.weight(.bold))
                Text(L10n.text("%d comments", comments.count)).font(.system(size: 19)).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: chosen) {
                Image(systemName: "xmark").font(.system(size: 16, weight: .bold))
                    .frame(width: 32, height: 32)
                    .background(.white.opacity(0.14), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("Close"))
            #if os(macOS)
            .keyboardShortcut(.cancelAction)
            #endif
        }
    }

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(L10n.text("Filter comments"), text: $query)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                #endif
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.text("Clear"))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.primary.opacity(0.08), in: Capsule())
    }

    private var list: some View {
        let items = shown
        let playhead = query.isEmpty ? nowIndex : nil
        return ScrollViewReader { proxy in
            WithPerceptionTracking {
                ScrollView {
                    WithPerceptionTracking {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            WithPerceptionTracking {
                                ForEach(items, id: \.offset) { item in
                                    WithPerceptionTracking {
                                        if item.offset == playhead { nowLine }
                                        Button { jump(to: item.element.time) } label: { row(item.element, upcoming: item.element.time > now + 0.5) }
                                            .buttonStyle(DanmakuRowStyle())
                                            .id(item.offset)
                                    }
                                }
                                if playhead == comments.count { nowLine }
                            }
                        }
                        .padding(.horizontal, 10).padding(.bottom, 80)
                    }
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
                // Rows fade out under the search field instead of being cut off.
                .mask {
                    WithPerceptionTracking {
                        VStack(spacing: 0) {
                            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 16)
                            Color.black
                        }
                    }
                }
                // Scrolling by hand stops following the video until “Back to Now”.
                .onScrollByHand { following = false }
                .overlay {
                    WithPerceptionTracking {
                        if items.isEmpty {
                            AppContentUnavailableView.search(text: query)
                        }
                    }
                }
                .overlay(alignment: .bottom) {
                    WithPerceptionTracking {
                        if !following, query.isEmpty {
                            Button {
                                following = true
                                follow(proxy, animated: true)
                            } label: {
                                Label(L10n.text("Back to Now"), systemImage: "arrow.down.to.line")
                                    .font(.system(size: 19, weight: .semibold))
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 16).padding(.vertical, 10)
                                    .background(.white, in: Capsule())
                                    .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
                            }
                            .buttonStyle(.plain)
                            .padding(.bottom, 20)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                }
                .animation(.appSmooth(duration: 0.3), value: following)
                .onAppear { follow(proxy, animated: false) }
                .appOnChange(of: now) { _, _ in if following { follow(proxy, animated: true) } }
                .appOnChange(of: query) { _, text in if text.isEmpty { follow(proxy, animated: false) } }
            }
        }
    }

    private func row(_ comment: Danmaku, upcoming: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(Self.clock(comment.time))
                .font(.system(size: 17, weight: .medium)).monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .leading)
                .padding(.top, 2)
            RoundedRectangle(cornerRadius: 1.5).fill(Self.tint(comment.color)).frame(width: 3)
            Text(comment.text)
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .opacity(upcoming ? 0.42 : 1)
        .contentShape(Rectangle())
    }

    private var nowLine: some View { DanmakuNowLine(time: now) }

    /// Where the playhead falls among the comments: the first one still to come.
    private var nowIndex: Int { comments.partitioningIndex { $0.time > now + 0.5 } }

    private func follow(_ proxy: ScrollViewProxy, animated: Bool) {
        guard query.isEmpty, !comments.isEmpty else { return }
        // The row just after the playhead line, a third of the way down: recent comments above, the next few below.
        let target = min(comments.count - 1, nowIndex)
        guard target != anchor || !animated else { return }
        anchor = target
        if animated { withAnimation(.appSmooth(duration: 0.4)) { proxy.scrollTo(target, anchor: UnitPoint(x: 0.5, y: 0.4)) } }
        else { proxy.scrollTo(target, anchor: UnitPoint(x: 0.5, y: 0.4)) }
    }

    private var duration: Double {
        let length = playbackClock.duration
        return length.isFinite && length > 0 ? length : (comments.last?.time ?? 0) + 1
    }

    /// Comments per stretch of the episode, scaled to the busiest one.
    private var density: [Double] {
        let count = 64
        guard duration > 0, !comments.isEmpty else { return Array(repeating: 0, count: count) }
        var bins = Array(repeating: 0.0, count: count)
        for comment in comments { bins[min(count - 1, max(0, Int(comment.time / duration * Double(count))))] += 1 }
        let peak = bins.max() ?? 1
        return bins.map { ($0 / max(1, peak)).squareRoot() }
    }
    #endif

    static func clock(_ time: Double) -> String {
        Duration.seconds(Int(time)).formatted(.time(pattern: time >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }

    /// The comment's own colour; the usual white as a quiet grey so coloured ones stand out.
    static func tint(_ color: UInt32) -> Color {
        let red = Double(color >> 16 & 0xFF) / 255, green = Double(color >> 8 & 0xFF) / 255, blue = Double(color & 0xFF) / 255
        return min(red, green, blue) > 0.88 ? Color.primary.opacity(0.28) : Color(red: red, green: green, blue: blue)
    }

    private func jump(to time: Double, dismiss: Bool = true) {
        playbackClock.seek(max(0, time - 1))
        if dismiss {
            playbackClock.play()
            chosen()
        }
    }
}

#if !os(tvOS)
/// Where the comments gather across the episode, with the playhead; tap or drag to jump there.
private struct DanmakuDensity: View {
    let bins: [Double]
    let progress: Double
    let seek: (Double) -> Void
    var body: some View {
        WithPerceptionTracking {
            GeometryReader { geometry in
                WithPerceptionTracking {
                    let width = geometry.size.width, height = geometry.size.height
                    HStack(alignment: .bottom, spacing: 2) {
                        ForEach(bins.indices, id: \.self) { index in
                            WithPerceptionTracking {
                                let played = (Double(index) + 0.5) / Double(bins.count) <= progress
                                Capsule()
                                    .fill(played ? Brand.cyan : Color.primary.opacity(0.22))
                                    .frame(height: max(3, bins[index] * height))
                            }
                        }
                    }
                    .frame(width: width, height: height, alignment: .bottom)
                    .overlay(alignment: .bottomLeading) {
                        WithPerceptionTracking {
                            Capsule().fill(.primary).frame(width: 2, height: height + 6)
                                .offset(x: min(width - 2, max(0, progress * width - 1)), y: 3)
                                .shadow(color: .black.opacity(0.4), radius: 2)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onEnded { value in seek(min(1, max(0, value.location.x / width))) })
                }
            }
            .frame(height: 34)
            .accessibilityElement()
            .accessibilityLabel(L10n.text("Danmaku"))
            .accessibilityValue("\(Int(progress * 100))%")
        }
    }
}

/// The playhead among the comments: everything above it has been on screen.
private struct DanmakuNowLine: View {
    let time: Double
    var body: some View {
        WithPerceptionTracking {
            HStack(spacing: 10) {
                Text(DanmakuListView.clock(time))
                    .font(.system(size: 16, weight: .bold)).monospacedDigit()
                    .foregroundStyle(.black)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Brand.cyan, in: Capsule())
                Capsule().fill(Brand.cyan).frame(height: 2)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }
}

private struct DanmakuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        WithPerceptionTracking {
            configuration.label
                .opacity(configuration.isPressed ? 0.6 : 1)
                .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
        }
    }
}

extension View {
    /// The danmaku list as a sheet over the player: dark, half height first, pulled up for more.
    func danmakuListPresentation() -> some View {
        #if os(iOS)
        self.presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .appSheetBackground(.ultraThinMaterial)
            .appPresentationCornerRadius(28)
            .preferredColorScheme(.dark)
        #else
        self.frame(width: 520, height: 640)
            .background(Color(white: 0.09))
            .preferredColorScheme(.dark)
        #endif
    }
}
#endif

private extension Array {
    /// The first index where `belongs` becomes true, for an array already sorted by it.
    func partitioningIndex(where belongs: (Element) -> Bool) -> Int {
        var low = 0, high = count
        while low < high {
            let middle = (low + high) / 2
            if belongs(self[middle]) { high = middle } else { low = middle + 1 }
        }
        return low
    }
}
