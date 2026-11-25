import SwiftUI
import Perception
import TVCore

/// Music: search songs, albums or playlists by name (and artist), and play from the best channel
/// found. With no search, the page offers to continue where listening stopped, then shelves of
/// charts, playlists and new albums as Discover has for video, then what played recently.
struct MusicView: View {
    @Environment(Store.self) private var store
    @State private var query = ""
    /// The query Return was pressed for: its direct hit plays once the search knows it. Typing
    /// something else clears it.
    @State private var autoPlayQuery: String?
    @State private var showsSettings = false
    @State private var searchEndVisible = false
    @State private var nextPageTask: Task<Void, Never>?
    #if os(iOS)
    @Environment(\.isLocalPageActive) private var isLocalPageActive
    #endif
    private var paginationActive: Bool {
        #if os(iOS)
        isLocalPageActive
        #else
        true
        #endif
    }

    var body: some View {
        WithPerceptionTracking { presentationPage }
    }

    private var scrollingPage: some View {
        WithPerceptionTracking {
            let search = store.musicSearch
            ScrollView {
                WithPerceptionTracking {
                    LazyVStack(alignment: .leading, spacing: MusicLayout.rowSpacing) {
                        WithPerceptionTracking {
                            #if os(tvOS)
                            let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !typed.isEmpty, typed != search.query {
                                SearchQueryButton(query: typed) { search.search(typed, immediately: true) }
                                    .padding(.bottom, 12)
                            } else if typed.isEmpty {
                                MusicNowPlayingButton()
                            }
                            #endif
                            #if !os(macOS)
                            if !search.query.isEmpty { kinds(search) }
                            #endif
                            if !search.query.isEmpty { filters(search) }
                            content(search)
                            paginationFooter(search)
                        }
                    }
                    .glassRowInsets()
                    .pageContainer()
                }
            }
            .screenBackdrop()
        }
    }

    @ViewBuilder private func paginationFooter(_ search: MusicSearchModel) -> some View {
        if !search.query.isEmpty && (search.canLoadMore || search.loadingMore) {
            Button {
                loadNextPage(search, explicitly: true)
            } label: {
                HStack(spacing: 8) {
                    if search.loadingMore { ProgressView() }
                    Text(search.loadingMore ? "正在加载更多…" : "加载更多")
                }.frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain).disabled(search.loadingMore || search.busy)
            .accessibilityIdentifier("music.search.loadMore")
            .onScrolledIntoView(threshold: 0.2) { visible in
                searchEndVisible = visible
                loadNextPage(search)
            }
            .id("music.search.tail|" + search.kind.rawValue + "|" + search.query)
        }
    }

    private var searchPage: some View {
        WithPerceptionTracking {
            let search = store.musicSearch
            scrollingPage
            .catalogSearchable(text: $query, prompt: L10n.text("Song, album or playlist"))
            .appOnChange(of: query) { _, text in
                if text.trimmingCharacters(in: .whitespacesAndNewlines) != autoPlayQuery { autoPlayQuery = nil }
                #if os(tvOS)
                // As in Global Search: typing only edits the query, and results change when it is
                // submitted. Results replaced under the keyboard took focus away from the letters.
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { search.clear() }
                #else
                search.search(text, kind: Self.searchKind)
                #endif
            }
            .onSubmit(of: .search) {
                autoPlayQuery = (search.kind == .songs || search.kind == .top) && search.filter.isEmpty ? query.trimmingCharacters(in: .whitespacesAndNewlines) : nil
                search.search(query, kind: Self.searchKind, immediately: true); playDirectHitIfReady()
            }
            .appOnChange(of: search.busy) {
                playDirectHitIfReady()
                if !search.busy { loadNextPage(search) }
            }
            .appOnChange(of: search.kind) { autoPlayQuery = nil }
            .appOnChange(of: search.filter) { autoPlayQuery = nil }
        }
    }

