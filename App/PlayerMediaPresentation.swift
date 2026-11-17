#if os(iOS)
import SwiftUI
import Perception
import TVCore

/// Show artwork only after the current-title logo has actually decoded.
@MainActor @Perceptible final class PlayerTitleArtworkModel {
    enum Content {
        case hidden
        case logo(CGImage)
    }
    @PerceptionIgnored private let resolver: PlaybackTitleArtwork
    @PerceptionIgnored private let loader: @MainActor (URL) async -> CGImage?
    private var identity: String?
    private var matchKey: String?
    private var revision = UUID()
    private var image: CGImage?
    private var completed = false

    init(resolver: PlaybackTitleArtwork = .shared,
         loader: @escaping @MainActor (URL) async -> CGImage? = { await TMDBArtwork.load($0, maxPixels: 800) }) {
        self.resolver = resolver; self.loader = loader
    }

    func content(for identity: String, title: String) -> Content {
        if self.identity == identity, let image { return .logo(image) }
        return .hidden
    }

    /// Invalidate immediately so an in-flight image cannot reappear after a manual choice.
    func invalidateChoice(for key: String) -> Bool {
        guard key == matchKey else { return false }
        revision = UUID(); image = nil; completed = false
        return true
    }

    func load(_ request: PlaybackTitleArtwork.Request?, identity: String) async {
        if self.identity == identity, completed { return }
        let revision = UUID()
        self.identity = identity; self.revision = revision; matchKey = request?.matchKey
        image = nil; completed = false
        guard let request else { completed = true; return }
        do {
            let logo = try await resolver.logo(for: request)
            try Task.checkCancellation()
            guard self.identity == identity, self.revision == revision else { return }
            guard let logo else { completed = true; return }
            let decoded = await loader(logo)
            try Task.checkCancellation()
            guard self.identity == identity, self.revision == revision else { return }
            image = decoded; completed = true
        } catch {
            guard self.identity == identity, self.revision == revision else { return }
            completed = !(error is CancellationError) && !Task.isCancelled
        }
    }
}

/// The bottom-left artwork shows a decoded TMDB wordmark when available.
/// Its task belongs to this playing work, so a catalog scroll never initiates matching.
struct PlayerTitleLogo: View {
    let channel: Channel
    let compact: Bool
    @Environment(Store.self) private var store
    @State private var artwork = PlayerTitleArtworkModel()
    @State private var requestRevision = UUID()

    var body: some View {
        WithPerceptionTracking {
            let catalog = store.catalog(for: channel)
            let title = PlaybackTitleArtwork.displayTitle(catalog?.video.name ?? channel.historyContext?.videoName ?? channel.name,
                                                         fallback: L10n.text("Video title"))
            let identity = (catalog?.scope ?? channel.historyContext?.id ?? channel.id) + "|" + title + "|" + requestRevision.uuidString
            let box = compact ? CGSize(width: 150, height: 40) : CGSize(width: 220, height: 56)
            ZStack(alignment: .bottomLeading) {
                switch artwork.content(for: identity, title: title) {
                case .logo(let image):
                    let size = Self.fit(CGFloat(image.width) / CGFloat(max(image.height, 1)), in: box)
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                        .frame(width: size.width, height: size.height, alignment: .bottomLeading)
                case .hidden:
                    EmptyView()
                }
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.65), radius: 4, y: 1)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore).accessibilityLabel(title)
            .accessibilityHidden({ if case .hidden = artwork.content(for: identity, title: title) { return true }; return false }())
            .accessibilityIdentifier("player.titleArtwork")
            .task(id: identity) {
                // Title/episode recognition is performed once per work, outside playback redraws.
                let request = catalog.map {
                    PlaybackTitleArtwork.Request(video: $0.video, origin: $0.client.origin, sourceKey: $0.client.site.sourceKey,
                                                 siteKey: $0.client.site.key, siteName: $0.client.site.name, siteAPI: $0.client.site.api)
                }
                await artwork.load(request, identity: identity)
            }
            .onReceive(NotificationCenter.default.publisher(for: TMDBServiceSettings.changed)) { _ in requestRevision = UUID() }
            .onReceive(NotificationCenter.default.publisher(for: TMDBMatchStore.choiceChanged)) { notification in
                guard let key = notification.object as? String, artwork.invalidateChoice(for: key) else { return }
                requestRevision = UUID()
            }
        }
    }

    private static func fit(_ aspect: CGFloat, in box: CGSize) -> CGSize {
        let aspect = max(aspect, 0.5)
        return aspect >= box.width / box.height ? CGSize(width: box.width, height: box.width / aspect)
            : CGSize(width: box.height * aspect, height: box.height)
    }
}

