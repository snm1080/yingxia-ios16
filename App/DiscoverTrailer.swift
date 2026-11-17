import SwiftUI
import Perception
import TVCore
@preconcurrency import AVFoundation

/// Public trailer catalog -> expiring MP4/HLS URL -> AVPlayerLayer. No web page,
/// embedded controls, or AVPlayerViewController participates in the home background.
actor DiscoverTrailerResolver {
    typealias Stream = TrailerStreamResolver.Stream
    static let shared = DiscoverTrailerResolver()
    private let resolver = TrailerStreamResolver()

    func resolve(_ trailer: TMDBMatch.Trailer) async -> Stream? {
        await resolver.resolve(trailer)
    }
    func invalidate(_ trailer: TMDBMatch.Trailer, failedURL: URL) async {
        await resolver.invalidate(trailer, failedURL: failedURL)
    }
}

@MainActor @Perceptible private final class DiscoverTrailerPlayback {
    let player = AVQueuePlayer()
    var ready = false
    private var looper: AVPlayerLooper?
    private var observer: Any?
    private var currentItemObserver: NSKeyValueObservation?
    private var statusObserver: NSKeyValueObservation?
    private var looperObserver: NSKeyValueObservation?
    private var failureObserver: NSObjectProtocol?
    private var retry: Task<Void, Never>?
    private var retryUsed = false
    private var retrying = false
    private var generation = 0
    private var attempt = UUID()

    init() {
        player.isMuted = true
        player.allowsExternalPlayback = false
        player.preventsDisplaySleepDuringVideoPlayback = false
    }
    func load(_ trailer: TMDBMatch.Trailer) async {
        stop()
        retryUsed = false
        generation += 1
        let requestGeneration = generation
        guard let stream = await DiscoverTrailerResolver.shared.resolve(trailer), !Task.isCancelled,
              generation == requestGeneration else { return }
        install(stream, trailer: trailer, generation: requestGeneration)
    }
    private func install(_ stream: DiscoverTrailerResolver.Stream, trailer: TMDBMatch.Trailer, generation requestGeneration: Int) {
        attempt = UUID(); let requestAttempt = attempt
        let asset = AVURLAsset(url: stream.url, options: ["AVURLAssetHTTPHeaderFieldsKey": stream.headers])
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 3
        looper = AVPlayerLooper(player: player, templateItem: item)
        currentItemObserver = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] player, _ in
            let item = player.currentItem
            Task { @MainActor [weak self] in
                guard let self, self.generation == requestGeneration, self.attempt == requestAttempt else { return }
                self.statusObserver = item?.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                    guard item.status == .failed else { return }
                    Task { @MainActor [weak self] in self?.failed(trailer, stream: stream, generation: requestGeneration, attempt: requestAttempt) }
                }
            }
        }
        looperObserver = looper?.observe(\.status, options: [.new]) { [weak self] looper, _ in
            guard looper.status == .failed else { return }
            Task { @MainActor [weak self] in self?.failed(trailer, stream: stream, generation: requestGeneration, attempt: requestAttempt) }
        }
        failureObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] notification in
            guard let item = notification.object as? AVPlayerItem else { return }
            Task { @MainActor [weak self] in
                guard let self, self.player.items().contains(where: { $0 === item }) else { return }
                self.failed(trailer, stream: stream, generation: requestGeneration, attempt: requestAttempt)
            }
        }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, self.generation == requestGeneration, self.attempt == requestAttempt else { return }
                if time.seconds > 0.05, self.player.currentItem?.status == .readyToPlay {
                    self.ready = true
                }
            }
        }
        player.play()
    }
    private func failed(_ trailer: TMDBMatch.Trailer, stream: DiscoverTrailerResolver.Stream, generation requestGeneration: Int, attempt requestAttempt: UUID) {
        guard generation == requestGeneration, attempt == requestAttempt, !retrying else { return }
        ready = false
        guard !retryUsed else {
            retry = Task { await DiscoverTrailerResolver.shared.invalidate(trailer, failedURL: stream.url) }
            return
        }
        retryUsed = true; retrying = true
        retry = Task { [weak self] in
            await DiscoverTrailerResolver.shared.invalidate(trailer, failedURL: stream.url)
            let replacement = await DiscoverTrailerResolver.shared.resolve(trailer)
            guard let self, self.generation == requestGeneration, !Task.isCancelled else { return }
            self.clearPlayer(); self.retrying = false
            if let replacement { self.install(replacement, trailer: trailer, generation: requestGeneration) }
        }
    }
    func stop() {
        generation += 1
        retry?.cancel(); retry = nil; retrying = false
        clearPlayer()
    }
    private func clearPlayer() {
        attempt = UUID()
        ready = false
        player.pause()
        if let observer { player.removeTimeObserver(observer); self.observer = nil }
        currentItemObserver = nil; statusObserver = nil; looperObserver = nil
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver); self.failureObserver = nil }
        looper?.disableLooping(); looper = nil
        player.removeAllItems()
    }
}