    private var paginationPage: some View {
        WithPerceptionTracking {
            let search = store.musicSearch
            searchPage
            .appOnChange(of: search.query) { _, _ in nextPageTask?.cancel(); searchEndVisible = false }
            .appOnChange(of: search.loadingMore) { _, loading in
                if !loading { loadNextPage(search) }
            }
            #if os(iOS)
            .appOnChange(of: isLocalPageActive) { _, active in
                if active { loadNextPage(search) }
                // Retained tabs keep the same measured tail. Its visibility
                // callback need not fire again when only tab opacity changes.
                else { nextPageTask?.cancel() }
            }
            #endif
            .onDisappear { nextPageTask?.cancel(); nextPageTask = nil; searchEndVisible = false }
        }
    }

    private var presentationPage: some View {
        WithPerceptionTracking {
            let search = store.musicSearch
            paginationPage
            .musicPlayerInset()
            #if os(tvOS)
            .onPlayPauseCommand { store.music.toggle() }
            #endif
            // The shelves load the first time the page shows with nothing searched, not at launch.
            .task(id: search.query.isEmpty) { if search.query.isEmpty { await store.musicBrowse.load() } }
            .tabTitle(L10n.text("Music"))
            #if !os(tvOS)
            .toolbar { WithPerceptionTracking {

                    Button { showsSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel(L10n.text("Music Settings"))

             }}
            #endif
            #if os(tvOS)
            .fullScreenCover(isPresented: $showsSettings) { WithPerceptionTracking { MusicSettingsView() } }
            #else
            .sheet(isPresented: $showsSettings) { WithPerceptionTracking { MusicSettingsView() } }
            #endif
            .task {
                if query.isEmpty, !search.query.isEmpty { query = search.query }
                if let kind = Self.searchKind, search.kind != kind { search.search(search.query, kind: kind) }
            }
        }
    }

    /// Apple TV leads with All, its results in rows; a phone or iPad has only the kinds.
    private static var chips: [MusicSearchKind] {
        #if os(tvOS)
        [.top] + MusicSearchKind.filters
        #else
        MusicSearchKind.filters
        #endif
    }

    /// The Mac shows every kind at once, in rows, with no chips; elsewhere the chips choose one.
    private static var searchKind: MusicSearchKind? {
        #if os(macOS)
        .top
        #else
        nil
        #endif
    }

    private func playDirectHitIfReady() {
        let search = store.musicSearch
        guard let wanted = autoPlayQuery, wanted == search.query, !search.busy,
              search.kind == .songs || search.kind == .top, search.filter.isEmpty else { return }
        autoPlayQuery = nil
        let hit = search.directHit
        if let hit, store.music.track?.id != hit.id { playResults(from: hit) }
    }

    private func kinds(_ search: MusicSearchModel) -> some View {
        ChipRow {
            GlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(Self.chips, id: \.self) { kind in
                        WithPerceptionTracking {
                            Chip(title: kind.name, selected: search.kind == kind) {
                                autoPlayQuery = nil
                                search.search(query, kind: kind, immediately: true)
                            }
                        }
                    }
                }
            }.padding(.vertical, 4)
        }
        .padding(.bottom, 8)
        .tvFocusSection()
    }

    @ViewBuilder private func filters(_ search: MusicSearchModel) -> some View {
        WithPerceptionTracking {
            if !MusicSearchFilter.facets(for: search.kind).isEmpty {
                ChipRow {
                    WithPerceptionTracking {
                        HStack(spacing: 8) { MusicFilterMenus(search: search) { autoPlayQuery = nil } }
                            .padding(.vertical, 4)
                    }
                }
                .padding(.bottom, 8)
                .tvFocusSection()
            }
        }
    }

    @ViewBuilder private func content(_ search: MusicSearchModel) -> some View {
        if search.query.isEmpty {
            MusicHome { showsSettings = true }
        } else if search.results.isEmpty && search.collections.isEmpty && search.busy {
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 80)
        } else if search.failed {
            ErrorStateCard(title: L10n.text("Unable to Search Music"), message: L10n.text("Check your network connection and try again."),
                           details: failureDetails(search), retry: { search.search(query, immediately: true) }, busy: search.busy)
                .padding(.vertical, 24).tvFocusSection()
        } else if search.filteredOut {
            AppContentUnavailableView {
                WithPerceptionTracking { Label(L10n.text("No Matches"), systemImage: "line.3.horizontal.decrease") }
            } description: {
                WithPerceptionTracking { Text(L10n.text("No results match these filters. Try changing or clearing the filters.")) }
            } actions: {
                WithPerceptionTracking {
                    Button(L10n.text("Reset Filters")) {
                        autoPlayQuery = nil
                        search.setFilter(MusicSearchFilter())
                    }.controlButton()
                }
            }
            .padding(.vertical, 60)
        } else if search.empty {
            AppContentUnavailableView(L10n.text("No Matching Songs"), systemImage: "music.note",
                                   description: Text(L10n.text("Try the song's full name, or add the artist.")))
                .frame(maxWidth: .infinity).padding(.vertical, 60)
        } else {
            ForEach(search.failures.keys.sorted { $0.rawValue < $1.rawValue }, id: \.self) { platform in
                WithPerceptionTracking {
                    StatusNotice(text: L10n.text("%@ didn't answer, so these results are from the other catalog.", platform.name))
                        .padding(.bottom, 10)
                }
            }
            if search.kind == .top {
                #if os(macOS) || os(tvOS)
                MusicTopResults(search: search) { playResults(from: $0) }
                #endif
            } else if search.kind == .songs || search.kind == .artists {
                ForEach(search.results) { track in WithPerceptionTracking { MusicTrackRow(track: track) { playResults(from: track) } } }
            } else {
                ForEach(search.collections) { collection in WithPerceptionTracking { MusicCollectionRow(collection: collection) } }
            }
        }
    }

    /// Only the visible result tail requests another page; retained tabs stay idle.
    private func loadNextPage(_ search: MusicSearchModel, explicitly: Bool = false) {
        guard paginationActive, explicitly || searchEndVisible,
              !search.busy, !search.loadingMore, search.canLoadMore else { return }
        nextPageTask?.cancel()
        nextPageTask = Task { await search.loadMore() }
    }

    /// A song from the results plays with the results after it queued, so the next one follows.
    private func playResults(from track: MusicTrack) {
        let results = store.musicSearch.results
        guard let index = results.firstIndex(of: track) else { store.music.play(track); return }
        store.music.play(MusicQueue(tracks: results, start: index))
    }

    private func failureDetails(_ search: MusicSearchModel) -> String {
        search.failures.map { "\($0.key.name): \($0.value.localizedDescription) (\($0.value.detail))" }.sorted().joined(separator: "\n")
    }
}

