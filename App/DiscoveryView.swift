import SwiftUI
import Perception
import TVCore
#if os(iOS)
import UIKit
#endif

private struct SearchSourceItem: Identifiable {
    let id: String
    let name: String
    var count: Int? = nil
    /// A source that is slow or failing lately; see `SourceHealth`.
    var dot: Color? = nil
}

private typealias SearchPoster = SearchVideoResult

private struct SearchResultFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, next in next }
    }
}

#if os(iOS)
/// MacCat's result-bearing source rail, with touch-sized rows and an independently scrolling list.
private struct SearchSiteRail: View {
    let items: [SearchSourceItem]
    let selection: String
    let waiting: Bool
    var compact = false
    let select: (String) -> Void

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 0) {
                if let all = items.first { row(all).padding(6) }
                Divider()
                ScrollView {
                    WithPerceptionTracking {
                        LazyVStack(spacing: 3) {
                            ForEach(Array(items.dropFirst())) { item in
                                WithPerceptionTracking { row(item) }
                            }
                            if waiting, items.count == 1 {
                                Text("等待站点返回结果…")
                                    .font(.footnote).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            }
                        }.padding(6)
                    }
                }
            }
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.09), lineWidth: 1) }
            .accessibilityIdentifier("search.sources.rail")
        }
    }

    private func row(_ item: SearchSourceItem) -> some View {
        let selected = item.id == selection
        return Button { select(item.id) } label: {
            VStack(alignment: .leading, spacing: compact ? 5 : 0) {
                HStack(spacing: 8) {
                    Text(SourceLabel(item.name).text)
                        .font(.subheadline.weight(selected ? .semibold : .regular))
                        .lineLimit(2).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !compact { status(item) }
                }
                if compact { HStack(spacing: 6) { status(item) } }
            }
            .foregroundStyle(selected ? Brand.accent : Color.secondary)
            .padding(.horizontal, 9).padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .background(selected ? Brand.accent.opacity(0.12) : .clear,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityLabel(item.count.map { "\(item.name)，\($0) 个结果" } ?? item.name)
    }

    @ViewBuilder private func status(_ item: SearchSourceItem) -> some View {
        if let dot = item.dot { Circle().fill(dot).frame(width: 6, height: 6) }
        if let count = item.count {
            Text(count, format: .number).font(.caption.weight(.medium)).monospacedDigit()
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
        }
    }
}
#endif

struct GlobalSearchView: View {
    @Environment(Store.self) private var store
    #if os(iOS)
    @Environment(\.isLocalPageActive) private var localPageActive
    #endif
    @FocusState private var inputFocused: Bool
    @State private var showFailures = false
    @State private var showsSearchSettings = false
    /// The sources being searched right now, under the summary; folded away unless asked for.
    @AppStorage("searchShowsActivity") private var showsActivity = false
    /// Whether the end of the results is on screen, so finished pages can ask for the next.
    @State private var endVisible = false
    @State private var restoringSearchPosition = true
    #if !os(tvOS)
    /// Results as rows of a small cover beside the whole title, instead of the poster grid: long or similar titles
    /// are cut to one line under a poster (#426).
    @AppStorage("searchResultsAsList") private var showsList = false
    #endif
    @AppStorage("videoSearchHistory") private var historyData = Data()
    #if os(tvOS)
    /// Titles iQiyi suggests for the draft, and 360kan's chart for an empty field (`SearchSuggestions`).
    @State private var suggested: [String] = []
    @State private var trending: [String] = []
    /// The keyboard's own screen, opened from the search field.
    @State private var entering = false
    #endif
    private var model: SearchModel { store.searchModel }
    private var paginationActive: Bool {
        #if os(iOS)
        localPageActive
        #else
        true
        #endif
    }
    private func requestNextPage(config: Subscription) {
        guard paginationActive, endVisible else { return }
        model.loadMore(model.selectedSource, config: config, excludingFailed: true)
    }
    private var history: [String] { (try? JSONDecoder().decode([String].self, from: historyData)) ?? [] }
    /// SearchModel keeps the source-scoped cards materialized between result publications.
    private var posters: [SearchPoster] { model.items }
    private var sourceItems: [SearchSourceItem] {
        #if os(iOS)
        var items = model.matches.filter { model.includesInSelectedGroup($0.id) }.map { result in
            SearchSourceItem(id: result.id, name: result.site.name,
                             count: model.videoCount(for: result.id),
                             dot: store.health(of: result.site).warning)
        }
        // A saved source filter remains visible while that source's first page is still pending.
        if let selected = model.selectedSource, !items.contains(where: { $0.id == selected }),
           let site = store.subscription?.sites.first(where: { $0.id == selected }),
           model.includesInSelectedGroup(site.id), model.asking.contains(site.key) {
            let answered = model.results.contains { $0.id == selected }
            items.append(.init(id: site.id, name: site.name, count: answered ? model.videoCount(for: site.id) : nil,
                               dot: store.health(of: site).warning))
        }
        return [.init(id: "", name: "全部站点", count: model.videoCount)] + items
        #else
        // Built-in sources can be selected while their first search is still in flight.
        let builtins = (store.subscription?.sites ?? []).filter(\.isBuiltIn).filter { site in
            model.includesInSelectedGroup(site.id) && model.total > 0 && (model.results.contains { $0.site.key == site.key } ||
                (model.busy && model.asking.contains(site.key)))
        }.map { site in
            SearchSourceItem(id: site.key, name: site.name,
                             count: model.results.contains { $0.site.key == site.key } ? model.videoCount(for: site.key) : nil)
        }
        return [.init(id: "", name: L10n.text("All Sources"), count: model.videoCount)]
            + builtins
            + model.matches.filter { !$0.site.isBuiltIn && model.includesInSelectedGroup($0.id) }.map { .init(id: $0.id, name: $0.site.name, count: uniqueVideos(model.videos(for: $0.id)).count,
                                                                       dot: store.health(of: $0.site).warning) }
        #endif
    }

    var body: some View {
        WithPerceptionTracking {
            @AppBindable var model = model
            #if os(tvOS)
            searchResults()
                // A field beside the sidebar button rather than the system keyboard across the top of the page, so the
                // results get the screen (#415). Selecting it opens the keyboard on a screen of its own.
                .modifier(BesideSidebarButton(title: AppSection.search.title) { searchField })
                .screenBackdrop()
                .fullScreenCover(isPresented: $entering) { WithPerceptionTracking { searchEntry } }
                .sheet(isPresented: $showFailures) { WithPerceptionTracking { failureDetails } }
                .onAppear { if let config = store.subscription { model.resumeSuspended(config: config) } }
                // The keyboard's screen covers the page without leaving it, so a running search goes on under it.
                .onDisappear { if !entering { endVisible = false; model.suspend() } }
            #else
            searchResultLayout
                .topBar(hardEdge: true) { WithPerceptionTracking { if let config = store.subscription, showsHeader { searchHeader(config) } } }
                .screenBackdrop()
                .screenTitle(L10n.text("Global Search"))
                #if os(iOS)
                .toolbar { ToolbarItem(placement: .navigationBarTrailing) { searchSettingsButton } }
                .localGlassDialog(isPresented: $showsSearchSettings, title: "搜索设置", maxWidth: 560, maxHeight: 700, layout: .centered) {
                    WithPerceptionTracking {
                        if let config = store.subscription { LocalSearchSettingsView(config: config) }
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
                .appOnChange(of: localPageActive) { _, active in
                    if active, let config = store.subscription {
                        model.resumeSuspended(config: config)
                        requestNextPage(config: config)
                    } else { model.suspend() }
                }
                #else
                .toolbar { ToolbarItem(placement: .primaryAction) { searchSettingsButton } }
                .sheet(isPresented: $showsSearchSettings) { if let config = store.subscription { LocalSearchSettingsView(config: config) } }
                #endif
                // The system search field, as on Sources and Live TV: under the title on iPhone and iPad, in the toolbar on
                // the Mac. Only Return or the keyboard's Search key searches; clearing the field goes back to the recent searches.
                .catalogSearchable(text: $model.draft, prompt: L10n.text("Search videos"))
                .searchFieldFocused($inputFocused)
                .onSubmit(of: .search) { if let config = store.subscription { submit(config) } }
                .appOnChange(of: model.draft) { _, draft in if draft.isEmpty && !model.keyword.isEmpty { model.reset() } }
                #if os(iOS)
                .scrollDismissesKeyboard(.interactively)
                #endif
                .sheet(isPresented: $showFailures) { WithPerceptionTracking { failureDetails } }
                .onAppear {
                    // Not on iPhone and iPad: the keyboard would cover the tab bar, and a tab's root page has no back
                    // button, so there would be no way to leave without searching.
                    #if os(macOS)
                    if model.keyword.isEmpty { inputFocused = true }
                    #endif
                    if paginationActive, let config = store.subscription {
                        model.resumeSuspended(config: config)
                        requestNextPage(config: config)
                    }
                }
                .onDisappear { endVisible = false; model.suspend() }
            #endif
        }
    }

    private var searchSettingsButton: some View {
        WithPerceptionTracking {
            Button {
                inputFocused = false
                #if os(iOS)
                // searchFieldFocused has no binding on iOS 16/17. End the native
                // search field's editing session before presenting another controller.
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                #endif
                showsSearchSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 19, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(store.subscription == nil)
            .accessibilityLabel("搜索设置")
            .accessibilityIdentifier("search.settings")
        }
    }


    /// The search field is the system's, so the bar below it waits for a search.
    private var showsHeader: Bool { !model.keyword.isEmpty }

    /// Result-bearing sources form a vertical list on phones and iPad split views too.
    @ViewBuilder private var searchResultLayout: some View {
        #if os(iOS)
        GeometryReader { geometry in
            WithPerceptionTracking {
                let rail = !model.keyword.isEmpty && store.subscription != nil
                let railWidth = min(208, max(104, geometry.size.width * (geometry.size.width < 600 ? 0.30 : 0.24)))
                HStack(alignment: .top, spacing: 0) {
                    if rail {
                        SearchSiteRail(items: sourceItems, selection: model.selectedSource ?? "", waiting: model.busy,
                                       compact: geometry.size.width < 600) { id in
                            model.select(id.isEmpty ? nil : id)
                        }
                        .frame(width: railWidth)
                        .padding(.leading, geometry.size.width < 600 ? 8 : Layout.gutter)
                        .padding(.vertical, Layout.gutter)
                    }
                    positionedSearchResults(usesSiteRail: rail)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: Layout.maxWidth, maxHeight: .infinity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        #else
        positionedSearchResults(usesSiteRail: false)
        #endif
    }

    @ViewBuilder private func positionedSearchResults(usesSiteRail: Bool) -> some View {
        @AppBindable var model = model
        if #available(iOS 17, macOS 14, tvOS 17, *) {
            ScrollViewReader { reader in
                WithPerceptionTracking {
                    searchResults(usesSiteRail: usesSiteRail).scrollPosition(id: $model.scrollID)
                        .appOnChange(of: model.selectedSource) { _, _ in reader.scrollTo("search.top", anchor: .top) }
                        .appOnChange(of: model.selectedGroup) { _, _ in reader.scrollTo("search.top", anchor: .top) }
                        .appOnChange(of: model.keyword) { _, _ in reader.scrollTo("search.top", anchor: .top) }
                }
            }
        } else {
            let savedID = model.scrollID
            ScrollViewReader { reader in
                WithPerceptionTracking {
                    searchResults(usesSiteRail: usesSiteRail)
                        .task {
                            // Restoring after a title's back navigation needs the grid laid out first.
                            try? await Task.sleep(for: .milliseconds(60))
                            guard !Task.isCancelled else { return }
                            if let savedID { reader.scrollTo(savedID, anchor: .top) }
                            restoringSearchPosition = false
                        }
                        .onPreferenceChange(SearchResultFrames.self) { frames in
                            MainActor.assumeIsolated {
                                guard !restoringSearchPosition else { return }
                                let visible = frames.filter { $0.value.maxY > 0 }
                                    .min { first, second in
                                        first.value.minY == second.value.minY ? first.value.minX < second.value.minX : first.value.minY < second.value.minY
                                    }?.key
                                if let visible, model.scrollID != visible { model.scrollID = visible }
                            }
                        }
                        .appOnChange(of: model.selectedSource) { _, _ in
                            reader.scrollTo("search.top", anchor: .top)
                        }
                        .appOnChange(of: model.selectedGroup) { _, _ in
                            reader.scrollTo("search.top", anchor: .top)
                        }
                        .appOnChange(of: model.keyword) { _, _ in
                            reader.scrollTo("search.top", anchor: .top)
                        }
                        .onDisappear { restoringSearchPosition = true }
                }
            }
        }
    }

    private func searchResults(usesSiteRail: Bool = false) -> some View {
        ScrollView {
            WithPerceptionTracking {
                VStack(alignment: .leading, spacing: 24) {
                    #if os(tvOS)
                    if let config = store.subscription, !model.keyword.isEmpty {
                        searchHeader(config).padding(.horizontal, -Layout.gutter)
                    }
                    #endif
                    if let config = store.subscription {
                        if model.keyword.isEmpty {
                            #if os(tvOS)
                            // Recent searches are on the keyboard's screen, with the suggestions.
                            Text(L10n.text("Search all available sources in your subscription.")).font(.body).foregroundStyle(.secondary)
                                .frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
                            #else
                            idle.frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
                            #endif
                        }
                        else {
                            #if os(iOS)
                            VStack(alignment: .leading, spacing: 16) {
                                searchGroupTabs
                                if !usesSiteRail {
                                    SourceStrip(items: sourceItems.map { .init(id: $0.id, name: $0.name, count: $0.count, dot: $0.dot) },
                                                selection: model.selectedSource ?? "") { id in
                                        model.select(id.isEmpty ? nil : id)
                                    }.accessibilityIdentifier("search.sources.strip")
                                }
                                searchResultCaption
                                searchResultContent(config, usesSiteRail: usesSiteRail)
                            }
                            #else
                            searchResultContent(config, usesSiteRail: usesSiteRail)
                            #endif
                        }
                    } else {
                        EmptyResults(symbol: "magnifyingglass", title: L10n.text("No Sources Yet"), message: L10n.text("Add a TVBox subscription in Settings."),
                                     action: L10n.text("Settings"), actionSymbol: "gearshape") { store.section = .settings }
                    }
                }.pageContainer().id("search.top")
            }
        }
        .coordinateSpace(name: "search.results")
    }

    #if os(iOS)
    private var searchGroupTabs: some View {
        ScrollStrip(scrollTo: model.selectedGroup) {
            WithPerceptionTracking {
                HStack(spacing: 4) {
                    ForEach(model.groups) { group in
                        WithPerceptionTracking {
                            let selected = model.selectedGroup == group.id
                            Button { model.selectGroup(group.id) } label: {
                                Text(group.name.isEmpty ? "分组" : group.name)
                                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                                    .foregroundStyle(selected ? Brand.accent : Color.secondary)
                                    .padding(.horizontal, 14).frame(minHeight: 44)
                                    .overlay(alignment: .bottom) {
                                        Rectangle().fill(selected ? Brand.accent : .clear).frame(height: 2)
                                    }
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).id(group.id)
                            .accessibilityAddTraits(selected ? [.isSelected] : [])
                        }
                    }
                }
            }
        }
        .overlay(alignment: .bottom) { Color.primary.opacity(0.08).frame(height: 1).allowsHitTesting(false) }
        .accessibilityLabel("搜索结果分组")
        .accessibilityIdentifier("search.groups")
    }

    private var searchResultCaption: some View {
        let selected = model.selectedSource.flatMap { id in store.subscription?.sites.first { $0.id == id } }
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(selected.map { SourceLabel($0.name).text } ?? "全部结果").lineLimit(2)
            Spacer(minLength: 0)
            Text("\(posters.count) 个结果").monospacedDigit().fixedSize()
        }
        .font(.subheadline).foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("search.results.caption")
    }
    #endif

    @ViewBuilder private func searchResultContent(_ config: Subscription, usesSiteRail: Bool) -> some View {
        #if os(iOS)
        let emptyGroup = model.groups.first { $0.id == model.selectedGroup }?.siteIDs.isEmpty == true
        #else
        let emptyGroup = false
        #endif
        if emptyGroup {
            EmptyResults(symbol: "magnifyingglass", title: "当前分组没有搜索站点", message: "可在搜索设置中为这个分组添加站点。",
                         action: "搜索设置", actionSymbol: "slider.horizontal.3") { showsSearchSettings = true }
        } else if model.total == 0 {
            EmptyResults(symbol: "magnifyingglass", title: L10n.text("No searchable sources are available on this device."))
        } else if posters.isEmpty {
            if model.busy && (model.selectedSource == nil || !model.results.contains(where: { $0.id == model.selectedSource })) {
                #if os(iOS)
                VStack(alignment: .leading, spacing: 16) {
                    Text("等待站点返回结果…").font(.subheadline).foregroundStyle(.secondary)
                    if listed { ProgressView().frame(maxWidth: .infinity).padding(.vertical, 60) }
                    else { PosterSkeletonGrid() }
                }
                #else
                VStack(spacing: 18) {
                    ProgressView()
                    Text(L10n.text("Searching for “%@”…", model.keyword)).font(.title3.weight(.semibold))
                    Text(L10n.text("Results appear as each source responds.")).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 70)
                #endif
            } else {
                emptyResults(config)
            }
        } else {
            LazyVGrid(columns: resultColumns(usesSiteRail: usesSiteRail),
                      spacing: listed ? Layout.gridSpacing : Layout.gridRowSpacing) {
                WithPerceptionTracking { resultLinks(config) }
            }.appScrollTargetLayout().tvFocusSection()
            if !model.visiblePageErrors.isEmpty {
                VStack(spacing: 10) {
                    Text("部分来源下一页加载失败，可重试。").font(.footnote).foregroundStyle(.secondary)
                    Button("重试下一页") { model.loadMore(model.selectedSource, config: config) }.controlButton()
                }.frame(maxWidth: .infinity)
            }
            // Finished pages continue loading only while the footer and the results page remain visible.
            if model.canLoadMore(model.selectedSource, excludingFailed: true) || model.loadingMore {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 24)
                    .onScrolledIntoView(threshold: 0.2) { visible in
                        endVisible = visible
                        requestNextPage(config: config)
                    }
                    .appOnChange(of: model.loadingMore) { _, loading in
                        if !loading { requestNextPage(config: config) }
                    }
            }
        }
    }

    private func resultColumns(usesSiteRail: Bool) -> [GridItem] {
        #if os(iOS)
        if listed, usesSiteRail { return [GridItem(.flexible(minimum: 0), alignment: .top)] }
        if listed { return Self.rowColumns }
        return [GridItem(.adaptive(minimum: Layout.posterMin), spacing: Layout.gridSpacing, alignment: .top)]
        #else
        return listed ? Self.rowColumns : Layout.posterColumns
        #endif
    }

    /// Empty results report failures in the selected group/source, so another group's outage does not mask this filter.
    private func emptyResults(_ config: Subscription) -> some View {
        let visible = model.results.filter { model.includesInSelectedGroup($0.id) && (model.selectedSource == nil || $0.id == model.selectedSource) }
        let failures = visible.filter { $0.error != nil }
        let mostlyFailed = failures.count * 2 > visible.count
        let selected = model.selectedSource.flatMap { id in config.sites.first { $0.id == id } }
        let title = L10n.text(mostlyFailed ? "Most Sources Unavailable" : "No Videos")
        let message: String
        if mostlyFailed {
            message = selected.flatMap { site in failures.first { $0.id == site.id }?.error }
                ?? L10n.text("%lld of %lld sources didn't respond, so results may be incomplete.", failures.count, visible.count)
        } else {
            #if os(iOS)
            message = "试试其他站点、分组或关键词。"
            #else
            message = L10n.text("Try another keyword.")
            #endif
        }
        return AppContentUnavailableView {
            Label(title,
                  systemImage: mostlyFailed ? "wifi.exclamationmark" : "magnifyingglass")
        } description: {
            Text(message)
        } actions: {
            if !model.failures.isEmpty || !model.paused.isEmpty {
                HStack(spacing: 16) {
                    Button(L10n.text("Retry failed sources")) { model.resume(config: config, retryFailures: true) }
                        .controlButton(prominent: true)
                    Button(L10n.text("Show Details")) { showFailures = true }.controlButton()
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    #if os(tvOS)
    /// Drawn as a text field showing the draft; selecting it opens `searchEntry`.
    private var searchField: some View {
        Button { entering = true } label: {
            Label {
                Text(model.draft.isEmpty ? L10n.text("Search videos") : model.draft)
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(model.draft.isEmpty ? 0.6 : 1)
            } icon: { Image(systemName: "magnifyingglass") }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Keeps its size on focus (it turns white): grown, the full-width field covered the sidebar button.
        .glassPill(lift: 1)
        .accessibilityLabel(L10n.text("Search videos"))
        .accessibilityValue(model.draft)
        .accessibilityIdentifier("search.field")
    }

    /// The system search keyboard, full screen: past searches and suggested titles under it, then the button that
    /// runs the search and closes it. Back closes it without searching.
    private var searchEntry: some View {
        @AppBindable var model = model
        return NavigationStack {
            WithPerceptionTracking {
                ScrollView {
                    WithPerceptionTracking {
                        VStack(alignment: .leading, spacing: 24) {
                            // Editing, dictation and search completions only update the draft. The remote
                            // needs an explicit, focusable submit action before starting expensive plugins.
                            if let config = store.subscription {
                                let query = model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !query.isEmpty, query != model.keyword {
                                    SearchQueryButton(query: query) { submit(config) }.accessibilityIdentifier("search.submit")
                                }
                            }
                            idle.frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
                        }.pageContainer()
                    }
                }
                .searchable(text: $model.draft, prompt: Text(L10n.text("Search videos")))
                .searchSuggestions {
                    WithPerceptionTracking {
                        // Past searches first, then titles for what is typed: a remote spells "xyj" and picks 西游记, as on
                        // FongMi's TV search. A completion only fills the field; the Search button below still starts the search.
                        let past = Array(history.filter { model.draft.isEmpty || $0.localizedCaseInsensitiveContains(model.draft) }.prefix(6))
                        ForEach(past + (model.draft.isEmpty ? trending : suggested).filter { !past.contains($0) }, id: \.self) { query in
                            WithPerceptionTracking {
                                Text(query).searchCompletion(query)
                            }
                        }
                    }
                }
                .task(id: model.draft) { await suggest(model.draft) }
                .onSubmit(of: .search) { if let config = store.subscription { submit(config) } }
                .screenBackdrop()
            }
        }
    }
    #endif

    private func searchHeader(_ config: Subscription) -> some View {
        #if os(iOS)
        return VStack(alignment: .leading, spacing: 10) {
            searchSummary
            HStack(alignment: .center, spacing: 12) {
                Text("“\(model.keyword)” 的搜索结果")
                    .font(.headline).lineLimit(1).truncationMode(.tail)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                searchActions(config)
            }
            if model.total > 0 {
                ProgressView(value: Double(model.completed), total: Double(max(model.total, 1)))
                    .progressViewStyle(.linear).tint(Brand.accent)
            }
            if model.busy && showsActivity {
                SearchActivityList(origin: config.origin, completed: model.completed, total: model.total, runStart: model.runStart,
                                   showsSources: true)
            }
        }
        .frame(maxWidth: Layout.maxWidth - Layout.gutter * 2)
        .padding(.horizontal, Layout.gutter).padding(.top, 6).padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        #else
        @AppBindable var model = model
        return VStack(alignment: .leading, spacing: 14) {
            if !model.groups.isEmpty {
                ChipRow {
                    HStack(spacing: 8) {
                        ForEach(model.groups) { group in
                            Chip(title: group.name.isEmpty ? "分组" : group.name, selected: model.selectedGroup == group.id) { model.selectGroup(group.id) }
                        }
                    }
                }
            }
            if !model.keyword.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 16) {
                        searchSummary
                        Spacer(minLength: 16)
                        searchActions(config)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        searchSummary
                        searchActions(config)
                    }
                }
                #if os(tvOS)
                // Stop and the unavailable sources sit at the row's far end, out of line with the suggestions above and
                // the source chips below, so the remote passed them by. As a section, moving onto the row lands on them.
                .focusSection()
                #endif
                if model.busy {
                    SearchActivityList(origin: config.origin, completed: model.completed, total: model.total, runStart: model.runStart,
                                       showsSources: showsActivity)
                        .transition(.opacity)
                }
                if sourceItems.count > 1 {
                    #if os(tvOS)
                    ChipRow {
                        HStack(spacing: 8) {
                            ForEach(sourceItems) { item in
                                WithPerceptionTracking {
                                    Chip(title: item.count.map { "\(item.name) · \($0)" } ?? item.name, selected: (model.selectedSource ?? "") == item.id,
                                         mark: item.id == Bilibili.siteKey, dot: item.dot) {
                                        model.select(item.id.isEmpty ? nil : item.id)
                                    }
                                }
                            }
                        }
                    }
                    // The chips sit at the left, under the field and the summary row's far end: as a section, Down
                    // from anywhere above lands on them (#481).
                    .focusSection()
                    #else
                    SourceStrip(items: sourceItems.map { .init(id: $0.id, name: $0.name, count: $0.count, dot: $0.dot) }, selection: model.selectedSource ?? "") { id in
                        model.select(id.isEmpty ? nil : id)
                    }
                    #endif
                }
            }
        }
        .frame(maxWidth: model.keyword.isEmpty ? 760 : Layout.maxWidth - Layout.gutter * 2)
        .frame(maxWidth: .infinity)
        #if os(iOS)
        // Right under the search bar, which has its own margin.
        .padding(.horizontal, Layout.gutter).padding(.top, 6).padding(.bottom, 12)
        #elseif os(macOS)
        .padding(.horizontal, Layout.gutter).padding(.vertical, 10)
        #else
        .padding(.horizontal, Layout.gutter).padding(.vertical, 16)
        #endif
        #endif
    }

    private var searchSummary: some View {
        #if os(iOS)
        return HStack(alignment: .center, spacing: 8) {
            ProgressView().controlSize(.small).opacity(model.busy ? 1 : 0)
                .accessibilityHidden(!model.busy)
            Text("\(model.completed) / \(model.total)").font(.subheadline.weight(.semibold)).fixedSize()
            Text(summaryDetail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
        }
        .monospacedDigit().fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        #else
        // A spinner has no text baseline, so it centers on the row; only the two labels share a baseline.
        HStack(alignment: .center, spacing: 12) {
            #if !os(iOS)
            if model.busy { ProgressView().controlSize(.small) }
            #endif
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(L10n.text("%lld results", model.videoCount)).font(.headline)
                Text(summaryDetail)
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .monospacedDigit()
        .fixedSize(horizontal: false, vertical: true)
        #endif
    }

    /// Failed sources count as "completed", so once the search ends report how many actually answered.
    private var summaryDetail: String {
        #if os(iOS)
        if model.stopped { return "已暂停搜索" }
        if model.busy { return "站点已完成" }
        if !model.failures.isEmpty { return "站点已完成，部分来源不可用" }
        return "站点搜索完成"
        #else
        if model.stopped { return L10n.text("Search paused") }
        if model.busy || model.failures.isEmpty { return L10n.text("Searched %lld of %lld sources", model.completed, model.total) }
        return L10n.text("%lld of %lld sources responded", model.completed - model.failures.count, model.total)
        #endif
    }

    /// Four fixed iOS slots keep the keyword and header height stable as sources finish or fail.
    private func searchActions(_ config: Subscription) -> some View {
        #if os(iOS)
        let unavailable = model.failures.count + model.paused.count
        return HStack(spacing: 4) {
            searchIcon(symbol: showsList ? "square.grid.2x2" : "list.bullet",
                       title: L10n.text(showsList ? "Show as Grid" : "Show as List"), id: "search.layout") {
                withAnimation(.appSmooth(duration: 0.35)) { showsList.toggle() }
            }
            searchIcon(symbol: model.busy ? "stop.fill" : "arrow.clockwise",
                       title: L10n.text(model.busy ? "Stop" : "Continue search"), id: "search.stop",
                       visible: model.busy || model.completed < model.total) {
                if model.busy { model.stop() } else { model.resume(config: config) }
            }
            searchIcon(symbol: showsActivity ? "chevron.up" : "chevron.down",
                       title: L10n.text(showsActivity ? "Hide Details" : "Show Details"), id: "search.activity",
                       visible: model.busy) {
                withAnimation(.appSmooth(duration: 0.25)) { showsActivity.toggle() }
            }
            searchIcon(symbol: "exclamationmark.triangle.fill", title: L10n.text("%lld unavailable", unavailable),
                       id: "search.unavailable", visible: unavailable > 0, count: unavailable) { showFailures = true }
        }
        .fixedSize(horizontal: true, vertical: false)
        #else
        HStack(spacing: 8) { searchActionButtons(config) }.fixedSize()
        #endif
    }

    #if os(iOS)
    @ViewBuilder private func searchIcon(symbol: String, title: String, id: String,
                                        visible: Bool = true, count: Int? = nil, action: @escaping () -> Void) -> some View {
        if visible {
            Button(action: action) {
                Image(systemName: symbol).font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(count == nil ? Color.primary : Brand.amber)
                    .appSymbolReplaceTransition()
                    .frame(width: 44, height: 44)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        if let count, count > 0 {
                            Text(count > 99 ? "99+" : String(count))
                                .font(.system(size: 9, weight: .bold)).monospacedDigit()
                                .foregroundStyle(Color.white)
                                .padding(.horizontal, 4).frame(height: 16)
                                .background(Brand.rose, in: Capsule()).padding(2)
                                .accessibilityHidden(true).allowsHitTesting(false)
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel(title).help(title).accessibilityIdentifier(id)
        } else {
            Color.clear.frame(width: 44, height: 44).allowsHitTesting(false).accessibilityHidden(true)
        }
    }
    #endif

    /// tvOS pills lead with a symbol, as the search pill does; elsewhere the title stands alone.
    @ViewBuilder private func searchActionLabel(_ title: String, symbol: String) -> some View {
        #if os(tvOS)
        Label(title, systemImage: symbol)
        #else
        Text(title)
        #endif
    }

    @ViewBuilder private func searchActionButtons(_ config: Subscription) -> some View {
        #if !os(tvOS)
        // Shows what it switches to; the symbol morphs into the other one as the results rearrange.
        let layoutTitle = L10n.text(showsList ? "Show as Grid" : "Show as List")
        Button { withAnimation(.appSmooth(duration: 0.35)) { showsList.toggle() } } label: {
            Image(systemName: showsList ? "square.grid.2x2" : "list.bullet")
                .font(.footnote.weight(.semibold))
                .appSymbolReplaceTransition()
                .frame(minWidth: 16)
        }
        .searchAction()
        .accessibilityLabel(layoutTitle).help(layoutTitle)
        .accessibilityIdentifier("search.layout")
        #endif
        if model.busy {
            Button { model.stop() } label: { searchActionLabel(L10n.text("Stop"), symbol: "stop.fill") }.searchAction()
            let title = L10n.text(showsActivity ? "Hide Details" : "Show Details")
            Button { withAnimation(.appSmooth(duration: 0.25)) { showsActivity.toggle() } } label: {
                Image(systemName: "chevron.down").font(.footnote.weight(.semibold))
                    .rotationEffect(.degrees(showsActivity ? 180 : 0))
            }
            .searchAction()
            .accessibilityLabel(title).help(title)
        } else if model.completed < model.total {
            Button { model.resume(config: config) } label: { searchActionLabel(L10n.text("Continue search"), symbol: "arrow.clockwise") }.searchAction()
        }
        if !model.failures.isEmpty || !model.paused.isEmpty {
            Button { showFailures = true } label: {
                Label {
                    Text(L10n.text("%lld unavailable", model.failures.count + model.paused.count))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Brand.amber)
                }
            }.searchAction()
        }
    }

    @ViewBuilder private func resultLinks(_ config: Subscription) -> some View {
        ForEach(posters) { item in
            WithPerceptionTracking {
                RouteLink {
                    WithPerceptionTracking {
                        CatalogDestination(video: item.video, client: CatalogClient(site: item.site, origin: config.origin, jarURL: config.spiderURL))
                            .onAppear { rememberQuery() }
                    }
                } label: {
                    WithPerceptionTracking {
                        if listed { searchRow(item) } else { searchPoster(item) }
                    }
                }
                .cardButton().id(item.id)
                .background {
                    if #unavailable(iOS 17, macOS 14, tvOS 17) {
                        GeometryReader { geometry in
                            Color.clear.preference(key: SearchResultFrames.self,
                                                   value: [item.id: geometry.frame(in: .named("search.results"))])
                        }
                    }
                }
            }
        }
    }

    private var listed: Bool {
        #if os(tvOS)
        false
        #else
        showsList
        #endif
    }

    /// Rows side by side where they fit: one column on a phone, two or three on an iPad or a Mac window.
    private static let rowColumns = [GridItem(.adaptive(minimum: 320), spacing: Layout.gridSpacing, alignment: .top)]

    /// A small cover beside the whole title (up to three lines), what the source says of it, and the source.
    private func searchRow(_ item: SearchPoster) -> some View {
        let video = item.video
        let detail = [video.year, video.category?.split(separator: ",").first.map(String.init)].compactMap { $0 }.joined(separator: " · ")
        return HStack(alignment: .top, spacing: 12) {
            Color.clear.frame(width: 64, height: 96)
                .overlay { WithPerceptionTracking { PosterImage(url: video.poster, headers: video.posterHeaders) } }
                .posterClip(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(video.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    .lineLimit(3).multilineTextAlignment(.leading)
                if !video.remarks.isEmpty {
                    Text(video.remarks).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(SourceLabel(item.site.name).text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
        // A plain fill, not glass: a long list of results would otherwise draw a glass layer per row.
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func searchPoster(_ item: SearchPoster) -> some View {
        #if os(iOS)
        return VStack(alignment: .leading, spacing: 4) {
            LocalSitePosterCard(video: item.video, landscape: false)
            Text([item.video.year, SourceLabel(item.site.name).text].compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        #else
        VStack(alignment: .leading, spacing: 2) {
            PosterCard(video: item.video)
            Text(SourceLabel(item.site.name).text).font(.caption).foregroundStyle(.secondary).lineLimit(1).cardCaption()
        }
        #endif
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: idleSpacing) {
            #if os(tvOS)
            Text(L10n.text("Search all available sources in your subscription.")).font(.body).foregroundStyle(.secondary)
            if !history.isEmpty {
                HStack {
                    Text(L10n.text("Recent Searches")).font(.headline)
                    Spacer()
                    Button(L10n.text("Clear")) { historyData = Data() }.controlButton()
                }
            }
            #else
            if history.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "magnifyingglass").font(.system(size: 44, weight: .light)).foregroundStyle(.tertiary)
                    Text(L10n.text("Search all available sources in your subscription.")).font(.title3.weight(.medium)).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity).padding(.top, 80)
            } else {
                HStack {
                    Text(L10n.text("Recent Searches")).font(.title3.weight(.bold))
                    Spacer()
                    Button(L10n.text("Clear")) { historyData = Data() }.buttonStyle(.plain).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).frame(minHeight: 44)
                }
                VStack(spacing: 0) {
                    ForEach(Array(history.enumerated()), id: \.element) { index, item in
                        WithPerceptionTracking {
                            HStack(spacing: 0) {
                                Button { useHistory(item) } label: {
                                    HStack(spacing: 14) {
                                        Image(systemName: "clock.arrow.circlepath").font(.body).foregroundStyle(.secondary).frame(width: 24)
                                        Text(item).font(.body).lineLimit(1)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.leading, 18).frame(minHeight: 48).frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                Button { removeSearch(item) } label: {
                                    Image(systemName: "xmark").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                                        .frame(width: 36, height: 48)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(L10n.text("Remove"))
                                Button { useHistory(item) } label: {
                                    Image(systemName: "arrow.up.left").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                                        .padding(.trailing, 18).frame(height: 48)
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                            if index < history.count - 1 { Divider().padding(.leading, 56) }
                        }
                    }
                }
                .glassSurface(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            #endif
        }
    }

    private var idleSpacing: CGFloat {
        #if os(tvOS)
        22
        #else
        8
        #endif
    }

    private func pauseNote(_ site: Site) -> String {
        guard let until = store.subscription.flatMap({ SourceHealth.shared.pausedUntil(site, origin: $0.origin) }) else {
            return L10n.text("Skipped after repeated failures")
        }
        return L10n.text("Skipped after repeated failures; back in search at %@", until.formatted(date: .omitted, time: .shortened))
    }

    private var failureDetails: some View {
        NavigationStack {
            WithPerceptionTracking {
                List {
                    WithPerceptionTracking {
                        ForEach(model.failures) { result in
                            WithPerceptionTracking {
                                VStack(alignment: .leading, spacing: 6) {
                                    let health = store.health(of: result.site)
                                    HStack(spacing: 6) { Text(result.site.name).font(.headline); SourceHealthDot(status: health) }
                                    Text(result.error ?? "").font(.caption).foregroundStyle(.secondary)
                                    if health == .failing { Text(health.summary).font(.caption).foregroundStyle(Brand.rose) }
                                }
                            }
                        }
                        // Sources this search left out for failing; the retry below asks them too.
                        ForEach(model.paused) { site in
                            WithPerceptionTracking {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 6) { Text(site.name).font(.headline); SourceHealthDot(status: .failing) }
                                    Text(pauseNote(site)).font(.caption).foregroundStyle(Brand.rose)
                                }
                            }
                        }
                    }
                }
                .screenTitle(L10n.text("Unavailable Sources"))
                .screenBackdrop()
                #if os(tvOS)
                .safeAreaInset(edge: .bottom) {
                    WithPerceptionTracking {
                        HStack {
                            Button(L10n.text("Retry failed sources")) {
                                if let config = store.subscription { model.resume(config: config, retryFailures: true) }
                                showFailures = false
                            }.controlButton(prominent: true).disabled(model.busy || (model.failures.isEmpty && model.paused.isEmpty))
                            Spacer()
                            Button(L10n.text("Done")) { showFailures = false }.controlButton()
                        }.padding(32).controlBackdrop()
                    }
                }
                #else
                .toolbar { WithPerceptionTracking {

                        ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { showFailures = false } }
                        ToolbarItem(placement: .primaryAction) {
                            Button(L10n.text("Retry failed sources")) {
                                if let config = store.subscription { model.resume(config: config, retryFailures: true) }
                                showFailures = false
                            }.disabled(model.busy || (model.failures.isEmpty && model.paused.isEmpty))
                        }

                 }}
                #endif
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 380)
        #elseif os(tvOS)
        .frame(width: 1000, height: 650)
        #endif
    }

    private func useHistory(_ item: String) {
        model.draft = item
        if let config = store.subscription { submit(config) }
    }

    private func removeSearch(_ item: String) {
        historyData = (try? JSONEncoder().encode(history.filter { $0 != item })) ?? historyData
    }

    private func rememberQuery(_ query: String? = nil) {
        let keyword = query ?? model.keyword
        guard !keyword.isEmpty else { return }
        historyData = (try? JSONEncoder().encode(Array(([keyword] + history.filter { $0 != keyword }).prefix(20)))) ?? Data()
    }

    #if os(tvOS)
    /// A quarter second after typing stops, so a word spelled out key by key on the remote asks once; a newer draft
    /// cancels the wait and the answer.
    private func suggest(_ draft: String) async {
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else {
            suggested = []
            if trending.isEmpty { trending = await SearchSuggestions.trending() }
            return
        }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        let titles = await SearchSuggestions.titles(for: typed)
        if !Task.isCancelled { suggested = titles }
    }
    #endif

    private func submit(_ config: Subscription) {
        let keyword = model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        rememberQuery(keyword)
        inputFocused = false
        #if os(tvOS)
        entering = false
        #endif
        let preferences = LocalSearchPreferences.load(config: config)
        model.search(keyword, config: config, preferences: preferences) { [store] site in
            preferences.mode == .default && store.hiddenSources.contains(site, origin: config.origin)
        }
    }
}
/// What a running search is doing: overall progress, a time estimate, and one row per plugin
/// source in flight. A first search can spend minutes building plugin components, and the
/// summary count alone looks stuck.
private struct SearchActivityList: View {
    let origin: URL
    let completed: Int
    let total: Int
    let runStart: (date: Date, completed: Int)?
    /// The progress bar always shows; the sources being searched fold behind the chevron.
    let showsSources: Bool
    /// The on-device plugin worker runs at most this many searches at once.
    private let limit = 5
    var body: some View {
        WithPerceptionTracking {
            TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
                WithPerceptionTracking {
                    let active = Array(PluginPreparation.active(origin: origin).prefix(limit))
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 14) {
                            #if os(tvOS)
                            SearchProgressBar(fraction: Double(completed) / Double(max(total, 1)))
                            #else
                            ProgressView(value: Double(completed), total: Double(max(total, 1)))
                                .progressViewStyle(.linear).tint(Brand.accent)
                            #endif
                            if let remaining = remaining(at: timeline.date) {
                                Text(remaining).foregroundStyle(.secondary).monospacedDigit().fixedSize()
                            }
                            if let runStart {
                                Text(Duration.seconds(max(0, Int(timeline.date.timeIntervalSince(runStart.date))))
                                        .formatted(.time(pattern: .minuteSecond)))
                                    .foregroundStyle(.secondary).monospacedDigit().fixedSize()
                            }
                        }
                        if active.contains(where: { $0.snapshot.stage == .converting || $0.snapshot.converted > 0 }) {
                            Label(L10n.text("Preparing plugins for first use. Later searches are much faster."), systemImage: "hourglass")
                                .foregroundStyle(.secondary)
                        }
                        if showsSources {
                            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                                ForEach(active) { item in
                                    WithPerceptionTracking {
                                        GridRow {
                                            Text(item.name).fontWeight(.semibold).lineLimit(1)
                                            Text(status(item.snapshot)).foregroundStyle(.secondary).lineLimit(1)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                            Text(Duration.seconds(max(0, Int(timeline.date.timeIntervalSince(item.snapshot.started))))
                                                    .formatted(.time(pattern: .minuteSecond)))
                                                .monospacedDigit().foregroundStyle(.secondary)
                                                .gridColumnAlignment(.trailing)
                                        }
                                    }
                                }
                            }
                            .transition(.opacity)
                        }
                    }
                    .font(.subheadline)
                    .accessibilityElement(children: .combine)
                    .animation(.appSmooth(duration: 0.25), value: active.map(\.id))
                }
            }
        }
    }
    /// While searching, the plugin's "loading" stage is the search itself.
    private func status(_ snapshot: PluginPreparation.Snapshot) -> String {
        let title = snapshot.stage == .loading ? L10n.text("Searching…") : snapshot.stage.title
        return snapshot.detail.map { "\(title) · \($0)" } ?? title
    }
    /// Extrapolates this run's finishing rate; hidden until a few sources have answered.
    private func remaining(at now: Date) -> String? {
        guard let runStart, total > completed else { return nil }
        let done = completed - runStart.completed
        let elapsed = now.timeIntervalSince(runStart.date)
        guard done >= 3, elapsed >= 20 else { return nil }
        let minutes = Int((elapsed / Double(done) * Double(total - completed) / 60).rounded(.up))
        return minutes <= 1 ? L10n.text("Less than a minute left") : L10n.text("About %lld min left", minutes)
    }
}

#if os(tvOS)
/// Puts `field` in the row of the collapsed sidebar's button, just after it. The system draws that button (the section's
/// symbol and name) at the top left and gives no way to add to its row, so a hidden copy of the name, at the button's
/// font and insets as tvOS 27 draws it, takes its width. tvOS 17 has the tab bar along the top instead: the field
/// goes in the navigation bar under it.
private struct BesideSidebarButton<Field: View>: ViewModifier {
    let title: String
    @ViewBuilder let field: Field
    func body(content: Content) -> some View {
        WithPerceptionTracking {
            if #available(tvOS 18, *) {
                content.overlay(alignment: .topLeading) {
                    WithPerceptionTracking {
                        HStack(spacing: 32) {
                            Text(title).font(.system(size: 31, weight: .medium)).lineLimit(1).fixedSize()
                                .padding(.leading, 83).hidden().accessibilityHidden(true)
                            field.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 58)
                        // Out to the right edge of the results, so pressing up from anywhere on the page reaches it (as a
                        // section, the whole row takes the move): a 560-point field left most of the results with nothing above.
                        // The page sits inside the 80-point side safe area, which this overlay ignores, so it ends where the results do.
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .focusSection()
                        .padding(.leading, 50).padding(.trailing, Layout.gutter + max(80, (1920 - Layout.maxWidth) / 2)).padding(.top, 51)
                        .ignoresSafeArea()
                    }
                }
            } else {
                content.toolbar { WithPerceptionTracking {  ToolbarItem(placement: .navigationBarLeading) { field }   }}
            }
        }
    }
}

/// The search's progress, drawn rather than a linear `ProgressView`. On tvOS that is a UIProgressView, and setting
/// its progress makes UIKit's accessibility ask SwiftUI for the focused element in the middle of a view update.
/// With the remote moving through the results as sources answer, AttributeGraph then loops on the cycle with the
/// main thread at 100%, and the app freezes until it is quit (#325).
private struct SearchProgressBar: View {
    let fraction: Double
    var body: some View {
        WithPerceptionTracking {
            Capsule().fill(Color.primary.opacity(0.2))
                .overlay(alignment: .leading) {
                    WithPerceptionTracking {
                        GeometryReader { proxy in
                            WithPerceptionTracking {
                                Capsule().fill(Brand.accent).frame(width: proxy.size.width * min(1, max(0, fraction)))
                            }
                        }
                    }
                }
                .frame(height: 6)
                .accessibilityElement()
                .accessibilityValue(Text(fraction, format: .percent.precision(.fractionLength(0))))
        }
    }
}
#endif

#if !os(tvOS)
private struct QuietPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        WithPerceptionTracking {
            configuration.label
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 12).frame(height: SourceStrip.controlSize - 2)
                .background(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.07), in: Capsule())
                .contentShape(Capsule())
        }
    }
}
#endif

private extension View {
    @ViewBuilder func searchAction() -> some View {
        #if os(tvOS)
        glassPill()
        #else
        buttonStyle(QuietPillStyle())
        #endif
    }
}

private func uniqueVideos(_ videos: [Video]) -> [Video] {
    var seen = Set<String>()
    return videos.filter { seen.insert($0.id).inserted }
}

struct RecommendationsView: View {
    @Environment(Store.self) private var store
    @Environment(\.openRoute) private var openRoute
    let config: Subscription
    var fixedSite: Site? = nil
    /// Apple TV's Watch Now: the picks as a row of covers, then a row for each of the source's first categories.
    var rails = false
    @AppStorage("recommendationSource") private var sourceKey = ""
    @State private var revision = 0
    @State private var forceRefresh = false
    @State private var choosingSource = false
    /// A source's page opened from its long-press menu, outside a stack that takes `openRoute`.
    @State private var openedSource: Route?
    #if os(tvOS)
    @FocusState private var focusedSource: String?
    /// The long-press action chosen in the source picker, run once its sheet has closed.
    @State private var afterPicker: (() -> Void)?
    #endif
    /// The source category shown instead of its recommendations; nil shows the recommendations.
    @State private var category: String?
    /// The open category's filter choices (key to value), set with `category`.
    @State private var categoryFilters: [String: String] = [:]
    /// The source `category` belongs to. A source change clears it inside the load task, which is the last writer.
    @State private var categorySite: String?
    @State private var browser = CatalogBrowser()
    private var model: RecommendationModel { store.recommendationModel }
    private var sites: [Site] { fixedSite.map { [$0] } ?? store.recommendationSites(config) }
    /// Until the user picks a source, default to the first in strategy order, so opening the app
    /// does not start the JVM when a standard API or script source is available. A source paused for
    /// failing (`SourceHealth.paused`) is passed over unless it is the viewer's pick.
    private var site: Site? {
        sites.first(where: { $0.key == sourceKey })
            ?? sites.first(where: { !SourceHealth.shared.paused($0, origin: config.origin) }) ?? sites.first
    }
    private var requestID: String { "\(config.origin)|\(config.importedAt)|\(site?.key ?? "")|\(revision)|\(model.resetRevision)" }
    private var categoryRequestID: String { "\(requestID)|\(model.site?.key ?? "")|\(category ?? "")|" + categoryFilters.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&") }

    private var recommendationControls: some View {
        HStack(spacing: 12) {
            if let site {
                if fixedSite == nil {
                #if os(tvOS)
                // The name opens the source, as on the Sources page; the switch beside it chooses another.
                Button { openSite(site) } label: {
                    Label(site.name, systemImage: "chevron.right")
                        .lineLimit(1)
                }
                .glassPill()
                .contextMenu { WithPerceptionTracking { sourceActions(site) } }
                .accessibilityIdentifier("recommendations.open")
                Button {
                    // The sheet only where nothing can be pushed.
                    if openRoute != nil { pickSource(site) } else { choosingSource = true }
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                }
                .glassPill()
                .accessibilityLabel(L10n.text("Recommendation Source"))
                .accessibilityIdentifier("recommendations.switch")
                .sheet(isPresented: $choosingSource, onDismiss: { afterPicker?(); afterPicker = nil }) {
                    WithPerceptionTracking {
                        NavigationStack {
                            WithPerceptionTracking {
                                ScrollViewReader { proxy in
                                    WithPerceptionTracking {
                                        ScrollView {
                                            WithPerceptionTracking {
                                                LazyVStack(alignment: .leading, spacing: 4) {
                                                    WithPerceptionTracking {
                                                        ForEach(sites) { candidate in
                                                            WithPerceptionTracking {
                                                                Button { choose(candidate); choosingSource = false } label: {
                                                                    HStack {
                                                                        Text(candidate.name).lineLimit(1)
                                                                        Spacer()
                                                                        if candidate.key == site.key { Image(systemName: "checkmark").foregroundStyle(Brand.accent) }
                                                                    }
                                                                    .frame(maxWidth: .infinity)
                                                                }
                                                                .glassRow()
                                                                .contextMenu { WithPerceptionTracking { sourceActions(candidate) { afterPicker = $0; choosingSource = false } } }
                                                                .focused($focusedSource, equals: candidate.key)
                                                                .id(candidate.key)
                                                            }
                                                        }
                                                    }
                                                }
                                                .glassRowInsets()
                                            }
                                        }
                                        // Open on the current source rather than the top of a long list.
                                        .defaultFocus($focusedSource, site.key)
                                        .onAppear { proxy.scrollTo(site.key, anchor: .center) }
                                    }
                                }
                                .screenTitle(L10n.text("Recommendation Source"))
                                .screenBackdrop()
                            }
                        }
                        .frame(width: 1000, height: 700)
                        .onExitCommand { choosingSource = false }
                    }
                }
                #endif
                }
                Spacer(minLength: 0)
                #if os(tvOS)
                Button { forceRefresh = true; revision += 1 } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .glassPill()
                .disabled(model.busy).accessibilityLabel(L10n.text("Refresh"))
                #else
                Button { forceRefresh = true; revision += 1 } label: {
                    ZStack {
                        if model.busy {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: SourceStrip.controlSize, height: SourceStrip.controlSize)
                    // Liquid Glass where the system draws it, as the source and switch buttons beside it.
                    .glassOrFill(.regular.interactive(), Color.primary.opacity(0.06), in: Circle())
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(model.busy)
                .accessibilityLabel(L10n.text(model.busy ? "Loading…" : "Refresh"))
                .help(L10n.text("Refresh"))
                #endif
            }
        }
    }

    /// Opens the Sources page to choose the source from, as on every platform; choosing comes back here.
    private func pickSource(_ current: Site) {
        let sites = sites, key = current.key
        openRoute?(Route { AnyView(SitesView(pick: { choose($0) }, pickable: sites, picked: key)) })
    }

    #if !os(tvOS)
    /// The chosen source as a capsule that opens it, and a switch beside it that opens the Sources page to choose another.
    private func sourcePickerButton(_ site: Site) -> some View {
        HStack(spacing: 8) {
            sourceNameButton(site)
            Button { pickSource(site) } label: {
                Image(systemName: "arrow.left.arrow.right").font(.subheadline.weight(.semibold))
                    .frame(width: SourceStrip.controlSize, height: SourceStrip.controlSize)
                    .glassOrFill(.regular.interactive(), Color.primary.opacity(0.06), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("Recommendation Source"))
            .accessibilityIdentifier("recommendations.switch")
            #if os(macOS)
            .help(L10n.text("Recommendation Source"))
            #endif
        }
    }

    private func sourceNameButton(_ site: Site) -> some View {
        Button { openSite(site) } label: {
            HStack(spacing: 6) {
                Text(site.name).lineLimit(1)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14).frame(height: SourceStrip.controlSize)
            .glassOrFill(.regular.interactive(), Color.primary.opacity(0.06), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .contextMenu { WithPerceptionTracking { sourceActions(site) } }
        .accessibilityIdentifier("recommendations.open")
    }
    #endif

    /// The source's own page, as choosing it on the Sources page opens.
    private func openSite(_ site: Site) {
        let route = sitePage(site)
        if let openRoute { openRoute(route) } else { openedSource = route }
    }

    /// The source's page, opening on the picks already shown here; it refreshes them and swaps in a different answer.
    private func sitePage(_ site: Site) -> Route {
        let config = config
        var preview: (videos: [Video], categories: [TVCore.Category])?
        if model.site?.key == site.key, !model.busy {
            let videos = model.items.compactMap { item -> Video? in if case .detail(let video) = item.destination { video } else { nil } }
            if !videos.isEmpty, videos.count == model.items.count { preview = (videos, model.categories) }
        }
        return Route { AnyView(SiteView(site: site, origin: config.origin, jarURL: config.spiderURL, preview: preview)) }
    }

    /// Leaving this source drops its open category before the new home loads.
    private func choose(_ candidate: Site) {
        category = nil
        sourceKey = candidate.key
        revision = 0
        forceRefresh = false
    }

    /// The source's picks in a grid, under its categories as chips.
    private var grid: some View {
        VStack(alignment: .leading, spacing: 16) {
            #if os(tvOS)
            recommendationControls.tvFocusSection()
            #else
            if fixedSite == nil, let site, sites.count > 1, openRoute != nil {
                HStack(spacing: 10) {
                    sourcePickerButton(site)
                    Spacer(minLength: 0)
                    recommendationControls.fixedSize()
                }
            } else if fixedSite == nil, let site, sites.count > 1 {
                HStack(spacing: 10) {
                    SourceStrip(items: sites.map { .init(id: $0.key, name: $0.name) }, selection: site.key) { key in
                        // Clear before the key changes. The load task opens a category-only home after it returns;
                        // an onChange that also clears would run after a cached load and wipe that category.
                        if key != sourceKey { category = nil }
                        sourceKey = key; revision = 0; forceRefresh = false
                    } actions: { key in
                        AnyView(sites.first(where: { $0.key == key }).map { sourceActions($0) })
                    }
                    recommendationControls.fixedSize()
                }
            } else {
                HStack(spacing: 16) {
                    Text(L10n.text("Recommendations")).font(.title3.weight(.bold))
                    Spacer()
                    recommendationControls.fixedSize()
                }
            }
            #endif
            if model.busy, let site {
                LoadingCard { .source(site, origin: config.origin, title: L10n.text("Loading recommendations…")) }
            }
            if model.busy && model.items.isEmpty { PosterSkeletonGrid() }
            if let error = model.error {
                Text(error).foregroundStyle(.secondary)
                Button(L10n.text("Retry")) { forceRefresh = true; revision += 1 }
            }
            if let loadedSite = model.site, !model.categories.isEmpty {
                categoryChips(loadedSite).tvFocusSection()
            }
            if let category, let current = model.categories.first(where: { $0.id == category }), !current.filters.isEmpty {
                CategoryFilterBar(filters: current.filters, choices: categoryFilters) { categoryFilters = $0 }.tvFocusSection()
            }
            if category != nil, let loadedSite = model.site {
                categoryContent(loadedSite)
            } else if !model.busy && model.error == nil && model.items.isEmpty {
                Text(L10n.text("This source has no recommendations. Choose another source or use Global Search."))
                    .foregroundStyle(.secondary)
            }
            if category == nil, !model.items.isEmpty, let loadedSite = model.site {
                if (loadedSite.raw["indexs"]?.int ?? 0) == 1 {
                    Text(L10n.text("Choose a title to find it across your sources.")).font(.subheadline).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: Layout.posterColumns, spacing: Layout.gridRowSpacing) {
                    WithPerceptionTracking {
                        ForEach(model.items) { item in
                            WithPerceptionTracking {
                                switch item.destination {
                                case .search(let keyword):
                                    Button { store.searchVideos(keyword) } label: { PosterCard(recommendation: item) }.cardButton()
                                case .detail(let video):
                                    RouteLink {
                                        WithPerceptionTracking {
                                            CatalogDestination(video: video, client: CatalogClient(site: loadedSite, origin: config.origin, jarURL: config.spiderURL))
                                        }
                                    } label: { WithPerceptionTracking { PosterCard(recommendation: item) } }.cardButton()
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .tvFocusSection()
            }
        }
    }

    var body: some View {
        WithPerceptionTracking {
            Group {
                #if os(tvOS)
                if rails { tvRails } else { grid }
                #else
                if rails { phoneRails } else { grid }
                #endif
            }
            .task(id: requestID) {
                let requested = site?.key
                guard let site else { model.reset(); return }
                // Reset here, while this task is the last writer. A later onChange would clear the category
                // a cached home opens below: that home has no posters, so the page would say it has none.
                if categorySite != requested { category = nil; categorySite = requested }
                let refresh = forceRefresh; forceRefresh = false
                await model.load(client: CatalogClient(site: site, origin: config.origin, jarURL: config.spiderURL), subscriptionDate: config.importedAt, force: refresh)
                guard !Task.isCancelled, site.key == requested else { return }
                // A source whose home names only categories (list sites) opens its first one.
                if category == nil, !model.busy, model.error == nil, model.items.isEmpty, let first = model.categories.first {
                    category = first.id; categoryFilters = CategoryFilter.initialChoices(first.filters)
                }
            }
            .task(id: categoryRequestID) {
                // A reset temporarily removes model.site. Reattach must retry this task even when
                // the selected source, category and filters stayed the same throughout the reset.
                // The rows load their own categories.
                guard !rails, let category, let loadedSite = model.site, loadedSite.key == site?.key else { return }
                await browser.load(.list(category: category, query: "", page: 1, filters: categoryFilters),
                                   client: CatalogClient(site: loadedSite, origin: config.origin, jarURL: config.spiderURL))
            }
            .onDisappear { browser.cancel() }
            .appNavigationDestination(item: $openedSource) { route in
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

    #if os(tvOS)
    /// The picks as a row of covers, then a row for each of the source's first four categories, each loaded when it
    /// comes on screen. See All opens the source's page.
    private var tvRails: some View {
        LazyVStack(alignment: .leading, spacing: 30) {
            WithPerceptionTracking {
                HStack(spacing: 24) {
                    Text(L10n.text("Recommendations")).font(.system(size: DiscoverLayout.heading, weight: .semibold)).lineLimit(1)
                    recommendationControls
                }
                .padding(.horizontal, DiscoverLayout.gutter)
                .tvFocusSection()
                // Every category row starts loading with the heading, not when it scrolls on screen: a row that filled in
                // under the remote moved the page.
                .task(id: "\(model.site?.key ?? "")|" + model.categories.prefix(4).map(\.id).joined(separator: ",")) {
                    guard let loadedSite = model.site else { return }
                    let client = CatalogClient(site: loadedSite, origin: config.origin, jarURL: config.spiderURL)
                    for item in model.categories.prefix(4) { WatchNowRows.shared.load(category: item.id, client: client) }
                }
                if let error = model.error {
                    HStack(spacing: 24) {
                        Text(error).foregroundStyle(.secondary)
                        Button(L10n.text("Retry")) { forceRefresh = true; revision += 1 }.controlButton()
                    }
                    .padding(.horizontal, DiscoverLayout.gutter)
                }
                if let loadedSite = model.site, !model.busy || !model.items.isEmpty {
                    let client = CatalogClient(site: loadedSite, origin: config.origin, jarURL: config.spiderURL)
                    let page = sitePage(loadedSite)
                    if !model.items.isEmpty {
                        WatchNowTVRow(seeAll: WatchNowTVSeeAll(height: WatchNowTVCover.height, route: page)) {
                            WithPerceptionTracking {
                                    ForEach(model.items) { item in
                                        WithPerceptionTracking {
                                            let cover = WatchNowTVCover(title: item.name, detail: item.remarks, poster: item.poster?.url, headers: item.poster?.headers ?? [:])
                                            switch item.destination {
                                            case .search(let keyword):
                                                Button { store.searchVideos(keyword) } label: { cover }.cardButton()
                                            case .detail(let video):
                                                RouteLink { WithPerceptionTracking { CatalogDestination(video: video, client: client) } } label: { WithPerceptionTracking { cover } }.cardButton()
                                            }
                                        }
                                    }
                            }
                        }
                    } else if !model.busy, model.error == nil, model.categories.isEmpty {
                        Text(L10n.text("This source has no recommendations. Choose another source or use Global Search."))
                            .foregroundStyle(.secondary).padding(.horizontal, DiscoverLayout.gutter)
                    }
                    ForEach(model.categories.prefix(4)) { item in
                        WithPerceptionTracking {
                            WatchNowTVCategoryRail(title: item.name, category: item.id, client: client, seeAll: page)
                        }
                    }

                } else if model.busy {
                    HStack(spacing: DiscoverLayout.spacing) {
                        ForEach(0..<7, id: \.self) { _ in
                            WithPerceptionTracking {
                                SkeletonBlock(cornerRadius: 12).frame(width: WatchNowTVCover.width, height: WatchNowTVCover.height)
                                    .frame(height: WatchNowTVCover.height + DiscoverLayout.captionHeight, alignment: .top)
                            }
                        }
                    }
                    .padding(.horizontal, DiscoverLayout.gutter).padding(.vertical, 24)
                    .accessibilityLabel(L10n.text("Loading…"))
                }
            }
        }
    }
    #endif

    #if !os(tvOS)
    /// Watch Now on iPhone and the Mac: the picks as a row of covers under the source, then a row for each of its first four
    /// categories, as on Apple TV. A category's heading opens the source's page.
    private var phoneRails: some View {
        VStack(alignment: .leading, spacing: 30) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(L10n.text("Recommendations")).font(.system(size: DiscoverLayout.heading, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 8)
                    recommendationControls.fixedSize()
                }
                if fixedSite == nil, let site, sites.count > 1, openRoute != nil {
                    sourcePickerButton(site)
                }
            }
            .padding(.horizontal, DiscoverLayout.gutter)
            // Every category row starts loading with the heading, not when it scrolls on screen.
            .task(id: "\(model.site?.key ?? "")|" + model.categories.prefix(4).map(\.id).joined(separator: ",")) {
                guard let loadedSite = model.site else { return }
                let client = CatalogClient(site: loadedSite, origin: config.origin, jarURL: config.spiderURL)
                for item in model.categories.prefix(4) { WatchNowRows.shared.load(category: item.id, client: client) }
            }
            if let error = model.error {
                VStack(alignment: .leading, spacing: 10) {
                    Text(error).font(.subheadline).foregroundStyle(.secondary)
                    Button(L10n.text("Retry")) { forceRefresh = true; revision += 1 }.controlButton()
                }
                .padding(.horizontal, DiscoverLayout.gutter)
            }
            if let loadedSite = model.site, !model.busy || !model.items.isEmpty {
                let client = CatalogClient(site: loadedSite, origin: config.origin, jarURL: config.spiderURL)
                let page = sitePage(loadedSite)
                if !model.items.isEmpty {
                    WatchNowPhoneRow {
                        ForEach(model.items) { item in
                            WithPerceptionTracking {
                                let cover = WatchNowPhoneCover(title: item.name, detail: item.remarks, poster: item.poster?.url, headers: item.poster?.headers ?? [:])
                                switch item.destination {
                                case .search(let keyword):
                                    Button { store.searchVideos(keyword) } label: { cover }.tmdbCardButton()
                                case .detail(let video):
                                    RouteLink { WithPerceptionTracking { CatalogDestination(video: video, client: client) } } label: { WithPerceptionTracking { cover } }.tmdbCardButton()
                                }
                            }
                        }
                    }
                    .padding(.top, -16)
                } else if !model.busy, model.error == nil, model.categories.isEmpty {
                    Text(L10n.text("This source has no recommendations. Choose another source or use Global Search."))
                        .font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, DiscoverLayout.gutter)
                }
                ForEach(model.categories.prefix(4)) { item in
                    WithPerceptionTracking {
                        WatchNowPhoneCategoryRail(title: item.name, category: item.id, client: client, seeAll: page)
                    }
                }
            } else if model.busy {
                WatchNowPhoneSkeletonRow().padding(.top, -16)
            }
        }
    }
    #endif

    /// A long press on a source (a right click on Mac): hide it, open its page to search only that source, as the
    /// Sources page does, or go to the Sources page to manage them all. `leave` runs the two that leave Watch Now;
    /// the tvOS picker passes one that closes its sheet first.
    @ViewBuilder private func sourceActions(_ candidate: Site, leave: @escaping (@escaping () -> Void) -> Void = { $0() }) -> some View {
        HideSourceButton(site: candidate, origin: config.origin)
        Button {
            leave {
                let route = Route { AnyView(SiteView(site: candidate, origin: config.origin, jarURL: config.spiderURL)) }
                if let openRoute { openRoute(route) } else { openedSource = route }
            }
        } label: { Label(L10n.text("Search This Source"), systemImage: "magnifyingglass") }
            .accessibilityIdentifier("source.search." + candidate.key)
        Button { leave { store.section = .sites } } label: { Label(L10n.text("Manage Sources"), systemImage: AppSection.sites.icon) }
    }

    private func categoryChips(_ loadedSite: Site) -> some View {
        ChipRow {
            HStack(spacing: 8) {
                if !model.items.isEmpty {
                    Chip(title: L10n.text("Recommendations"), selected: category == nil) { category = nil }
                }
                ForEach(model.categories) { item in
                    WithPerceptionTracking {
                        Chip(title: item.name, selected: category == item.id) {
                            category = item.id; categoryFilters = CategoryFilter.initialChoices(item.filters)
                        }
                    }
                }
            }.padding(.vertical, 4)
        }
    }

    @ViewBuilder private func categoryContent(_ loadedSite: Site) -> some View {
        let client = CatalogClient(site: loadedSite, origin: config.origin, jarURL: config.spiderURL)
        let isIndex = (loadedSite.raw["indexs"]?.int ?? 0) == 1
        if browser.busy && browser.videos.isEmpty { PosterSkeletonGrid() }
        if let error = browser.error {
            Text(error).foregroundStyle(.secondary)
            Button(L10n.text("Retry")) { Task { await browser.load(browser.request, client: client) } }
        }
        if !browser.videos.isEmpty {
            if isIndex {
                Text(L10n.text("Choose a title to find it across your sources.")).font(.subheadline).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: Layout.posterColumns, spacing: Layout.gridRowSpacing) {
                WithPerceptionTracking {
                    ForEach(browser.videos) { video in
                        WithPerceptionTracking {
                            Group {
                                if isIndex {
                                    Button { store.searchVideos(video.name) } label: { PosterCard(video: video) }.cardButton()
                                } else {
                                    RouteLink { WithPerceptionTracking { CatalogDestination(video: video, client: client) } } label: { WithPerceptionTracking { PosterCard(video: video) } }.cardButton()
                                }
                            }
                            .onAppear {
                                // The last cover coming on screen appends the next page, so scrolling never stops
                                // at a page boundary. A failed page waits for the footer's Retry instead.
                                guard browser.moreError == nil, video.id == browser.videos.last?.id else { return }
                                Task { await browser.loadMore(client: client) }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(browser.busy ? 0.55 : 1)
            .tvFocusSection()
            // A focus section, so moving down from a cover in any column reaches Load More or Try Again.
            Group {
                if let message = browser.moreError {
                    VStack(spacing: 12) {
                        Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button(L10n.text("Try Again")) { Task { await browser.loadMore(client: client) } }
                            .controlButton()
                            .accessibilityIdentifier("recommendations.loadMore.retry")
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                } else if browser.loadingMore {
                    ProgressView().controlSize(.large)
                        .frame(maxWidth: .infinity).padding(.vertical, 24)
                        .accessibilityLabel(L10n.text("Loading…"))
                } else if browser.hasMore {
                    Button(L10n.text("Load More")) { Task { await browser.loadMore(client: client) } }
                        .controlButton()
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                        .accessibilityIdentifier("recommendations.loadMore")
                }
            }
            .tvFocusSection()
        }
    }
}

#if !os(tvOS)
/// Recommendation source picker. It is its own view so scrolling and dragging
/// re-render only the strip, never the poster grid below it.
struct SourceStrip: View {
    #if os(macOS)
    static let controlSize: CGFloat = 30
    #else
    static let controlSize: CGFloat = 44
    #endif
    struct Item: Identifiable {
        let id: String
        let name: String
        var count: Int? = nil
        var dot: Color? = nil
    }
    let items: [Item]
    let selection: String
    var horizontalInset: CGFloat = 0
    let select: (String) -> Void
    /// A chip's long-press (right-click) menu, by item id.
    var actions: ((String) -> AnyView)? = nil

    var body: some View {
        WithPerceptionTracking {
            ScrollStrip(scrollTo: selection, leftLabel: "Scroll sources left", rightLabel: "Scroll sources right") {
                WithPerceptionTracking {
                    HStack(spacing: 6) {
                        ForEach(items) { item in
                            WithPerceptionTracking {
                                let chip = SourceChip(name: item.name, count: item.count, dot: item.dot, selected: item.id == selection) { select(item.id) }
                                Group {
                                    if let actions { chip.contextMenu { WithPerceptionTracking { actions(item.id) } } } else { chip }
                                }
                                .id(item.id)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, horizontalInset)
                    .appScrollTargetLayout()
                }
            }
        }
    }
}

/// Outside ScrollStrip so measuring it in a sendable closure does not capture the generic content type.
private struct ScrollStripMetrics: Equatable { var offset: CGFloat, viewport: CGFloat, maximum: CGFloat }
private struct ScrollStripLegacyFrame: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}
private struct ScrollStripLegacyWidth: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// A horizontal row of chips or cards. A mouse wheel cannot scroll sideways, so on Mac the row can
/// also be dragged like a trackpad swipe and shows arrow buttons once it overflows. Elsewhere it is
/// a plain horizontal scroll view (touch on iOS; tvOS rows stay focus-driven and do not use it).
struct ScrollStrip<Content: View>: View {
    let scrollTo: String?
    let leftLabel: String
    let rightLabel: String
    /// Floats the arrows over the strip's ends instead of beside it, for strips that run edge to edge,
    /// centred this far from the strip's top (the middle of its artwork), or on the strip when nil.
    var overlayArrows = false
    var arrowCenter: CGFloat?
    let content: Content
    #if os(macOS)
    @State private var position = ScrollPosition(idType: String.self)
    #endif
    @State private var edges = Edges()
    /// Live geometry and drag state. A plain reference, so updating it never invalidates the view.
    @State private var tracking = Tracking()
    @Namespace private var legacyCoordinateSpace

    init(scrollTo: String? = nil, leftLabel: String = "Scroll left", rightLabel: String = "Scroll right",
         overlayArrows: Bool = false, arrowCenter: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.scrollTo = scrollTo
        self.leftLabel = leftLabel
        self.rightLabel = rightLabel
        self.overlayArrows = overlayArrows
        self.arrowCenter = arrowCenter
        self.content = content()
    }

    private struct Edges: Equatable { var leading = false, trailing = false }
    private typealias Metrics = ScrollStripMetrics
    @MainActor private final class Tracking {
        var metrics = Metrics(offset: 0, viewport: 0, maximum: 0)
        var dragOrigin: CGFloat?
        var legacyFrame = CGRect.zero
        var legacyWidth: CGFloat = 0
        let drag = StripDrag()
        func clamp(_ x: CGFloat) -> CGFloat { min(metrics.maximum, max(0, x)) }
    }

    var body: some View {
        WithPerceptionTracking {
            ScrollViewReader { proxy in
                WithPerceptionTracking {
                    HStack(spacing: 8) {
                        measured(
                            ScrollView(.horizontal, showsIndicators: false) {
                                WithPerceptionTracking {
                                    measuredContent
                                }
                            }
                            #if os(macOS)
                            .scrollPosition($position)
                            #endif
                        )
                        .mask {
                            WithPerceptionTracking {
                                HStack(spacing: 0) {
                                    LinearGradient(colors: [edges.leading ? .clear : .black, .black], startPoint: .leading, endPoint: .trailing)
                                        .frame(width: 20)
                                    Rectangle()
                                    LinearGradient(colors: [.black, edges.trailing ? .clear : .black], startPoint: .leading, endPoint: .trailing)
                                        .frame(width: 28)
                                }
                            }
                        }
                        .environment(\.stripDrag, tracking.drag)
                        #if os(macOS)
                        .simultaneousGesture(dragToScroll)
                        .overlay(alignment: arrowCenter == nil ? .center : .top) {
                            WithPerceptionTracking {
                                if overlayArrows {
                                    HStack {
                                        if edges.leading { arrow(forward: false) }
                                        Spacer(minLength: 0)
                                        if edges.trailing { arrow(forward: true) }
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.top, arrowCenter.map { max(0, $0 - 17) } ?? 0)
                                }
                            }
                        }
                        #endif
                        #if os(macOS)
                        if !overlayArrows, edges.leading || edges.trailing {
                            HStack(spacing: 4) { arrow(forward: false); arrow(forward: true) }
                        }
                        #endif
                    }
                    .onAppear {
                        guard let scrollTo else { return }
                        #if os(macOS)
                        position.scrollTo(id: scrollTo, anchor: .center)
                        #else
                        proxy.scrollTo(scrollTo, anchor: .center)
                        #endif
                    }
                }
            }
        }
    }

    private func update(_ metrics: Metrics) {
        tracking.metrics = metrics
        let next = Edges(leading: metrics.offset > 1, trailing: metrics.offset < metrics.maximum - 1)
        if next != edges { edges = next }
    }

    @ViewBuilder private func measured(_ scrollView: some View) -> some View {
        if #available(iOS 18, *) {
            scrollView.onScrollGeometryChange(for: Metrics.self) { geometry in
                Metrics(offset: geometry.contentOffset.x + geometry.contentInsets.leading,
                        viewport: geometry.containerSize.width,
                        maximum: max(0, geometry.contentSize.width + geometry.contentInsets.leading
                            + geometry.contentInsets.trailing - geometry.containerSize.width))
            } action: { _, metrics in update(metrics) }
        } else if #available(iOS 17, macOS 14, tvOS 17, *) {
            scrollView
        } else {
            scrollView.coordinateSpace(name: legacyCoordinateSpace)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: ScrollStripLegacyWidth.self, value: geometry.size.width)
                    }
                }
                .onPreferenceChange(ScrollStripLegacyWidth.self) { width in
                    MainActor.assumeIsolated {
                        tracking.legacyWidth = width
                        updateLegacyMetrics()
                    }
                }
        }
    }

    /// Before iOS 18 the scroll view cannot report its geometry, so the content measures the part of
    /// itself that is on screen.
    @ViewBuilder private var measuredContent: some View {
        if #available(iOS 18, *) {
            content
        } else if #available(iOS 17, macOS 14, tvOS 17, *) {
            content.onGeometryChange(for: Metrics.self) { geometry in
                let visible = geometry.bounds(of: .scrollView(axis: .horizontal)) ?? .zero
                return Metrics(offset: visible.minX, viewport: visible.width, maximum: max(0, geometry.size.width - visible.width))
            } action: { update($0) }
        } else {
            content
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: ScrollStripLegacyFrame.self,
                                               value: geometry.frame(in: .named(legacyCoordinateSpace)))
                    }
                }
                .onPreferenceChange(ScrollStripLegacyFrame.self) { frame in
                    MainActor.assumeIsolated {
                        tracking.legacyFrame = frame
                        updateLegacyMetrics()
                    }
                }
        }
    }

    private func updateLegacyMetrics() {
        let width = tracking.legacyWidth
        let frame = tracking.legacyFrame
        update(Metrics(offset: -frame.minX, viewport: width, maximum: max(0, frame.width - width)))
    }

    #if os(macOS)
    /// Mouse users can grab the strip like a trackpad swipe, with momentum on release.
    private var dragToScroll: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let origin = tracking.dragOrigin ?? tracking.metrics.offset
                tracking.dragOrigin = origin
                tracking.drag.active = true
                position.scrollTo(x: tracking.clamp(origin - value.translation.width))
            }
            .onEnded { value in
                let origin = tracking.dragOrigin ?? tracking.metrics.offset
                tracking.dragOrigin = nil
                withAnimation(.appSmooth(duration: 0.45)) {
                    position.scrollTo(x: tracking.clamp(origin - value.predictedEndTranslation.width))
                }
                let drag = tracking.drag
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(120))
                    drag.active = false
                }
            }
    }

    private func arrow(forward: Bool) -> some View {
        let enabled = forward ? edges.trailing : edges.leading
        let label = L10n.text(forward ? rightLabel : leftLabel)
        return Button {
            let step = max(1, tracking.metrics.viewport * 0.8)
            withAnimation(.appSmooth(duration: 0.3)) {
                position.scrollTo(x: tracking.clamp(tracking.metrics.offset + (forward ? step : -step)))
            }
        } label: {
            Image(systemName: forward ? "chevron.right" : "chevron.left")
                .font(.system(size: overlayArrows ? 14 : 11, weight: .bold))
                .frame(width: overlayArrows ? 34 : 26, height: overlayArrows ? 34 : 26)
                .background(Color.primary.opacity(0.07), in: Circle())
                .glassSurface(overlayArrows ? .regular.interactive() : .identity, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? .primary : .tertiary)
        .disabled(!enabled)
        .accessibilityLabel(label)
        .help(label)
    }
    #endif
}

/// Flat capsule chip: cheap to draw in long rows, high contrast only for the selection.
private struct SourceChip: View {
    let name: String
    var count: Int? = nil
    var dot: Color? = nil
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.stripDrag) private var drag
    @Environment(\.glassControls) private var glass

    var body: some View {
        WithPerceptionTracking {
            let label = SourceLabel(name)
            // The chip under the pointer receives the mouse-up that ends a drag.
            Button { if drag?.active != true { action() } } label: {
                HStack(spacing: 6) {
                    if name == CloudSources.site(where: \.isBilibili)?.name { BilibiliGlyph(size: 15).foregroundStyle(selected ? Brand.onAccent : BilibiliMark.blue) } else if let symbol = label.symbol { Text(symbol) }
                    Text(label.title).lineLimit(1)
                    if let count { Text("\(count)").monospacedDigit().opacity(0.55) }
                    if let dot { Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(dot) }
                }
                .font(.system(size: 13, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? Brand.onAccent : Color.primary.opacity(0.82))
                .padding(.horizontal, 12)
                .frame(height: SourceStrip.controlSize)
                .glassOrFill(glass ? (selected ? GlassStyle.regular.tint(Brand.accent).interactive() : .regular.interactive()) : nil, fill, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(.appSmooth(duration: 0.15), value: hovering)
            .animation(.appSmooth(duration: 0.2), value: selected)
            .accessibilityLabel(label.title)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            .help(name)
        }
    }

    private var fill: Color {
        if selected { return Brand.accent }
        return Color.primary.opacity(hovering ? 0.12 : 0.06)
    }
}

#endif

/// Source names often pack a leading emoji and box-drawing separators ("🌕┃片单┃精选").
/// Split them into a symbol and a readable title ("片单 · 精选").
struct SourceLabel {
    var symbol: String?
    var title: String
    /// The name's segments ("片单", "精选"); the first is the source's own name, the rest are taglines.
    var parts: [String]
    var text: String { [symbol, title].compactMap { $0 }.joined(separator: " ") }
    init(_ name: String) {
        var text = Substring(name.trimmingCharacters(in: .whitespaces))
        if let first = text.first, first.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation || $0.value == 0xFE0F }) {
            symbol = String(first)
            text = text.dropFirst()
        }
        let parts = text.split(whereSeparator: { character in
            "|｜丨¦·・".contains(character)
                || character.unicodeScalars.allSatisfy { (0x2500...0x257F).contains($0.value) } // box drawing
        })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        self.parts = parts.isEmpty ? [name] : parts
        title = self.parts.joined(separator: " · ")
    }
}
