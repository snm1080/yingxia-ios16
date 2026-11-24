import SwiftUI
import Perception
import TVCore

/// Watching follows the selected subscription and keeps a list or poster layout.
struct PlaybackHistoryView: View {
    @Environment(Store.self) private var store
    @Environment(\.isEnabled) private var isEnabled
    #if os(iOS)
    @Environment(\.isLocalPageActive) private var isPageActive
    #endif
    @State private var query = ""
    @State private var confirmsClear = false
    @State private var clearIDs = Set<String>()
    @AppStorage("local.library.historyLayout") private var layout = "list"
    private var history: PlaybackHistory { store.playbackHistory }
    private var entries: [PlaybackHistoryEntry] {
        mergedHistoryEntries(store.visibleHistory.filter { query.isEmpty || $0.context.displayTitle.localizedCaseInsensitiveContains(query) || $0.context.sourceName.localizedCaseInsensitiveContains(query) })
    }

    var body: some View {
        WithPerceptionTracking {
            ScrollView {
                WithPerceptionTracking {
                    VStack(alignment: .leading, spacing: Layout.headerSpacing) {
                        header
                        if let error = history.persistenceError { StatusNotice(text: L10n.text("Unable to save playback history: %@", error)) }
                        if entries.isEmpty {
                            EmptyPage(symbol: AppSection.history.icon, title: "你的观看旅程即将开始",
                                      message: "播放后，这里会自动记录当前订阅的观看进度。",
                                      action: "浏览站点", actionSymbol: AppSection.sites.icon, perform: { if canInteract { store.section = .sites } })
                        } else if layout == "horizontal" {
                            LazyVGrid(columns: Layout.posterColumns, spacing: Layout.gridRowSpacing) {
                                ForEach(entries) { entry in WithPerceptionTracking { WatchingHistoryCard(entry: entry) } }
                            }
                        } else {
                            LazyVStack(spacing: 12) { ForEach(entries) { entry in WithPerceptionTracking { historyRow(entry) } } }
                        }
                    }.pageContainer()
                }
            }
            .catalogSearchable(text: $query, prompt: L10n.text("Search history"))
            .screenBackdrop().historyDetailsDestination().tabTitle(AppSection.history.title)
            .disabled(!canInteract)
            .alert("清空当前显示的观看记录？", isPresented: $confirmsClear) {
                Button("清空观看记录", role: .destructive) {
                    guard canInteract else { return }
                    history.remove(clearIDs); clearIDs.removeAll()
                }
                Button("取消", role: .cancel) { clearIDs.removeAll() }
            }
        }
    }

    private var canInteract: Bool {
        #if os(iOS)
        isEnabled && isPageActive && store.section == .history
        #else
        isEnabled && store.section == .history
        #endif
    }