/// Facets follow the kind chips; the active choice remains visible and can be cleared.
private struct MusicFilterMenus: View {
    let search: MusicSearchModel
    let didChange: () -> Void

    var body: some View {
        WithPerceptionTracking {
            let filter = search.filter
            ForEach(MusicSearchFilter.facets(for: search.kind), id: \.self) { facet in
                WithPerceptionTracking {
                    switch facet {
                    case .decade: menu("decade", L10n.text("Year"), filter.decade, MusicDecade.allCases, \.name) { $0.decade = $1 }
                    case .genre: menu("genre", L10n.text("Genre"), filter.genre, MusicGenre.allCases, \.name) { $0.genre = $1 }
                    case .language: menu("language", L10n.text("Language"), filter.language, MusicLanguage.allCases, \.name) { $0.language = $1 }
                    }
                }
            }
            if !filter.isEmpty {
                Button {
                    didChange()
                    search.setFilter(MusicSearchFilter())
                } label: {
                    WithPerceptionTracking {
                        #if os(tvOS)
                        Label(L10n.text("Reset Filters"), systemImage: "xmark")
                        #else
                        Image(systemName: "xmark").frame(width: 38, height: 38).glassSurface(.regular, in: Circle()).iosTouchTarget()
                        #endif
                    }
                }
                #if os(tvOS)
                .buttonStyle(DiscoverTVChipStyle(active: false))
                #else
                .buttonStyle(.plain)
                #endif
                .accessibilityLabel(L10n.text("Reset Filters")).accessibilityIdentifier("music.filter.reset")
            }
        }
    }