/// Artwork is packaged with the app, so badge presentation never mixes in temporary
/// text labels while a network image is loading or unavailable.
struct PlayerMediaBadges: View {
    @AppStorage(LocalMediaBadgeStore.enabledKey) private var enabled = true
    @State private var selected = LocalMediaBadgeStore.load().active
    @State private var catalog = LocalMediaBadgeStore.load().active.rules
    let session: PlaybackSession
    let channel: Channel
    private var badges: [PlayerBadgeRules.Row] {
        let info = session.engine.playbackInfo
        let title = [channel.name, channel.historyContext?.videoName, channel.historyContext?.episodeName].compactMap { $0 }.joined(separator: " ")
        var overrides: [String: String] = [:]
        if info.width > 0, info.height > 0 {
            let edge = max(info.width, info.height)
            overrides["gr"] = edge >= 7000 ? "8K" : edge >= 3500 ? "2160p" : edge >= 2500 ? "1440p" : edge >= 1900 ? "1080p" : edge >= 1200 ? "720p" : "480p"
        }
        if let codec = session.engine.tracks.first(where: { $0.kind == .video && $0.selected })?.codec, !codec.isEmpty {
            overrides["video-codec"] = codec == "mpeg2video" ? "MPEG-2" : codec == "h266" ? "VVC" : codec
        } else if let codec = info.videoCodec { overrides["video-codec"] = PlaybackInfo.videoName(codec) }
        if let profile = info.dolbyVisionProfile { overrides["video-tech"] = "Dolby Vision P\(profile)" }
        else if let transfer = info.transferFunction, let range = PlaybackInfo.dynamicRange(transfer) { overrides["video-tech"] = range }
        if let fps = info.frameRate, fps > 0, fps.isFinite {
            let rate = [23.976, 29.97, 59.94, 119.88].first { abs($0 - fps) < 0.005 } ?? (fps * 100).rounded() / 100
            overrides["gfr"] = "\(rate)fps"
        }
        if let format = session.engine.tracks.first(where: { $0.kind == .audio && $0.selected })?.codec, !format.isEmpty {
            let codec = format.lowercased()
            var name = ["eac3":"DDP", "ac3":"Dolby Digital", "dts":"DTS"][codec] ?? codec
            if ["eac3", "truehd"].contains(codec), title.range(of: #"\batmos\b"#, options: [.regularExpression, .caseInsensitive]) != nil { name = "Dolby Atmos" }
            if codec == "dts" {
                if title.range(of: #"dts[\s._:-]*x\b"#, options: [.regularExpression, .caseInsensitive]) != nil { name = "DTS:X" }
                else if title.range(of: #"dts[\s._-]*hd[\s._-]*(?:hra|high)"#, options: [.regularExpression, .caseInsensitive]) != nil { name = "DTS-HD HRA" }
                else if title.range(of: #"dts[\s._-]*hd"#, options: [.regularExpression, .caseInsensitive]) != nil { name = "DTS-HD MA" }
            }
            overrides["audio-tech"] = name
        }
        if let channels = info.channels, channels > 0 { overrides["gc"] = [2:"2.0",6:"5.1",7:"6.1",8:"7.1"][channels] ?? "" }
        if let depth = session.engine.videoBitDepth, depth > 0 { overrides["bit-depth"] = "\(depth)bit" }
        return catalog?.matches(title: title, overrides: overrides) ?? []
    }
    var body: some View {
        WithPerceptionTracking {
            PlayerBadgeFlow(spacing: 7) {
                ForEach(enabled ? badges : []) { badge in
                    LocalMediaBadgeImage(badge: badge, builtin: selected.isBuiltin)
                }
            }
            .shadow(color: .black.opacity(0.6), radius: 3, y: 1)
            .accessibilityElement(children: .combine).accessibilityLabel("媒体规格")
            .accessibilityIdentifier("player.badges")
            .onReceive(NotificationCenter.default.publisher(for: LocalMediaBadgeStore.changed)) { _ in
                selected = LocalMediaBadgeStore.load().active; catalog = selected.rules
            }
        }
    }
}

private struct PlayerBadgeFlow: SwiftUI.Layout {
    let spacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(width: proposal.width ?? 520, subviews: subviews).0
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let points = arrangement(width: bounds.width, subviews: subviews).1
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + points[index].x, y: bounds.minY + points[index].y), proposal: .unspecified)
        }
    }
    private func arrangement(width: CGFloat, subviews: Subviews) -> (CGSize, [CGPoint]) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        var points: [CGPoint] = []
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + 5; rowHeight = 0 }
            points.append(CGPoint(x: x, y: y)); widest = max(widest, x + size.width)
            rowHeight = max(rowHeight, size.height); x += size.width + spacing
        }
        return (CGSize(width: min(width, widest), height: y + rowHeight), points)
    }
}

struct CompactPlayerInformationPanel: View {
    let session: PlaybackSession
    let channel: Channel
    @State private var copied: String?
    private var title: String { [channel.historyContext?.videoName ?? channel.name, channel.historyContext?.episodeName].compactMap { $0 }.joined(separator: " · ") }
    private var headers: String {
        guard let data = try? JSONSerialization.data(withJSONObject: session.currentPlaybackHeaders, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let result = String(data: data, encoding: .utf8) else { return "{}" }
        return result
    }
    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 16) {
                summary("标题", title)
                summary("ID", channel.historyContext?.episodeID ?? channel.id)
                let info = session.engine.playbackInfo
                summary("分辨率", info.width > 0 && info.height > 0 ? "\(info.width) × \(info.height)" : "探测中", copyable: false)
                field("URL", session.currentPlaybackURL?.absoluteString ?? "")
                field("Headers", headers)
                if let video = info.video { summary("视频", video, copyable: false) }
                if let audio = info.audio { summary("音频", audio, copyable: false) }
            }.font(.system(size: 12))
        }
    }
    private func summary(_ label: String, _ value: String, copyable: Bool = true) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
            Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if copyable { copyButton(label, value) }
        }
    }
    private func field(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(label).fontWeight(.semibold); Spacer(); copyButton(label, value) }
            Text(value.isEmpty ? "正在读取播放地址…" : value).font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
        }
    }
    private func copyButton(_ label: String, _ value: String) -> some View {
        Button { UIPasteboard.general.string = value; copied = label } label: {
            Image(systemName: copied == label ? "checkmark" : "doc.on.doc").playerControlTarget()
        }.buttonStyle(.plain).disabled(value.isEmpty).accessibilityLabel("复制 " + label)
    }
}
#endif