    private func resume(_ entry: PlaybackHistoryEntry, mode: PlaybackResumeMode = .resume) {
        guard canInteract else { return }
        store.resume(entry, mode: mode)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack { Text("观看 · \(entries.count) 条").font(.title3.bold()); Spacer(); actions }
                VStack(alignment: .leading, spacing: 10) { Text("观看 · \(entries.count) 条").font(.title3.bold()); HStack { actions } }
            }
            Text(store.historySubscriptions.first.map { "当前订阅：\($0.title)" } ?? "未启用订阅期间")
                .font(.subheadline).foregroundStyle(.secondary)
            Text(store.historyScope == nil ? "显示未启用订阅期间的观看记录，包含已启用的 Python 来源。" : "显示当前订阅及所有已启用 Python 来源在此订阅下的观看进度。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
    private var actions: some View {
        Group {
            Button {
                guard canInteract else { return }
                layout = layout == "list" ? "horizontal" : "list"
            } label: {
                Image(systemName: layout == "list" ? "square.grid.2x2" : "list.bullet")
            }.controlButton().accessibilityLabel(layout == "list" ? "切换为横排" : "切换为列表")
            Button {
                guard canInteract else { return }
                clearIDs = Set(store.visibleHistory.map(\.id)); confirmsClear = true
            } label: {
                Label("清空观看记录", systemImage: "trash").lineLimit(1)
            }.controlButton().disabled(store.visibleHistory.isEmpty)
        }
    }
    private func historyRow(_ entry: PlaybackHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { resume(entry) } label: {
                HStack(alignment: .top, spacing: 12) {
                    HistoryPoster(entry: entry)
                        .frame(width: 54, height: 78).clipped().clipShape(RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.context.displayTitle).font(.headline).foregroundStyle(.primary).lineLimit(2)
                        Text([SourceLabel(entry.context.sourceName).text, entry.context.episodeFlag, entry.context.episodeName].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        Text(HistoryFormat.status(entry)).font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Text(entry.updatedAt, style: .date).font(.caption2).foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            HStack(spacing: 12) {
                Button("从头播放", systemImage: "arrow.counterclockwise") { resume(entry, mode: .beginning) }
                Spacer(minLength: 0)
                Button(entry.completed ? "重新观看" : "继续观看", systemImage: "play.fill") { resume(entry) }
                Button(role: .destructive) {
                    guard canInteract else { return }
                    history.remove(historyEntryIDs(of: entry, in: store.visibleHistory))
                } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("移除 \(entry.context.displayTitle) 的观看记录")
            }.font(.subheadline).buttonStyle(.borderless)
        }.padding(14).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
    }
}

/// One row per title: episodes of the same show collapse onto the most recently
/// watched one. Storage keeps every episode; only the list merges. Entries arrive
/// newest-first, so the first of each title is its latest episode.
func mergedHistoryEntries(_ entries: [PlaybackHistoryEntry]) -> [PlaybackHistoryEntry] {
    var seen = Set<String>()
    return entries.filter { seen.insert($0.context.id).inserted }
}

/// All stored episode ids of one title, so removing a merged row removes the
/// whole title's history instead of only its latest episode.
func historyEntryIDs(of entry: PlaybackHistoryEntry, in entries: [PlaybackHistoryEntry]) -> Set<String> {
    Set(entries.filter { $0.context.id == entry.context.id }.map(\.id))
}

enum HistoryMetrics {
    /// Continue Watching card width on Watch Now; the History page lets the grid size its cards.
    #if os(tvOS)
    static let card: CGFloat = DiscoverLayout.posterWidth
    #elseif os(macOS)
    static let card: CGFloat = 150
    #else
    static let card: CGFloat = 120
    #endif
}

enum HistoryFormat {
    static func status(_ entry: PlaybackHistoryEntry) -> String {
        if let reading = entry.context.readingProgress { return entry.completed ? "已看完 · \(reading.totalPages) 页" : "看到第 \(reading.page + 1) / \(reading.totalPages) 页" }
        return entry.completed ? "已看完" : "看到 \(EpisodeSkipSettings.formatTime(entry.position))"
    }
}

/// The independent Watching grid uses ordinary buttons only. Its controls and page
/// checks are separate from the homepage's native long-press menu.
struct WatchingHistoryCard: View {
    @Environment(Store.self) private var store
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.openHistoryDetails) private var openDetails
    @Environment(\.openRoute) private var openRoute
    #if os(iOS)
    @Environment(\.isLocalPageActive) private var isPageActive
    #endif
    let entry: PlaybackHistoryEntry

    private var canInteract: Bool {
        #if os(iOS)
        isEnabled && isPageActive && store.section == .history
        #else
        isEnabled && store.section == .history
        #endif
    }

    var body: some View {
        WithPerceptionTracking {
            Button { resume() } label: { HistoryCardLabel(entry: entry, details: true) }
                .cardButton()
                .accessibilityIdentifier("history.resume." + entry.context.videoID)
                .overlay(alignment: .topTrailing) {
                    WithPerceptionTracking {
                        HStack(spacing: 6) {
                            ArtworkBadgeButton(symbol: "arrow.counterclockwise", label: "从头播放") { resume(mode: .beginning) }
                            if let route = detailsRoute {
                                ArtworkBadgeButton(symbol: "info", label: L10n.text("Show Details")) {
                                    guard canInteract else { return }
                                    store.cancelResume()
                                    if let openDetails { openDetails(route) } else { openRoute?(route) }
                                }
                            }
                            ArtworkBadgeButton(symbol: "xmark", label: L10n.text("Remove from history"), destructive: true) {
                                guard canInteract else { return }
                                store.playbackHistory.remove(historyEntryIDs(of: entry, in: store.visibleHistory))
                            }
                        }.padding(8)
                    }
                }
                .disabled(!canInteract)
        }
    }

    private func resume(mode: PlaybackResumeMode = .resume) {
        guard canInteract else { return }
        store.resume(entry, mode: mode)
    }

    private var detailsRoute: Route? {
        guard openDetails != nil || openRoute != nil, let client = store.historyClient(entry) else { return nil }
        return Route { AnyView(VideoDetailView(video: entry.listVideo, client: client)) }
    }
}

/// Shared artwork and captions contain no gestures, modal state or route ownership.
struct HistoryCardLabel: View {
    @Environment(Store.self) private var store
    @AppStorage(HistoryFileDetails.key) private var showsFileDetails = false
    let entry: PlaybackHistoryEntry
    var details = false

    var body: some View { WithPerceptionTracking { cardLabel } }

    /// The short episode label when history kept a netdisk file's name (#521, #522): the card cut a long name off after
    /// the show's, so every episode of a series looked the same. With file details on, its size and quality follow
    /// the number (#595).
    private var episodeLabel: String {
        EpisodeLabels.historyLabel(entry.context.episodeName, showsDetails: showsFileDetails)
    }

    private var cardLabel: some View {
        VStack(alignment: centredCaptions ? .center : .leading, spacing: 8) {
            Color.clear.aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay { WithPerceptionTracking { HistoryPoster(entry: entry) } }
                .coverOverlay(alignment: .bottom) {
                    WithPerceptionTracking {
                        if entry.duration > 0 {
                            // White on the artwork, as in the TV app: the accent is near-black in light mode.
                            GeometryReader { proxy in
                                WithPerceptionTracking {
                                    Capsule().fill(.white.opacity(0.25))
                                        .overlay(alignment: .leading) { WithPerceptionTracking { Capsule().fill(.white).frame(width: proxy.size.width * entry.progress) } }
                                }
                            }
                            .frame(height: 5).padding(10)
                        }
                    }
                }
                .coverOverlay(animated: true) {
                    WithPerceptionTracking {
                        // Preparing this title; choosing another card switches to that one.
                        if store.resumingHistoryID == entry.id {
                            ZStack {
                                Color.black.opacity(0.5)
                                ProgressView().controlSize(.large).tint(.white)
                            }
                        }
                    }
                }
                .posterClip(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(entry.context.displayTitle).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                .cardCaption()
            if details {
                Text("\(episodeLabel) · \(SourceLabel(entry.context.sourceName).text)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).cardCaption()
                Text(HistoryFormat.status(entry)).font(.caption).monospacedDigit().foregroundStyle(.tertiary).lineLimit(1)
                    .cardCaption()
            } else {
                // The bar on the poster already says how far; the line names the episode.
                Text(episodeLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1).cardCaption()
            }
        }
        .frame(width: details ? nil : HistoryMetrics.card)
        .frame(maxWidth: details ? .infinity : nil, alignment: .leading)
    }

    /// On Apple TV's Watch Now the captions are centred under the cover, as Discover's.
    private var centredCaptions: Bool {
        #if os(tvOS)
        !details
        #else
        false
        #endif
    }

}

extension EnvironmentValues { @Entry var openHistoryDetails: ((Route) -> Void)? = nil }

extension View {
    /// Lets the history cards under it open a title's page (from the cards' visible controls or homepage menu). Outside the cards' lazy grids:
    /// a navigation destination inside a lazy container is not supported.
    func historyDetailsDestination() -> some View { modifier(HistoryDetailsDestination()) }
}

private struct HistoryDetailsDestination: ViewModifier {
    @Environment(\.openRoute) private var openRoute
    @State private var route: Route?
    func body(content: Content) -> some View {
        WithPerceptionTracking {
            content
                .environment(\.openHistoryDetails) { if let openRoute { openRoute($0) } else { route = $0 } }
                .appNavigationDestination(item: $route) { route in
                    WithPerceptionTracking {
                        #if os(macOS)
                        route.build().musicBar()
                        #else
                        route.build()
                        #endif
                    }
                }
        }
    }
}