    private func menu<Value: Hashable>(_ id: String, _ title: String, _ current: Value?, _ values: [Value], _ name: @escaping (Value) -> String,
                                       set: @escaping (inout MusicSearchFilter, Value?) -> Void) -> some View {
        let choose = { (value: Value?) in
            didChange()
            var next = search.filter
            set(&next, value == current ? nil : value)
            search.setFilter(next)
        }
        return Menu {
            WithPerceptionTracking {
                Button { choose(nil) } label: { WithPerceptionTracking { checked(L10n.text("Any"), current == nil) } }
                ForEach(values, id: \.self) { value in
                    WithPerceptionTracking {
                        Button { choose(value) } label: { WithPerceptionTracking { checked(name(value), current == value) } }
                    }
                }
            }
        } label: {
            WithPerceptionTracking {
                #if os(tvOS)
                Text(current.map(name) ?? title)
                #else
                FilterChipLabel(title: current.map(name) ?? title, open: current != nil)
                #endif
            }
        }
        #if os(tvOS)
        .menuStyle(.button).buttonStyle(DiscoverTVChipStyle(active: current != nil))
        #else
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        #endif
        .accessibilityIdentifier("music.filter." + id)
    }

    @ViewBuilder private func checked(_ text: String, _ on: Bool) -> some View {
        if on { Label(text, systemImage: "checkmark") } else { Text(text) }
    }
}

enum MusicLayout {
    #if os(tvOS)
    static let rowSpacing: CGFloat = 8, art: CGFloat = 76, gap: CGFloat = 22, header: CGFloat = 260
    #else
    static let rowSpacing: CGFloat = 2, art: CGFloat = 48, gap: CGFloat = 14, header: CGFloat = 150
    #endif
}

/// The Music page with nothing searched: continue listening, shelves to browse, and what played recently.
private struct MusicHome: View {
    @Environment(Store.self) private var store
    let openSettings: () -> Void