struct DiscoverTrailer: View {
    let trailer: TMDBMatch.Trailer
    /// Mac: the leading part of the frame that lies under the floating sidebar. It shows a mirrored, blurred copy of
    /// the video, as `backgroundExtensionEffect()` does for SwiftUI content, which can't reach this layer.
    var mirrorWidth: CGFloat = 0
    var readyChanged: (Bool) -> Void = { _ in }
    @State private var playback = DiscoverTrailerPlayback()
    var body: some View {
        WithPerceptionTracking {
            DiscoverTrailerLayer(player: playback.player, mirrorWidth: mirrorWidth)
                .opacity(playback.ready ? 1 : 0)
                .animation(.easeOut(duration: 0.4), value: playback.ready)
                .accessibilityHidden(true)
                .appOnChange(of: playback.ready) { _, ready in readyChanged(ready) }
                .task(id: trailer) { await playback.load(trailer) }
                .onDisappear { playback.stop() }
        }
    }
}

#if os(macOS)
private struct DiscoverTrailerLayer: NSViewRepresentable {
    let player: AVPlayer
    let mirrorWidth: CGFloat
    final class Host: NSView {
        let video = AVPlayerLayer()
        /// The same player again, flipped about the content's leading edge and blurred, under the sidebar.
        let mirror = AVPlayerLayer()
        private let videoClip = CALayer()
        private let mirrorClip = CALayer()
        var mirrorWidth: CGFloat = 0 { didSet { if mirrorWidth != oldValue { needsLayout = true } } }
        let fade = CAGradientLayer()
        /// AppKit owns a layer-backed view's own layer and drops a mask set on it, so the video and its fade sit in
        /// a sublayer. The view is flipped to match UIKit, so the fade runs to the bottom as on iOS.
        private let clip = CALayer()
        override var isFlipped: Bool { true }
        override init(frame: NSRect) {
            super.init(frame: frame); wantsLayer = true; layerUsesCoreImageFilters = true; layer?.addSublayer(clip)
            clip.addSublayer(mirrorClip); clip.addSublayer(videoClip); videoClip.addSublayer(video); mirrorClip.addSublayer(mirror)
            video.videoGravity = .resizeAspectFill; mirror.videoGravity = .resizeAspectFill
            clip.masksToBounds = true; videoClip.masksToBounds = true; mirrorClip.masksToBounds = true
            mirror.transform = CATransform3DMakeScale(-1, 1, 1)
            mirror.filters = [CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: 24])].compactMap { $0 }
            fade.startPoint = CGPoint(x: 0.5, y: 0); fade.endPoint = CGPoint(x: 0.5, y: 1)
            fade.colors = [1.0, 1.0, 0.85, 0.35, 0.0].map { NSColor.black.withAlphaComponent($0).cgColor }
            fade.locations = [0, 0.5, 0.7, 0.87, 1]; clip.mask = fade
        }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() {
            super.layout(); CATransaction.begin(); CATransaction.setDisableActions(true)
            clip.frame = bounds; fade.frame = bounds
            let edge = min(max(mirrorWidth, 0), bounds.width)
            let content = CGRect(x: edge, y: 0, width: bounds.width - edge, height: bounds.height)
            videoClip.frame = content
            let picture = CGRect(origin: .zero, size: content.size).insetBy(dx: -content.width * 0.1, dy: -content.height * 0.1)
            video.frame = picture
            mirrorClip.frame = CGRect(x: 0, y: 0, width: edge, height: bounds.height)
            mirrorClip.isHidden = edge <= 0
            // Reflect the picture about the content's leading edge (x = edge in the mirror clip's space).
            mirror.bounds = CGRect(origin: .zero, size: picture.size)
            mirror.position = CGPoint(x: edge - picture.midX, y: picture.midY)
            CATransaction.commit()
        }
    }
    func makeNSView(context: Context) -> Host {
        let view = Host(); view.video.player = player; view.mirror.player = player; view.mirrorWidth = mirrorWidth; return view
    }
    func updateNSView(_ view: Host, context: Context) {
        view.video.player = player; view.mirror.player = player; view.mirrorWidth = mirrorWidth
    }
    static func dismantleNSView(_ view: Host, coordinator: ()) { view.video.player = nil; view.mirror.player = nil }
}
#else
private struct DiscoverTrailerLayer: UIViewRepresentable {
    let player: AVPlayer
    var mirrorWidth: CGFloat = 0
    final class Host: UIView {
        let video = AVPlayerLayer()
        let fade = CAGradientLayer()
        override init(frame: CGRect) {
            super.init(frame: frame); layer.addSublayer(video); video.videoGravity = .resizeAspectFill
            fade.startPoint = CGPoint(x: 0.5, y: 0); fade.endPoint = CGPoint(x: 0.5, y: 1)
            fade.colors = [1.0, 1.0, 0.85, 0.35, 0.0].map { UIColor.black.withAlphaComponent($0).cgColor }
            fade.locations = [0, 0.5, 0.7, 0.87, 1]; layer.mask = fade
        }
        required init?(coder: NSCoder) { nil }
        override func layoutSubviews() {
            super.layoutSubviews(); CATransaction.begin(); CATransaction.setDisableActions(true)
            video.frame = bounds.insetBy(dx: -bounds.width * 0.1, dy: -bounds.height * 0.1); fade.frame = bounds
            CATransaction.commit()
        }
    }
    func makeUIView(context: Context) -> Host { let view = Host(); view.video.player = player; return view }
    func updateUIView(_ view: Host, context: Context) { view.video.player = player }
    static func dismantleUIView(_ view: Host, coordinator: ()) { view.video.player = nil }
}
#endif
