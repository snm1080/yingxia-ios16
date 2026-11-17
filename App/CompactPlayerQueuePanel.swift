#if os(iOS)
import SwiftUI
import Perception
import TVCore

/// MacCat's queue: changing a line only browses it; choosing an episode starts that
/// exact source entry. Search, reverse order and ranges never change playback order.
struct CompactPlayerQueuePanel: View {
    let channel: Channel
    @Environment(Store.self) private var store
    @State private var tmdb = TMDBLookup()
    @State private var selectedFlag: String?
    @State private var query = ""
    @State private var descending = false
    @State private var group = 0
    @State private var locateRevision = 0
    @State private var loadedIdentity: String?
    @AppStorage("local.playback.queueView") private var viewMode = "tmdb"
    @AppStorage("local.playback.prefetchNext") private var prefetch = true
    private var playing: Channel { store.playing.flatMap { store.catalog(for: $0) != nil ? $0 : nil } ?? channel }
    private var lookupIdentity: String {
        guard let catalog = store.catalog(for: playing) else { return playing.id }
        return [TMDBServiceSettings.identity, catalog.scope, catalog.client.site.key, catalog.client.site.api, catalog.video.id].joined(separator: "|")
    }
    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 0) {
                if let catalog = store.catalog(for: playing) { queue(catalog) }
                else {
                    VStack(spacing: 12) { Image(systemName: "list.bullet.rectangle").font(.title2); Text("正在播放单个媒体") }
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    playbackSettings
                }

            }
            .task(id: lookupIdentity) { await lookup() }
        }
    }
    private var playbackSettings: some View {
        VStack(spacing: 0) {
            Toggle("播完自动播放下一集", isOn: Binding(get: { store.autoPlayNext }, set: { store.autoPlayNext = $0 })).padding(.vertical, 8)
            Toggle("预缓存下一集", isOn: $prefetch).padding(.vertical, 8)
        }.font(.system(size: 12)).toggleStyle(.switch).controlSize(.mini)
            .padding(.top, 8).overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1) }
            .padding(.horizontal, 16).padding(.bottom, 10)
    }
    private struct QueueSnapshot {
        let flags: [String]
        let flag: String
        let current: Episode?
        let episodes: [Episode]
        let visible: [Int]
        let hasMetadata: Bool
        let metadata: [Episode.ID: TMDBMatch.EpisodeInfo]
        let thumbnails: Bool
    }

    private func snapshot(_ catalog: PlaybackCatalog) -> QueueSnapshot {
        let flags = catalog.playlist.flags
        let current = playing.historyContext?.episode(in: catalog.video.episodes)
        let flag = selectedFlag.flatMap { flags.contains($0) ? $0 : nil } ?? current?.flag ?? flags.first ?? ""
        let episodes = catalog.video.episodes.filter { $0.flag == flag }
        let season = PlayerQueueFilter.season(flag) ?? PlayerQueueFilter.season(catalog.video.name)
        let visible = PlayerQueueFilter.visibleIndices(names: episodes.map(\.name), query: query, group: group,
                                                      descending: descending, defaultSeason: season)
        let hasMetadata = loadedIdentity == lookupIdentity && tmdb.details != nil
        let metadata: [Episode.ID: TMDBMatch.EpisodeInfo] = hasMetadata ? tmdb.episodes(episodes) : [:]
        return QueueSnapshot(flags: flags, flag: flag, current: current, episodes: episodes, visible: visible,
                             hasMetadata: hasMetadata, metadata: metadata, thumbnails: viewMode == "tmdb" && hasMetadata)
    }

    private func queue(_ catalog: PlaybackCatalog) -> some View {
        let value = snapshot(catalog)
        return ScrollViewReader { proxy in
            WithPerceptionTracking {
                queueScroll(value, catalog: catalog)
                    .onAppear { scrollToCurrent(value, proxy: proxy) }
                    .appOnChange(of: locateRevision) { _, _ in
                        Task { @MainActor in
                            await Task.yield()
                            withAnimation { scrollToCurrent(value, proxy: proxy) }
                        }
                    }
                    .appOnChange(of: descending) { _, _ in
                        if let index = value.visible.first { proxy.scrollTo(value.episodes[index].id, anchor: .top) }
                    }
                    .appOnChange(of: query) { _, next in if !next.isEmpty { group = 0 } }
            }
        }
    }

    private func scrollToCurrent(_ value: QueueSnapshot, proxy: ScrollViewProxy) {
        if let id = value.current?.id { proxy.scrollTo(id, anchor: .center) }
    }

    private func queueScroll(_ value: QueueSnapshot, catalog: PlaybackCatalog) -> some View {
        // One vertical scroller preserves usable episode space on short landscape screens.
        ScrollView {
            WithPerceptionTracking {
                VStack(alignment: .leading, spacing: 10) {
                    queueToolbar(value, catalog: catalog)
                    episodeGrid(value, catalog: catalog)
                    if value.visible.isEmpty {
                        Text(value.episodes.isEmpty ? "当前线路暂无剧集" : "没有匹配的剧集")
                            .foregroundStyle(.secondary).padding()
                    }
                    playbackSettings
                }.font(.system(size: 12))
            }
        }.scrollDismissesKeyboard(.interactively)
    }

    private func queueToolbar(_ value: QueueSnapshot, catalog: PlaybackCatalog) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if value.hasMetadata { viewModeControl(thumbnails: value.thumbnails) }
            HStack {
                Text("线路")
                Spacer()
                Text("\(value.episodes.count) 集").monospacedDigit()
            }.foregroundStyle(.secondary)
            lineChoices(value)
            queueSearch(value, catalog: catalog)
            resolvingStatus
        }.padding(.horizontal, 12).padding(.top, 12)
    }

    private func viewModeControl(thumbnails: Bool) -> some View {
        HStack {
            Text("显示模式").foregroundStyle(.secondary)
            Spacer()
            Button { viewMode = thumbnails ? "list" : "tmdb" } label: {
                Image(systemName: thumbnails ? "list.bullet" : "square.grid.2x2").playerControlTarget()
            }.buttonStyle(CompactPlayerControlStyle())
                .accessibilityLabel(thumbnails ? "切换为列表模式" : "切换为 TMDB 模式")
        }
    }

    private func lineChoices(_ value: QueueSnapshot) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(value.flags, id: \.self) { item in
                    Button { selectedFlag = item; group = 0 } label: {
                        Text(item.isEmpty ? "默认线路" : item).lineLimit(1).padding(.horizontal, 12).playerControlTarget()
                    }.buttonStyle(CompactPlayerControlStyle(selected: item == value.flag))
                        .accessibilityAddTraits(item == value.flag ? .isSelected : [])
                }
            }
        }.fixedSize(horizontal: false, vertical: true)
    }

    private func queueSearch(_ value: QueueSnapshot, catalog: PlaybackCatalog) -> some View {
        VStack(spacing: 8) {
          HStack(spacing: 6) {
            Button { descending.toggle() } label: { Text(descending ? "倒序" : "正序").playerControlTarget() }
                .buttonStyle(CompactPlayerControlStyle()).accessibilityLabel("剧集显示顺序")
                .accessibilityAddTraits(descending ? .isSelected : [])
            Button { locate(value, catalog: catalog) } label: {
                Image(systemName: "scope").playerControlTarget()
            }.buttonStyle(CompactPlayerControlStyle()).disabled(value.current == nil).accessibilityLabel("定位到当前")
            TextField("搜索当前线路剧集…", text: $query).textFieldStyle(LocalGlassTextFieldStyle())
                .frame(minWidth: 60)
                .autocorrectionDisabled().textInputAutocapitalization(.never).accessibilityLabel("搜索剧集")
          }
          if value.episodes.count > 100 { rangePicker(count: value.episodes.count) }
        }
    }

    private func locate(_ value: QueueSnapshot, catalog: PlaybackCatalog) {
        selectedFlag = value.current?.flag
        query = ""
        let playingItems = catalog.video.episodes.filter { $0.flag == value.current?.flag }
        let index = playingItems.firstIndex { $0.id == value.current?.id } ?? 0
        group = playingItems.count > 100 ? index / 100 + 1 : 0
        locateRevision += 1
    }

    private func rangePicker(count: Int) -> some View {
        LocalGlassChoicePicker(title: "剧集区间", selection: Binding(get: { group }, set: { group = $0; query = "" }),
                               options: [.init(0, "全部区间")] + (1...((count + 99) / 100)).map { index in
                                   .init(index, "\((index - 1) * 100 + 1)-\(min(count, index * 100)) 集")
                               })
    }

    private var resolvingStatus: some View {
        WithPerceptionTracking {
            if let pending = store.resolvingEpisode { ProgressView("正在打开 " + pending.name).font(.caption) }
            if let error = store.episodeError { Text(error).foregroundStyle(.orange).font(.caption) }
        }
    }

    private func episodeGrid(_ value: QueueSnapshot, catalog: PlaybackCatalog) -> some View {
        let columns = value.thumbnails ? [GridItem(.flexible()), GridItem(.flexible())] : [GridItem(.flexible())]
        return LazyVGrid(columns: columns, spacing: value.thumbnails ? 12 : 6) {
            ForEach(value.visible, id: \.self) { index in
                WithPerceptionTracking { episodeButton(index: index, value: value, catalog: catalog) }
            }
        }.padding(.horizontal, 12).padding(.bottom, 12)
    }

    private func episodeButton(index: Int, value: QueueSnapshot, catalog: PlaybackCatalog) -> some View {
        let episode = value.episodes[index]
        let active = episode.id == value.current?.id && value.flag == value.current?.flag
        return Button { if !active { store.selectEpisode(episode, from: playing) } } label: {
            if value.thumbnails {
                thumbnail(episode, info: value.metadata[episode.id], active: active,
                          fallback: catalog.video.poster, headers: catalog.video.posterHeaders)
            } else { episodeListRow(episode, index: index, active: active) }
        }.buttonStyle(CompactPlayerControlStyle(selected: active, inset: false))
            .disabled(store.resolvingEpisode != nil).id(episode.id)
            .accessibilityLabel("播放 " + episode.name).accessibilityAddTraits(active ? .isSelected : [])
    }

    private func episodeListRow(_ episode: Episode, index: Int, active: Bool) -> some View {
        HStack(spacing: 10) {
            Text(String(format: "%02d", PlayerQueueFilter.number(episode.name, query: false) ?? index + 1))
                .foregroundStyle(.secondary).frame(minWidth: 22)
            Text(episode.name).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            if active { Image(systemName: "checkmark") }
        }.padding(.horizontal, 10).frame(minHeight: 44).contentShape(Rectangle())
    }

    private func thumbnail(_ episode: Episode, info: TMDBMatch.EpisodeInfo?, active: Bool, fallback: URL?, headers: [String: String]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.primary.opacity(0.05)).aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        LocalCatalogEpisodeArtwork(primary: info?.still ?? tmdb.details?.backdrop, fallback: fallback, headers: headers)
                    }.clipped()
                HStack(alignment: .top, spacing: 4) {
                    if let number = info?.number ?? PlayerQueueFilter.number(episode.name, query: false) { badge("第 \(number) 集") }
                    Spacer(minLength: 0)
                    if let detail = EpisodeFileInfo.summary(episode.name), let size = detail.components(separatedBy: " · ").last, size.hasSuffix("G") || size.hasSuffix("M") || size.hasSuffix("T") { badge(size) }
                }.padding(6)
                if active { badge("✓ 正在播放").frame(maxHeight: .infinity, alignment: .bottom).padding(6) }
            }
            Text(info?.name.isEmpty == false ? info!.name : episode.name).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.vertical, 9)
        }.clipShape(RoundedRectangle(cornerRadius: 7))
    }
    private func badge(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.white).lineLimit(1)
            .padding(.horizontal, 5).padding(.vertical, 3).background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 4))
    }
    private func lookup() async {
        let identity = lookupIdentity
        let lookup = TMDBLookup(); tmdb = lookup; loadedIdentity = identity
        guard let catalog = store.catalog(for: playing), TMDBLookup.applies(to: catalog.client.site) else { lookup.skip(); return }
        let key = TMDBMatchStore.key(source: catalog.client.site.key, video: catalog.video.id)
        let request = TMDBMatch.Request(video: catalog.video, listVideo: catalog.video, source: .init(key: catalog.client.site.key, name: catalog.client.site.name))
        guard !TMDBMatch.labeledNotOnTMDB(request) else { lookup.skip(); return }
        await lookup.run(key: key, request: request)
    }
}
#endif