    var body: some View {
        WithPerceptionTracking {
            let library = store.music.library
            let browse = store.musicBrowse
            let resumable = store.music.track == nil ? library.resumePoint : nil
            if let point = resumable, let track = point.queue.current {
                MusicContinueCard(point: point, track: track).padding(.bottom, 20)
            }
            let liked = store.favorites.musicTracks.count
            MusicLikedLink(count: liked).padding(.bottom, 12)
            RouteLink { MusicFavoriteCollectionsView() } label: {
                HStack(spacing: MusicLayout.gap) {
                    Image(systemName: "music.note.list").font(.title2).foregroundStyle(Brand.accent)
                        .frame(width: MusicLayout.art, height: MusicLayout.art)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("我的歌单").font(.system(size: 19, weight: .semibold))
                        Text("收藏的歌单与专辑 · \(library.favoriteCollections.count)").font(.system(size: 17)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }.padding(.vertical, 6).contentShape(Rectangle())
            }.glassRow().padding(.bottom, 20)
            let downloads = !MusicDownloadLibrary.shared.items.isEmpty
            if downloads { MusicDownloadsLink().padding(.bottom, 20) }
            if !browse.sections.isEmpty {
                MusicBrowseShelves(sections: browse.sections).padding(.bottom, 28)
            } else if browse.loading {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 60)
            }
            if browse.incomplete && !browse.loading {
                Button { Task { await browse.load() } } label: {
                    Label(L10n.text("Some lists couldn't load. Try again."), systemImage: "arrow.clockwise")
                        #if !os(tvOS)
                        .font(.system(size: 17)).frame(maxWidth: .infinity).padding(.vertical, 8)
                        #endif
                }
                #if os(tvOS)
                .controlButton().frame(maxWidth: .infinity)
                #else
                .buttonStyle(.plain)
                #endif
                .padding(.bottom, 20)
            }
            if !library.history.isEmpty {
                HStack {
                    SectionHeader(title: "最近聆听 · 20首")
                    Spacer()
                    Button(L10n.text("Clear")) { library.clearHistory() }.controlButton()
                }
                .padding(.bottom, 8)
                .tvFocusSection()
                ForEach(library.history.prefix(MusicLibrary.historyLimit)) { entry in
                    WithPerceptionTracking {
                        if let collection = entry.collection {
                            MusicCollectionRow(collection: collection)
                        } else if let track = entry.track {
                            MusicTrackRow(track: track) { store.music.play(track) }
                        }
                    }
                }
            } else if resumable == nil && !downloads && browse.sections.isEmpty && !browse.loading {
                EmptyPage(symbol: "music.note", title: L10n.text("Search for a Song"),
                          message: L10n.text("Type a song's name, or its name and the artist. Yingxia finds the recording and plays it from the best channel available, lossless first."),
                          action: L10n.text("Music Settings"), actionSymbol: "slider.horizontal.3", perform: openSettings)
                    .frame(minHeight: 420)
            }
        }
    }
}

private struct MusicContinueCard: View {
    @Environment(Store.self) private var store
    let point: MusicResumePoint
    let track: MusicTrack

    var body: some View {
        WithPerceptionTracking {
            Button { store.music.resume() } label: {
                HStack(spacing: MusicLayout.gap) {
                    MusicArtwork(url: track.artwork, size: MusicLayout.art * 1.4)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.text("Continue Playing")).font(.system(size: 14, weight: .semibold)).foregroundStyle(Brand.accent)
                        Text(track.title).font(.system(size: 19, weight: .semibold)).lineLimit(1)
                        Text([track.artistLine, point.queue.source, L10n.text("Stopped at %@", MusicTime.text(point.position))]
                            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: 17)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "play.circle.fill").font(.system(size: MusicLayout.art * 0.6)).foregroundStyle(Brand.accent)
                }
                .padding(14)
                .contentPanel(cornerRadius: 20)
                .contentShape(Rectangle())
            }
            .panelCardButton(cornerRadius: 20)
        }
    }
}

struct MusicTrackRow: View {
    @Environment(Store.self) private var store
    let track: MusicTrack
    /// Its place in an album or playlist, shown instead of the cover.
    var number: Int?
    /// Off when a heart beside the row removes the favorite, so the row does not show a second heart.
    var showsFavoriteMark = true
    let action: () -> Void

    var body: some View {
        WithPerceptionTracking {
            let current = store.music.track?.id == track.id
            Button(action: action) {
                HStack(spacing: MusicLayout.gap) {
                    if let number {
                        Text("\(number)").font(.system(size: 17)).monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: MusicLayout.art * 0.6, alignment: .trailing)
                    } else {
                        MusicArtwork(url: track.artwork, size: MusicLayout.art)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title).font(.system(size: 19, weight: .semibold)).lineLimit(1)
                            .foregroundStyle(current ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(.primary))
                        Text([track.artistLine, number == nil ? track.album : nil].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: 17)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    ForEach(track.tags.sorted(), id: \.self) { tag in WithPerceptionTracking { Pill(text: tag.name) } }
                    if current { MusicActivityMark() }
                    // A slot for the download state on every row, saved or not, and lengths at least as wide
                    // as "00:00", trailing: the marks and the lengths each stay in a column.
                    Group {
                        if let saved = MusicDownloadLibrary.shared.item(for: track) { DownloadState(status: saved.status, fraction: saved.fraction) }
                    }
                    .frame(width: DownloadState.size * 1.2)
                    if showsFavoriteMark, store.favorites.contains(.music(track)) {
                        Image(systemName: "heart.fill")
                            .font(.system(size: DownloadState.size, weight: .semibold))
                            .foregroundStyle(Brand.rose)
                            .accessibilityHidden(true)
                    }
                    if let duration = track.duration {
                        ZStack(alignment: .trailing) {
                            Text(verbatim: "00:00").hidden()
                            Text(MusicTime.text(duration))
                        }
                        .font(.system(size: 17)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, number == nil ? 6 : 10)
                .contentShape(Rectangle())
            }
            .glassRow()
            // On Apple TV, a long press.
            .contextMenu {
                WithPerceptionTracking {
                    FavoriteMenuButton(item: .music(track), name: track.title)
                    Button { store.music.playNext([track]) } label: { Label(L10n.text("Play Next"), systemImage: "text.line.first.and.arrowtriangle.forward") }
                    Button { store.music.addToUpNext([track]) } label: { Label(L10n.text("Add to Up Next"), systemImage: "text.line.last.and.arrowtriangle.forward") }
                    Divider()
                    MusicDownloadMenuItems(tracks: [track])
                }
            }
            .accessibilityLabel(Text([track.title, track.artistLine].joined(separator: ", ")))
        }
    }
}

private struct MusicCollectionRow: View {
    let collection: MusicCollection

    var body: some View {
        WithPerceptionTracking {
            RouteLink {
                WithPerceptionTracking {
                    MusicCollectionView(collection: collection)
                }
            } label: {
                WithPerceptionTracking {
                    HStack(spacing: MusicLayout.gap) {
                        MusicArtwork(url: collection.artwork, size: MusicLayout.art, symbol: collection.kind == .album ? "square.stack" : "music.note.list")
                        VStack(alignment: .leading, spacing: 3) {
                            Text(collection.title).font(.system(size: 19, weight: .semibold)).lineLimit(1).foregroundStyle(.primary)
                            Text(MusicCollectionView.details(collection)).font(.system(size: 17)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right").font(.subheadline.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
            }
            .glassRow()
        }
    }
}

/// An album or playlist: its tracks, Play and Shuffle. Playing a track queues the whole list from it.
struct MusicCollectionView: View {
    let collection: MusicCollection
    @Environment(Store.self) private var store
    @State private var tracks: [MusicTrack] = []
    @State private var loading = false
    @State private var error: String?

    static func details(_ collection: MusicCollection) -> String {
        [collection.subtitle, collection.trackCount.map { L10n.text("%lld songs", $0) }, collection.year, collection.platform.name]
            .compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        WithPerceptionTracking {
            ScrollView {
                WithPerceptionTracking {
                    LazyVStack(alignment: .leading, spacing: MusicLayout.rowSpacing) {
                        WithPerceptionTracking {
                            #if os(tvOS)
                            MusicNowPlayingButton()
                            #endif
                            #if os(macOS)
                            MusicCollectionHeader(collection: collection, tracks: tracks).padding(.bottom, 28)
                            #else
                            header.padding(.bottom, 24)
                            #endif
                            if loading && tracks.isEmpty { ProgressView().frame(maxWidth: .infinity).padding(.vertical, 60) }
                            if let error {
                                ErrorStateCard(title: L10n.text("Unable to Load Songs"), message: L10n.text("Check your network connection and try again."),
                                               details: error, retry: { Task { await load() } }, busy: loading)
                                    .padding(.vertical, 24).tvFocusSection()
                            }
                            #if os(macOS)
                            MusicSongTable(tracks: tracks, numbered: collection.kind == .album) {
                                store.music.play(MusicQueue(tracks: tracks, start: $0, collection: collection))
                            }
                            #else
                            ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                                WithPerceptionTracking {
                                    MusicTrackRow(track: track, number: index + 1) {
                                        store.music.play(MusicQueue(tracks: tracks, start: index, collection: collection))
                                    }
                                }
                            }
                            #endif
                        }
                    }
                    .glassRowInsets()
                    .pageContainer()
                }
            }
            .screenBackdrop()
            .screenTitle(collection.title)
            #if os(macOS)
            // The header already names it in large type.
            .toolbar(removing: .title)
            #endif
            .musicPlayerInset()
            #if os(tvOS)
            .onPlayPauseCommand { store.music.toggle() }
            #endif
            .task {
                if tracks.isEmpty { await load() }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: MusicLayout.gap * 1.4) {
                MusicArtwork(url: collection.artwork, size: MusicLayout.header, symbol: collection.kind == .album ? "square.stack" : "music.note.list")
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text(collection.kind == .album ? "Album" : "Playlist")).font(.system(size: 14, weight: .semibold)).foregroundStyle(Brand.accent)
                    Text(collection.title).font(.system(size: 24, weight: .bold)).lineLimit(2)
                    Text(Self.details(collection)).font(.system(size: 17)).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            Button { store.music.library.toggleFavorite(collection) } label: {
                Label(store.music.library.isFavorite(collection) ? "已收藏到我的歌单" : "收藏到我的歌单",
                      systemImage: store.music.library.isFavorite(collection) ? "heart.fill" : "heart")
            }.controlButton()
            HStack(spacing: 10) {
                    Button { store.music.play(MusicQueue(tracks: tracks, collection: collection)) } label: {
                        Label(L10n.text("Play"), systemImage: "play.fill")
                    }
                    .controlButton(prominent: true)
                    Button { store.music.play(MusicQueue.shuffled(tracks, collection: collection)) } label: {
                        Label(L10n.text("Shuffle"), systemImage: "shuffle")
                    }
                    .controlButton()
                    MusicDownloadButton(tracks: tracks, collection: collection).controlButton()
            }
            .fixedSize()
            .disabled(tracks.isEmpty)
        }
        .tvFocusSection()
    }

    private func load() async {
        guard let source = store.musicSearch.source(for: collection.platform) else { return }
        loading = true; error = nil
        defer { loading = false }
        do { tracks = try await source.tracks(of: collection) }
        catch { self.error = MusicProviderError(error).localizedDescription + " (" + MusicProviderError(error).detail + ")" }
    }
}

/// The way to liked songs, at the top of the Music page: every song saved with Like, played as one list.
struct MusicLikedLink: View {
    let count: Int

    var body: some View {
        WithPerceptionTracking {
            RouteLink { WithPerceptionTracking { MusicLikedView() } } label: {
                WithPerceptionTracking {
                    HStack(spacing: MusicLayout.gap) {
                        #if os(iOS)
                        SectionGlyph(section: .favorites, size: MusicLayout.art)
                        #else
                        Image(systemName: AppSection.favorites.icon)
                            .font(.system(size: MusicLayout.art * 0.46, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: MusicLayout.art, height: MusicLayout.art)
                            .background(Brand.rose.gradient, in: RoundedRectangle(cornerRadius: MusicLayout.art * 0.3, style: .continuous))
                            .accessibilityHidden(true)
                        #endif
                        VStack(alignment: .leading, spacing: 3) {
                            Text(MusicLikedView.title).font(.system(size: 19, weight: .semibold)).lineLimit(1).foregroundStyle(.primary)
                            Text(L10n.text("%lld songs", count)).font(.system(size: 17)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right").font(.subheadline.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
            }
            .glassRow()
        }
    }
}

/// The songs saved with Like, newest first. Play, Shuffle and Add to Up Next treat them as one list,
/// so liking songs is all it takes to build a playlist.
struct MusicLikedView: View {
    @Environment(Store.self) private var store

    static var title: String { "我的音乐" }

    var body: some View {
        WithPerceptionTracking {
            let tracks = store.favorites.musicTracks
            ScrollView {
                WithPerceptionTracking {
                    LazyVStack(alignment: .leading, spacing: MusicLayout.rowSpacing) {
                        WithPerceptionTracking {
                            header(tracks).padding(.bottom, 20)
                            if tracks.isEmpty {
                                AppContentUnavailableView(L10n.text("No Liked Songs"), systemImage: "heart",
                                                       description: Text(L10n.text("Like a song from its menu, and it waits here, ready to play as one list.")))
                                    .frame(maxWidth: .infinity).padding(.vertical, 60)
                            }
                            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                                WithPerceptionTracking {
                                    HStack(spacing: 10) {
                                        MusicTrackRow(track: track, showsFavoriteMark: false) {
                                            store.music.play(MusicQueue(tracks: tracks, start: index, source: Self.title))
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        // The row's own menu has Unlike, which is how the remote removes it.
                                        #if !os(tvOS)
                                        FavoriteHeartButton(item: .music(track), name: track.title)
                                            .fixedSize()
                                        #endif
                                    }
                                }
                            }
                        }
                    }
                    .glassRowInsets()
                    .pageContainer()
                }
            }
            .screenBackdrop()
            .screenTitle(Self.title)
            #if os(macOS)
            // The header names it in large type, as on the other Music pages.
            .toolbar(removing: .title)
            #endif
            .musicPlayerInset()
            #if os(tvOS)
            .onPlayPauseCommand { store.music.toggle() }
            #endif
        }
    }

    private func header(_ tracks: [MusicTrack]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            #if os(macOS)
            Text(Self.title).font(.largeTitle.weight(.bold))
            #endif
            Text(L10n.text("%lld songs", tracks.count))
                .font(.system(size: 17)).monospacedDigit().foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Group {
                    Button { store.music.play(MusicQueue(tracks: tracks, start: 0, source: Self.title)) } label: {
                        Label(L10n.text("Play"), systemImage: "play.fill")
                    }
                    .controlButton(prominent: true)
                    Button { store.music.play(MusicQueue.shuffled(tracks, source: Self.title)) } label: {
                        Label(L10n.text("Shuffle"), systemImage: "shuffle")
                    }
                    .controlButton()
                    Button { store.music.addToUpNext(tracks) } label: {
                        Label(L10n.text("Add to Up Next"), systemImage: "text.line.last.and.arrowtriangle.forward")
                    }
                    .controlButton()
                }
                .disabled(tracks.isEmpty)
            }
            .fixedSize()
            .tvFocusSection()
        }
    }
}


private struct MusicFavoriteCollectionsView: View {
    @Environment(Store.self) private var store
    var body: some View {
        WithPerceptionTracking {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: MusicLayout.rowSpacing) {
                    if store.music.library.favoriteCollections.isEmpty {
                        AppContentUnavailableView("我的歌单", systemImage: "music.note.list",
                                                  description: Text("在歌单或专辑页面点击收藏，即可在这里找到。"))
                            .padding(.vertical, 60)
                    }
                    ForEach(store.music.library.favoriteCollections) { collection in
                        WithPerceptionTracking {
                            HStack {
                                MusicCollectionRow(collection: collection)
                                Button { store.music.library.toggleFavorite(collection) } label: {
                                    Image(systemName: "heart.fill").foregroundStyle(Brand.accent)
                                }.buttonStyle(.plain).accessibilityLabel("取消收藏 " + collection.title)
                            }
                        }
                    }
                }.glassRowInsets().pageContainer()
            }.screenBackdrop().screenTitle("我的歌单").musicPlayerInset()
        }
    }
}
