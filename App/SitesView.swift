import CoreImage
import SwiftUI
import Perception
import TVCore

private struct SourcePanelFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { _, new in new } }
}

struct SitesView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// Choosing a source for something else (Watch Now's recommendations): only `pickable` sources are listed, the
    /// `picked` one is checked, and Select hands the source back and returns instead of opening it.
    var pick: ((Site) -> Void)? = nil
    var pickable: [Site] = []
    var picked: String? = nil
    var panelKind: String? = nil
    var builtinHome: (() -> Void)? = nil
    var homeSelected = false
    @FocusState private var focusedSite: String?
    @State private var query = ""
    /// Groups the viewer folded. Every group starts open, subscriptions and hidden sources included,
    /// so nothing on the page needs finding, and stays as the viewer left it: a fold is saved and comes
    /// back on the next visit and launch (#517). Picking a source always starts open, so the current
    /// choice can be shown. `prepared` keeps the reload to once per visit, not per pushed source.
    @State private var collapsed: Set<String>
    @State private var prepared = false
    /// The fold as it was when a search began; restored when the search is cleared.
    @State private var foldBeforeSearch: Set<String>?
    @State private var arranging = false
    @State private var choosingHidden = false
    @State private var rememberedRow: String?
    @State private var restoringPanelPosition = true
    private var panelKey: String { "local.source.panel." + (panelKind ?? (pickable.allSatisfy { $0.runtime == .python } && !pickable.isEmpty ? "python" : "sites")) }
    init(pick: ((Site) -> Void)? = nil, pickable: [Site] = [], picked: String? = nil, panelKind: String? = nil,
         builtinHome: (() -> Void)? = nil, homeSelected: Bool = false) {
        self.pick = pick
        self.pickable = pickable
        self.picked = picked
        self.panelKind = panelKind
        self.builtinHome = builtinHome
        self.homeSelected = homeSelected
        _collapsed = State(initialValue: pick == nil ? Self.savedFold : [])
        let kind = panelKind ?? (pickable.allSatisfy { $0.runtime == .python } && !pickable.isEmpty ? "python" : "sites")
        _rememberedRow = State(initialValue: UserDefaults.standard.string(forKey: "local.source.panel." + kind + ".row"))
    }
    private static let foldKey = "sources.foldedGroups"
    private static var savedFold: Set<String> { Set(UserDefaults.standard.stringArray(forKey: foldKey) ?? []) }
    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                #if os(iOS)
                if panelKind != nil {
                    panelSearch
                }
                #endif
                Group {
                    if let config = store.subscription {
                        sourceList(config)
                    } else {
                        ScrollView {
                            VStack(spacing: 16) {
                                builtinHomeButton.padding(.horizontal, 16)
                                AppContentUnavailableView(L10n.text("No Sources Yet"), systemImage: "square.grid.2x2", description: Text(L10n.text("Add a TVBox subscription in Settings.")))
                            }
                        }
                    }
                }
            }
            .screenBackdrop()
            .modifier(SitesSearch(query: $query, embedded: panelKind != nil))
            .modifier(SitesTitle(picking: pick != nil, embedded: panelKind != nil))
            .task(id: store.section) {
                if store.section == .sites && !prepared {
                    applyDefaultFold()
                    prepared = true
                }
            }
            .appOnChange(of: store.section) { _, new in
                if new != .sites { prepared = false }
            }
            .appOnChange(of: query) { old, new in
                if old.isEmpty && !new.isEmpty {
                    foldBeforeSearch = collapsed
                    collapsed = []
                } else if !old.isEmpty && new.isEmpty, let saved = foldBeforeSearch {
                    collapsed = saved
                    foldBeforeSearch = nil
                }
            }
        }
    }

    #if os(iOS)
    private var panelSearch: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(panelKind == "python" ? "筛选 python 脚本名称" : "筛选站点名称", text: $query)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .submitLabel(.search).accessibilityIdentifier("source.panel.search")
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("清除来源搜索")
            }
        }
        .padding(.leading, 12).frame(minHeight: 44)
        .localGlassInputSurface()
        .padding(.horizontal, 16).padding(.bottom, 10)
    }
    #endif


    private func sourceList(_ config: Subscription) -> some View {
        let groups = visibleSourceGroups.filtered(by: query).limited(to: pick == nil ? nil : Set(pickable.map(\.key)))
        let sites = panelKind == nil ? store.orderedSites(config) : pickable
        return ScrollViewReader { proxy in
            WithPerceptionTracking {
                ScrollView {
                    WithPerceptionTracking {
                        Group {
                            if panelKind != nil {
                                VStack(spacing: Layout.cardSpacing) {
                                    builtinHomeButton
                                    sourcePickerGrid(groups, sites: sites, config: config)
                                }
                            } else {
                                sourceGroups(groups, sites: sites, config: config)
                            }
                        }.pageContainer()
                            #if os(iOS)
                            .background {
                                if pick != nil {
                                    LocalSourcePanelScrollPosition(storageKey: panelKey, enabled: query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                }
                            }
                            #endif
                    }
                }
                .coordinateSpace(name: "source.panel")
                .accessibilityIdentifier(pick == nil ? "source.list.scroll" : "source.panel.scroll")
                .onPreferenceChange(SourcePanelFrames.self) { frames in
                    MainActor.assumeIsolated {
                        guard pick != nil, query.isEmpty, !restoringPanelPosition else { return }
                        let first = frames.filter { $0.value.maxY > 0 }.min {
                            $0.value.minY == $1.value.minY ? $0.value.minX < $1.value.minX : $0.value.minY < $1.value.minY
                        }?.key
                        if let first, first != rememberedRow { rememberedRow = first; UserDefaults.standard.set(first, forKey: panelKey + ".row") }
                    }
                }
                .onAppear {
                    if pick != nil {
                        let chosen = picked ?? UserDefaults.standard.string(forKey: panelKey + ".chosen")
                        focusedSite = chosen
                    }
                }
                .task(id: query) {
                    guard pick != nil else { return }
                    restoringPanelPosition = true
                    guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    let row = rememberedRow ?? picked ?? UserDefaults.standard.string(forKey: panelKey + ".chosen")
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    #if os(iOS)
                    if !LocalSourcePanelScrollPosition.hasSavedPosition(for: panelKey), let row { proxy.scrollTo(row, anchor: .top) }
                    #else
                    if let row { proxy.scrollTo(row, anchor: .top) }
                    #endif
                    await Task.yield()
                    if !Task.isCancelled { restoringPanelPosition = false }
                }
            }
        }
        .sheet(isPresented: $arranging) { WithPerceptionTracking { SourceOrderEditor(sites: sites, automatic: store.automaticSites(config)) } }
        .sheet(isPresented: $choosingHidden) { WithPerceptionTracking { HiddenSourcesEditor() } }
    }

    private var visibleSourceGroups: [SourceGroup] {
        let groups = store.sourceGroups(includeHidden: false)
        #if os(iOS)
        return groups.compactMap { group in
            var visible = group
            visible.sites.removeAll(where: \.isBuiltIn)
            return visible.sites.isEmpty ? nil : visible
        }
        #else
        return groups
        #endif
    }

    private func sourceGroups(_ groups: [SourceGroup], sites: [Site], config: Subscription) -> some View {
        LazyVStack(alignment: .leading, spacing: Layout.cardSpacing) {
            WithPerceptionTracking {
                if panelKind == nil { builtinHomeButton }
                if pick == nil, query.isEmpty && sites.count > 1 {
                    VStack(alignment: .leading, spacing: Layout.cardSpacing) {
                        SourceOrderCard(sites: sites) { arranging = true }
                        HideSourcesCard(hidden: groups.first { $0.kind == .hidden }?.sites.count ?? 0) { choosingHidden = true }
                    }.tvFocusSection()
                }
                ForEach(groups) { group in
                    WithPerceptionTracking {
                        groupHeader(group)
                        if !collapsed.contains(group.id) {
                            sourceGrid(group, sites: sites, config: config)
                                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -16)), removal: .opacity))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var builtinHomeButton: some View {
        if let builtinHome {
            Button {
                builtinHome()
                dismiss()
            } label: {
                Text("首页").font(.headline).frame(maxWidth: .infinity, minHeight: 64)
                .overlay(alignment: .leading) { MonogramIcon(seed: "首页", label: SourceLabel("首页"), size: 34, systemImage: "house.fill").padding(.leading, 14) }
                .overlay(alignment: .trailing) {
                    if homeSelected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.accent).padding(.trailing, 14) }
                }
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 15))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityIdentifier("home.source.builtin")
            .accessibilityAddTraits(homeSelected ? .isSelected : [])
        }
    }

    private func sourceGrid(_ group: SourceGroup, sites: [Site], config: Subscription) -> some View {
        LazyVGrid(columns: sourceColumns, spacing: Layout.cardSpacing) {
            WithPerceptionTracking {
                ForEach(group.sites) { site in
                    WithPerceptionTracking { sourceCard(site, dimmed: group.kind == .hidden, sites: sites, config: config) }
                }
            }
        }
    }

    private func sourcePickerGrid(_ groups: [SourceGroup], sites: [Site], config: Subscription) -> some View {
        let eligible = Set(groups.filter { $0.kind != .hidden }.flatMap(\.sites).map(\.key))
        return LazyVGrid(columns: sourceColumns, spacing: Layout.cardSpacing) {
            ForEach(sites.filter { eligible.contains($0.key) }) { site in
                WithPerceptionTracking {
                    sourceCard(site, dimmed: false, sites: sites, config: config)
                }
            }
        }
    }

    private var sourceColumns: [GridItem] {
        #if os(iOS)
        [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        #else
        Layout.cardColumns
        #endif
    }

    @ViewBuilder private func sourceTile(_ site: Site, dimmed: Bool = false, chosen: Bool? = nil) -> some View {
        #if os(iOS)
        LocalSourcePanelTile(site: site, dimmed: dimmed, chosen: chosen)
        #else
        SiteCard(site: site, dimmed: dimmed, chosen: chosen)
        #endif
    }

    @ViewBuilder private func sourceCard(_ site: Site, dimmed: Bool, sites: [Site], config: Subscription) -> some View {
        if let pick {
            Button {
                UserDefaults.standard.set(site.key, forKey: panelKey + ".chosen")
                rememberedRow = site.key; UserDefaults.standard.set(site.key, forKey: panelKey + ".row")
                if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    #if os(iOS)
                    LocalSourcePanelScrollPosition.clearPosition(for: panelKey)
                    #endif
                }
                pick(site); dismiss()
            } label: { sourceTile(site, chosen: site.key == (picked ?? UserDefaults.standard.string(forKey: panelKey + ".chosen"))) }.tileButton()
                .accessibilityAddTraits(site.key == picked ? .isSelected : [])
                .accessibilityIdentifier("source." + site.key)
                .focused($focusedSite, equals: site.key).id(site.key)
                #if !os(iOS)
                .background { GeometryReader { geometry in Color.clear.preference(key: SourcePanelFrames.self, value: [site.key: geometry.frame(in: .named("source.panel"))]) } }
                #endif
        } else {
            RouteLink { WithPerceptionTracking { SiteView(site: site, origin: config.origin, jarURL: config.spiderURL) } } label: {
                WithPerceptionTracking { sourceTile(site, dimmed: dimmed) }
            }
            .tileButton()
            .accessibilityIdentifier("source." + site.key)
            .contextMenu {
                WithPerceptionTracking {
                    PinSourceButton(site: site, origin: config.origin)
                    HideSourceButton(site: site, origin: config.origin)
                    if store.sourceOrder.enabled { MoveSourceButtons(site: site, sites: sites) }
                }
            }
        }
    }

    @ViewBuilder
    private func groupHeader(_ group: SourceGroup) -> some View {
        let open = !collapsed.contains(group.id)
        let header = Button {
            withAnimation(.appSnappy(duration: 0.3)) {
                if open { collapsed.insert(group.id) } else { collapsed.remove(group.id) }
            }
            // A search opens every group for the moment; only the page's own fold is kept.
            if pick == nil && query.isEmpty { UserDefaults.standard.set(collapsed.sorted(), forKey: Self.foldKey) }
        } label: {
            HStack(spacing: 8) {
                Text(L10n.text(group.title)).font(.headline).lineLimit(1)
                Text("\(group.sites.count)").font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                Spacer(minLength: 8)
                // One chevron that turns, rather than two symbols swapped.
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(open ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("sources.group." + group.id)
        #if !os(tvOS)
        if case .subscription = group.kind, query.isEmpty {
            header
                .draggable(group.id)
                .dropDestination(for: String.self) { items, _ in
                    guard query.isEmpty, let address = items.first else { return false }
                    store.moveSourceGroup(address, onto: group.id, includeHidden: false)
                    return true
                }
        } else {
            header
        }
        #else
        header
        #endif
    }

    /// The page as the viewer last left it: every group open unless they folded it.
    private func applyDefaultFold() {
        collapsed = pick == nil ? Self.savedFold : []
        foldBeforeSearch = nil
    }
}

/// The Sources tab names itself in the sidebar; a page pushed to pick a source says what is being chosen.
private struct SitesTitle: ViewModifier {
    let picking: Bool
    var embedded = false
    func body(content: Content) -> some View {
        WithPerceptionTracking {
            if embedded { content }
            else if picking { content.screenTitle(L10n.text("Recommendation Source")) } else { content.tabTitle(L10n.text("Sources")) }
        }
    }
}

private struct SitesSearch: ViewModifier {
    @Binding var query: String
    let embedded: Bool
    @ViewBuilder func body(content: Content) -> some View {
        #if os(iOS)
        if embedded { content }
        else { content.catalogSearchable(text: $query, prompt: L10n.text("Find a source")) }
        #else
        content.catalogSearchable(text: $query, prompt: L10n.text("Find a source"))
        #endif
    }
}

private extension Array where Element == SourceGroup {
    /// Only these sources, when given; groups left empty drop out.
    func limited(to keys: Set<String>?) -> [SourceGroup] {
        guard let keys else { return self }
        return compactMap { group in
            var kept = group
            kept.sites = group.sites.filter { keys.contains($0.key) }
            return kept.sites.isEmpty ? nil : kept
        }
    }

    /// Sites whose name contains the query, ignoring case; groups left empty drop out.
    func filtered(by query: String) -> [SourceGroup] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return self }
        return compactMap { group in
            var kept = group
            kept.sites = group.sites.filter { site in terms.allSatisfy { site.name.localizedCaseInsensitiveContains($0) } }
            return kept.sites.isEmpty ? nil : kept
        }
    }
}

extension Store {
    /// How a source has been answering lately; see `SourceHealth`.
    func health(of site: Site) -> SourceHealth.Status {
        subscription.map { SourceHealth.shared.status(site, origin: $0.origin) } ?? .unknown
    }
}

extension SourceHealth.Status {
    /// The dot that marks it; none until the source has been asked.
    var tint: Color? {
        switch self {
        case .unknown: nil
        case .healthy: .green
        case .unstable: Brand.amber
        case .failing: Brand.rose
        }
    }
    /// Only trouble: in search results every listed source has just answered.
    var warning: Color? { self == .unstable || self == .failing ? tint : nil }
    var summary: String {
        switch self {
        case .unknown: ""
        case .healthy: L10n.text("Responding normally")
        case .unstable: L10n.text("Slow or unreliable lately")
        case .failing: L10n.text("Failing; skipped in search for now")
        }
    }
}

/// A source's health as a dot beside its name.
struct SourceHealthDot: View {
    let status: SourceHealth.Status
    #if os(tvOS)
    private let size: CGFloat = 14
    #else
    private let size: CGFloat = 8
    #endif
    var body: some View {
        WithPerceptionTracking {
            if let tint = status.tint {
                Image(systemName: "circle.fill").font(.system(size: size)).foregroundStyle(tint).accessibilityLabel(status.summary)
            }
        }
    }
}

/// A source as an app-icon tile plus its name: the name's emoji becomes the icon, its taglines
/// ("不卡", "秒播") and engine a quiet second line, so a page of sources reads like a launcher
/// rather than a wall of identical badges. Use with `tileButton()`: on tvOS the card lights up itself.
struct SiteCard: View {
    @Environment(Store.self) private var store
    @Environment(\.isFocused) private var isFocused
    let site: Site
    /// A source the viewer hid, shown only while hidden sources are revealed.
    var dimmed = false
    /// The pin badge on the icon; off in Watch Now's Pinned Sources, where every card is pinned.
    var marksPinned = true
    /// Whether this is the source currently chosen, when picking one (`SitesView.pick`); nil when not picking.
    var chosen: Bool? = nil
    #if os(tvOS)
    private var focused: Bool { isFocused }
    private let icon: CGFloat = 88, padding: CGFloat = 20, radius: CGFloat = 28
    #else
    private let icon: CGFloat = 48, padding: CGFloat = 12, radius: CGFloat = 16
    // Keyboard focus on the Mac must not turn the text black on a dark panel.
    private let focused = false
    #endif
    var body: some View {
        WithPerceptionTracking {
            let label = SourceLabel(site.name)
            let pinned = marksPinned && (store.subscription.map { store.pinnedSources.contains(site, origin: $0.origin) } ?? false)
            let runs = site.isBuiltIn || site.canBrowse(jarURL: store.subscription?.spiderURL)
            let detail = runs ? (label.parts.dropFirst() + [engine].compactMap { $0 }).joined(separator: " · ") : site.compatibility
            HStack(spacing: padding) {
                SourceIcon(site: site, label: label, size: icon)
                    .opacity(runs ? 1 : 0.45)
                    // A badge on the icon, not another line, so pinned cards keep the grid's height.
                    .overlay(alignment: .bottomTrailing) {
                        WithPerceptionTracking {
                            if pinned {
                                Image(systemName: "pin.fill").font(.system(size: icon * 0.18, weight: .bold)).foregroundStyle(Brand.onAccent)
                                    .frame(width: icon * 0.36, height: icon * 0.36).background(Brand.accent, in: Circle())
                                    .overlay { WithPerceptionTracking { Circle().strokeBorder(.black.opacity(0.35), lineWidth: 1) } }
                                    .offset(x: icon * 0.1, y: icon * 0.1)
                                    .accessibilityLabel(L10n.text("Pinned"))
                            }
                        }
                    }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(label.parts[0]).font(.headline).lineLimit(1)
                            .foregroundStyle(focused ? Color.black : runs ? Color.primary : Color.secondary)
                        if runs { SourceHealthDot(status: store.health(of: site)) }
                        if site.runtime == .python {
                            Text(store.health(of: site) == .failing ? "待重试" : store.health(of: site) == .healthy ? "就绪" : "待机")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if dimmed { Text(L10n.text("Hidden")).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    if !detail.isEmpty {
                        Text(detail).font(.subheadline).lineLimit(1)
                            .foregroundStyle(focused ? Color.black.opacity(0.6) : runs ? Color.secondary : Brand.amber)
                    }
                }
                Spacer(minLength: 0)
                if chosen == true {
                    Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(focused ? Color.black : Brand.accent)
                        .accessibilityHidden(true)
                }
                #if !os(tvOS)
                if chosen == nil { Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary) }
                #endif
            }
            .padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background { WithPerceptionTracking { TileSurface(focused: focused, radius: radius) } }
            .accessibilityElement(children: .combine)
            .opacity(dimmed ? 0.45 : 1)
        }
    }

    /// Which engine runs a source is an implementation detail; only built-in sources say so.
    private var engine: String? { site.isBuiltIn ? L10n.text("Built-in") : nil }
}

/// A launcher tile's own surface (source cards, live playlists).
struct TileSurface: View {
    var focused: Bool
    var radius: CGFloat
    var body: some View {
        WithPerceptionTracking {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            #if os(tvOS)
            // Like the system's focused buttons: a quiet tile at rest, a bright plate under focus.
            shape.fill(focused ? Color.white : Color.white.opacity(0.07))
                .overlay { WithPerceptionTracking { shape.strokeBorder(.white.opacity(focused ? 0 : 0.06), lineWidth: 1) } }
            #else
            Color.clear.contentPanel(cornerRadius: radius)
            #endif
        }
    }
}

/// A source's icon: Bilibili's own mark, otherwise a `MonogramIcon`.
struct SourceIcon: View {
    let site: Site
    let label: SourceLabel
    var size: CGFloat
    var body: some View {
        WithPerceptionTracking {
            if site.isBilibili { BilibiliMark(size: size) } else {
                MonogramIcon(seed: site.name, label: label, size: size, systemImage: site.symbol)
            }
        }
    }
}

/// The emoji a name starts with (or its first character, or a symbol) on a tile whose colour is
/// derived from the name, so neighbours differ.
struct MonogramIcon: View {
    let seed: String
    let label: SourceLabel
    var size: CGFloat
    var systemImage: String?
    private static let tints: [Color] = [
        Brand.indigo, Brand.amber, Brand.rose,
        Color(red: 0.30, green: 0.66, blue: 0.60), Color(red: 0.42, green: 0.56, blue: 0.92),
        Color(red: 0.62, green: 0.48, blue: 0.88), Color(red: 0.52, green: 0.72, blue: 0.38),
    ]
    var body: some View {
        WithPerceptionTracking {
            // A stable hash: `hashValue` changes every launch.
            let tint = Self.tints[seed.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % Self.tints.count]
            let shape = RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            Group {
                if let systemImage {
                    // Sized by frame rather than font: font-sized symbols sit off-center (baseline/ascent padding) before macOS 26.
                    Image(systemName: systemImage).resizable().scaledToFit().fontWeight(.semibold)
                        .frame(width: size * 0.46, height: size * 0.46).foregroundStyle(.white)
                } else if let symbol = label.symbol {
                    Text(symbol).font(.system(size: size * 0.5))
                } else {
                    Text(String(label.parts[0].prefix(1)).uppercased()).font(.system(size: size * 0.44, weight: .bold, design: .rounded)).foregroundStyle(.white)
                }
            }
            .frame(width: size, height: size, alignment: .center)
            .background(LinearGradient(colors: [tint.opacity(0.85), tint.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing), in: shape)
            .overlay { WithPerceptionTracking { shape.strokeBorder(.white.opacity(0.12), lineWidth: 1) } }
            .accessibilityHidden(true)
        }
    }
}

struct PinSourceButton: View {
    @Environment(Store.self) private var store
    let site: Site
    let origin: URL
    var body: some View {
        WithPerceptionTracking {
            let pinned = store.pinnedSources.contains(site, origin: origin)
            Button { store.pinnedSources.toggle(site, origin: origin) } label: {
                Label(L10n.text(pinned ? "Unpin source" : "Pin source"), systemImage: pinned ? "pin.slash" : "pin")
            }.accessibilityIdentifier("source.pin." + site.key)
        }
    }
}

struct HideSourceButton: View {
    @Environment(Store.self) private var store
    let site: Site
    let origin: URL
    var body: some View {
        WithPerceptionTracking {
            let hidden = store.hiddenSources.contains(site, origin: origin)
            Button { store.hiddenSources.toggle(site, origin: origin) } label: {
                Label(L10n.text(hidden ? "Unhide Source" : "Hide Source"), systemImage: hidden ? "eye" : "eye.slash")
            }.accessibilityIdentifier("source.hide." + site.key)
        }
    }
}

/// Context-menu moves within the viewer's own source order.
struct MoveSourceButtons: View {
    @Environment(Store.self) private var store
    let site: Site
    let sites: [Site]
    var body: some View {
        WithPerceptionTracking {
            if let index = sites.firstIndex(where: { $0.id == site.id }) {
                if index > 0 {
                    Button { store.moveSource(site, to: 0) } label: { Label(L10n.text("Move to Top"), systemImage: "arrow.up.to.line") }
                }
                if index < sites.count - 1 {
                    Button { store.moveSource(site, to: sites.count) } label: { Label(L10n.text("Move to Bottom"), systemImage: "arrow.down.to.line") }
                }
            }
        }
    }
}

/// The Sources page's header: the switch for the viewer's own order (`SourceOrder`), the top of
/// that order at a glance, and the way into arranging it.
struct SourceOrderCard: View {
    @Environment(Store.self) private var store
    let sites: [Site]
    let arrange: () -> Void
    private var enabled: Binding<Bool> {
        Binding { store.sourceOrder.enabled } set: { on in withAnimation(.appSmooth) { store.setCustomSourceOrder(on) } }
    }
    private var detail: String {
        L10n.text(store.sourceOrder.enabled ? "Sources at the top are searched first, and their results are listed first."
                                            : "Yingxia searches quick, reliable sources first.")
    }
    var body: some View {
        WithPerceptionTracking {
            #if os(tvOS)
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsToggle(title: L10n.text("Custom Search Order"), detail: detail, isOn: enabled)
                    .accessibilityIdentifier("sources.order.toggle")
                if store.sourceOrder.enabled {
                    Button(action: arrange) {
                        TVSettingsRowLabel(title: L10n.text("Arrange Sources"), chevron: true) { SourceOrderPreview(sites: sites) }
                    }
                    .glassRow()
                    .accessibilityIdentifier("sources.order.arrange")
                }
            }
            #else
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    IconTile(symbol: "arrow.up.arrow.down", tint: Brand.indigo, size: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.text("Custom Search Order")).font(.headline)
                        Text(detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Toggle(L10n.text("Custom Search Order"), isOn: enabled).labelsHidden().toggleStyle(.switch).settingsSwitch()
                        .accessibilityIdentifier("sources.order.toggle")
                }
                if store.sourceOrder.enabled {
                    Divider()
                    HStack(spacing: 12) {
                        // As many icons as fit beside the button.
                        ViewThatFits(in: .horizontal) {
                            SourceOrderPreview(sites: sites, limit: 5)
                            SourceOrderPreview(sites: sites, limit: 4)
                            SourceOrderPreview(sites: sites, limit: 3)
                        }
                        Spacer(minLength: 8)
                        Button(action: arrange) {
                            Label(L10n.text("Arrange"), systemImage: "arrow.up.arrow.down")
                                .font(.subheadline.weight(.semibold)).foregroundStyle(Brand.onAccent)
                                .lineLimit(1).fixedSize()
                                .padding(.horizontal, 16).padding(.vertical, 7)
                                .background(Brand.accent, in: Capsule())
                        }
                        .buttonStyle(LiftButtonStyle())
                        .accessibilityIdentifier("sources.order.arrange")
                    }
                }
            }
            .padding(16)
            .contentPanel(cornerRadius: 22)
            #endif
        }
    }
}

/// The first sources of an order, as numbered icons.
struct SourceOrderPreview: View {
    let sites: [Site]
    var limit = 5
    #if os(tvOS)
    private let size: CGFloat = 44
    #else
    private let size: CGFloat = 30
    #endif
    var body: some View {
        WithPerceptionTracking {
            let shown = Array(sites.prefix(limit))
            HStack(spacing: size * 0.32) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, site in
                    WithPerceptionTracking {
                        SourceIcon(site: site, label: SourceLabel(site.name), size: size)
                            .overlay(alignment: .topLeading) {
                                WithPerceptionTracking {
                                    SourceRankBadge(rank: index + 1, size: size * 0.52).offset(x: -size * 0.18, y: -size * 0.18)
                                }
                            }
                    }
                }
                if sites.count > shown.count {
                    Text(verbatim: "+\(sites.count - shown.count)").font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            // Room for the badges that stick out.
            .padding(.top, size * 0.18).padding(.leading, size * 0.18)
            .accessibilityHidden(true)
        }
    }
}

struct SourceRankBadge: View {
    let rank: Int
    var size: CGFloat
    var body: some View {
        WithPerceptionTracking {
            Text(rank, format: .number).font(.system(size: size * 0.62, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(Brand.onAccent)
                .padding(.horizontal, size * 0.2)
                .frame(minWidth: size, minHeight: size)
                .background(Brand.accent, in: Capsule())
                .overlay { WithPerceptionTracking { Capsule().strokeBorder(.black.opacity(0.25), lineWidth: 1) } }
        }
    }
}

/// One source in the order editor: its place, icon, name and health.
private struct SourceOrderRow: View {
    @Environment(Store.self) private var store
    let site: Site
    let rank: Int
    #if os(tvOS)
    private let icon: CGFloat = 56, rankWidth: CGFloat = 44
    private let title = Font.system(size: 29, weight: .medium), caption = Font.system(size: 22)
    #else
    private let icon: CGFloat = 32, rankWidth: CGFloat = 26
    private let title = Font.body.weight(.medium), caption = Font.caption
    #endif
    var body: some View {
        WithPerceptionTracking {
            let label = SourceLabel(site.name)
            let detail = (label.parts.dropFirst() + [site.isBuiltIn ? L10n.text("Built-in") : nil].compactMap { $0 }).joined(separator: " · ")
            HStack(spacing: 12) {
                Text(rank, format: .number).font(caption.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(rank <= 3 ? Color.primary : Color.secondary)
                    .frame(minWidth: rankWidth, alignment: .trailing)
                SourceIcon(site: site, label: label, size: icon)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(label.parts[0]).font(title).lineLimit(1)
                        SourceHealthDot(status: store.health(of: site))
                    }
                    if !detail.isEmpty { Text(detail).font(caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 8)
                #if os(macOS)
                // macOS lists draw no handle of their own; any part of the row drags.
                Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                #endif
            }
            .padding(.vertical, 3)
            .accessibilityElement(children: .combine)
        }
    }
}

/// The viewer's source order as a list to drag into place. tvOS has no dragging: there, choose a
/// source, then where it goes; each move is saved at once.
struct SourceOrderEditor: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var sites: [Site]
    /// What Reset goes back to.
    private let automatic: [Site]
    #if os(tvOS)
    @State private var moving: Site?
    #endif

    init(sites: [Site], automatic: [Site]) {
        _sites = State(initialValue: sites)
        self.automatic = automatic
    }

    private var isAutomatic: Bool { sites.map(\.id) == automatic.map(\.id) }

    private func save() {
        if let config = store.subscription { store.sourceOrder.save(sites, origin: config.origin) }
    }

    var body: some View {
        WithPerceptionTracking {
            #if os(tvOS)
            NavigationStack {
                WithPerceptionTracking {
                    ScrollView {
                        WithPerceptionTracking {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                WithPerceptionTracking {
                                    Text(L10n.text("Choose a source to move it. Sources at the top are searched first, and their results are listed first."))
                                        .font(.system(size: 24)).foregroundStyle(.secondary).padding(.bottom, 12)
                                    ForEach(Array(sites.enumerated()), id: \.element.id) { index, site in
                                        WithPerceptionTracking {
                                            Button { moving = site } label: { SourceOrderRow(site: site, rank: index + 1).frame(maxWidth: .infinity) }
                                                .glassRow()
                                                .accessibilityIdentifier("sources.order.row." + site.key)
                                        }
                                    }
                                    TVSettingsAction(title: L10n.text("Reset"), destructive: true) {
                                        withAnimation(.appSmooth) { sites = automatic }
                                        save()
                                    }
                                    .disabled(isAutomatic)
                                    .padding(.top, 16)
                                }
                            }
                            .glassRowInsets()
                        }
                    }
                    .screenTitle(L10n.text("Arrange Sources"))
                    .screenBackdrop()
                    .confirmationDialog(moving.map { SourceLabel($0.name).parts[0] } ?? "",
                                        isPresented: Binding { moving != nil } set: { if !$0 { moving = nil } },
                                        titleVisibility: .visible, presenting: moving) { site in
                                            WithPerceptionTracking {
                            let index = sites.firstIndex { $0.id == site.id } ?? 0
                            if index > 0 {
                                Button(L10n.text("Move to Top")) { move(site, to: 0) }
                                Button(L10n.text("Move Up")) { move(site, to: index - 1) }
                            }
                            if index < sites.count - 1 {
                                Button(L10n.text("Move Down")) { move(site, to: index + 2) }
                                Button(L10n.text("Move to Bottom")) { move(site, to: sites.count) }
                            }
                                            }
                    }
                }
            }
            .frame(width: 1100, height: 800)
            .onExitCommand { dismiss() }
            #else
            NavigationStack {
                WithPerceptionTracking {
                    List {
                        WithPerceptionTracking {
                            Section {
                                ForEach(Array(sites.enumerated()), id: \.element.id) { index, site in
                                    WithPerceptionTracking {
                                        SourceOrderRow(site: site, rank: index + 1)
                                            #if os(iOS)
                                            .listRowBackground(Surface())
                                            #endif
                                            .accessibilityIdentifier("sources.order.row." + site.key)
                                    }
                                }
                                .onMove { sites.move(fromOffsets: $0, toOffset: $1) }
                            } footer: {
                                Text(L10n.text("Drag sources to reorder them. Sources at the top are searched first, and their results are listed first."))
                            }
                        }
                    }
                    #if os(iOS)
                    .environment(\.editMode, .constant(.active))
                    .scrollContentBackground(.hidden)
                    .background { WithPerceptionTracking { Backdrop() } }
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .navigationTitle(L10n.text("Arrange Sources"))
                    .toolbar { WithPerceptionTracking {

                            ToolbarItem(placement: .cancellationAction) {
                                Button(L10n.text("Cancel")) { dismiss() }
                            }
                            ToolbarItem(placement: .confirmationAction) {
                                Button(L10n.text("Done")) { save(); dismiss() }.fontWeight(.semibold)
                                    .accessibilityIdentifier("sources.order.done")
                            }
                            #if os(iOS)
                            ToolbarItem(placement: .bottomBar) {
                                Button(L10n.text("Reset")) { withAnimation(.appSmooth) { sites = automatic } }.disabled(isAutomatic)
                            }
                            #else
                            ToolbarItem(placement: .destructiveAction) {
                                Button(L10n.text("Reset")) { withAnimation(.appSmooth) { sites = automatic } }.disabled(isAutomatic)
                            }
                            #endif

                     }}
                }
            }
            #if os(macOS)
            .frame(width: 480, height: 600)
            #endif
            #endif
        }
    }

    #if os(tvOS)
    private func move(_ site: Site, to offset: Int) {
        guard let index = sites.firstIndex(where: { $0.id == site.id }) else { return }
        withAnimation(.appSmooth) { sites.move(fromOffsets: [index], toOffset: offset) }
        save()
    }
    #endif
}

/// Opens `HiddenSourcesEditor`, under the search order on the sources page.
struct HideSourcesCard: View {
    let hidden: Int
    let open: () -> Void
    private var value: String { hidden > 0 ? L10n.text("%lld hidden", hidden) : "" }
    var body: some View {
        WithPerceptionTracking {
            #if os(tvOS)
            Button(action: open) { TVSettingsRowLabel(title: L10n.text("Hide or Show Sources"), value: value, chevron: true) }
                .glassRow()
                .accessibilityIdentifier("sources.hidden.open")
            #else
            Button(action: open) {
                HStack(spacing: 14) {
                    IconTile(symbol: "eye.slash", tint: Brand.teal, size: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.text("Hide or Show Sources")).font(.headline).foregroundStyle(.primary)
                        Text(L10n.text("Choose many sources at once, or a whole subscription.")).font(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if !value.isEmpty { Text(value).font(.subheadline).monospacedDigit().foregroundStyle(.secondary).lineLimit(1) }
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .padding(16)
                .contentPanel(cornerRadius: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sources.hidden.open")
            #endif
        }
    }
}

/// Hiding or showing many sources at once: a ticked source is shown; Show All and Hide All take a whole group.
/// Sources stay in their own group here, hidden or not, and each change is saved at once.
struct HiddenSourcesEditor: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss

    private func isHidden(_ site: Site) -> Bool {
        store.subscription.map { store.hiddenSources.contains(site, origin: $0.origin) } ?? false
    }
    private func setHidden(_ sites: [Site], _ hidden: Bool) {
        guard let config = store.subscription else { return }
        store.hiddenSources.setHidden(sites, origin: config.origin, hidden: hidden)
    }

    var body: some View {
        WithPerceptionTracking {
            let groups = store.sourceGroups(includeHidden: true)
            let hiddenCount = groups.flatMap(\.sites).filter(isHidden).count
            #if os(tvOS)
            NavigationStack {
                WithPerceptionTracking {
                    ScrollView {
                        WithPerceptionTracking {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                WithPerceptionTracking {
                                    Text(L10n.text("Ticked sources are shown. Hidden sources stay out of Watch Now and search."))
                                        .font(.system(size: 24)).foregroundStyle(.secondary).padding(.bottom, 12)
                                    if hiddenCount > 0 {
                                        TVSettingsAction(title: L10n.text("Show All Sources")) { setHidden(groups.flatMap(\.sites), false) }
                                            .padding(.bottom, 16)
                                    }
                                    ForEach(groups) { group in
                                        WithPerceptionTracking {
                                            let hidden = group.sites.filter(isHidden)
                                            Text(L10n.text(group.title)).font(.system(size: 31, weight: .semibold)).lineLimit(1)
                                                .padding(.top, 20).padding(.bottom, 6)
                                                .accessibilityAddTraits(.isHeader)
                                            HStack(spacing: 16) {
                                                TVSettingsAction(title: L10n.text("Show All")) { setHidden(group.sites, false) }.disabled(hidden.isEmpty)
                                                TVSettingsAction(title: L10n.text("Hide All")) { setHidden(group.sites, true) }.disabled(hidden.count == group.sites.count)
                                            }
                                            .focusSection()
                                            ForEach(group.sites) { site in
                                                WithPerceptionTracking {
                                                    let shown = !isHidden(site)
                                                    Button { setHidden([site], shown) } label: {
                                                        TVSettingsRowLabel(title: SourceLabel(site.name).parts[0], value: shown ? nil : L10n.text("Hidden")) {
                                                            Image(systemName: shown ? "checkmark.circle.fill" : "circle").font(.system(size: 30))
                                                        }
                                                    }
                                                    .glassRow()
                                                    .accessibilityAddTraits(shown ? [.isSelected] : [])
                                                    .accessibilityIdentifier("sources.hidden.row." + site.key)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            .glassRowInsets()
                        }
                    }
                    .screenTitle(L10n.text("Hide or Show Sources"))
                    .screenBackdrop()
                }
            }
            .frame(width: 1100, height: 800)
            .onExitCommand { dismiss() }
            #else
            NavigationStack {
                WithPerceptionTracking {
                    List {
                        WithPerceptionTracking {
                            Section {
                                Text(L10n.text("Ticked sources are shown. Hidden sources stay out of Watch Now and search."))
                                    .font(.subheadline).foregroundStyle(.secondary)
                                    #if os(iOS)
                                    .listRowBackground(Surface())
                                    #endif
                            }
                            ForEach(groups) { group in
                                WithPerceptionTracking {
                                    let hidden = group.sites.filter(isHidden)
                                    Section {
                                        ForEach(group.sites) { site in
                                            WithPerceptionTracking {
                                                let shown = !isHidden(site)
                                                Button { setHidden([site], shown) } label: { HiddenSourceRow(site: site, shown: shown) }
                                                    .buttonStyle(.plain)
                                                    .accessibilityAddTraits(shown ? [.isSelected] : [])
                                                    .accessibilityIdentifier("sources.hidden.row." + site.key)
                                                    #if os(iOS)
                                                    .listRowBackground(Surface())
                                                    #endif
                                            }
                                        }
                                    } header: {
                                        HStack(spacing: 12) {
                                            Text(L10n.text(group.title)).lineLimit(1)
                                            Spacer(minLength: 8)
                                            Button(L10n.text("Show All")) { setHidden(group.sites, false) }.disabled(hidden.isEmpty)
                                            Button(L10n.text("Hide All")) { setHidden(group.sites, true) }.disabled(hidden.count == group.sites.count)
                                        }
                                        .buttonStyle(.borderless)
                                        .textCase(nil)
                                    }
                                }
                            }
                        }
                    }
                    #if os(iOS)
                    .scrollContentBackground(.hidden)
                    .background { WithPerceptionTracking { Backdrop() } }
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .navigationTitle(L10n.text("Hide or Show Sources"))
                    .toolbar { WithPerceptionTracking {

                            ToolbarItem(placement: .confirmationAction) {
                                Button(L10n.text("Done")) { dismiss() }.fontWeight(.semibold)
                                    .accessibilityIdentifier("sources.hidden.done")
                            }
                            #if os(iOS)
                            ToolbarItem(placement: .bottomBar) {
                                Button(L10n.text("Show All Sources")) { setHidden(groups.flatMap(\.sites), false) }.disabled(hiddenCount == 0)
                            }
                            #else
                            ToolbarItem(placement: .destructiveAction) {
                                Button(L10n.text("Show All Sources")) { setHidden(groups.flatMap(\.sites), false) }.disabled(hiddenCount == 0)
                            }
                            #endif

                     }}
                }
            }
            #if os(macOS)
            .frame(width: 480, height: 600)
            #endif
            #endif
        }
    }
}

#if !os(tvOS)
/// One source in `HiddenSourcesEditor`: a tick while it is shown, its icon and name.
private struct HiddenSourceRow: View {
    let site: Site
    let shown: Bool
    var body: some View {
        WithPerceptionTracking {
            let label = SourceLabel(site.name)
            HStack(spacing: 12) {
                Image(systemName: shown ? "checkmark.circle.fill" : "circle").font(.title3)
                    .foregroundStyle(shown ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(.secondary))
                SourceIcon(site: site, label: label, size: 32).opacity(shown ? 1 : 0.45)
                Text(label.parts[0]).font(.body.weight(.medium)).lineLimit(1)
                    .foregroundStyle(shown ? Color.primary : Color.secondary)
                Spacer(minLength: 8)
                if !shown { Text(L10n.text("Hidden")).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
        }
    }
}
#endif

struct SiteView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    @Environment(\.isLocalPageActive) private var localPageActive
    @Environment(\.localDockInset) private var localDockInset
    @Environment(\.openLocalHomeSources) private var openHomeSources
    #endif
    let site: Site
    let origin: URL
    let jarURL: URL?
    var initialQuery: String = ""
    /// A drive source's folder: the page lists it in place of the source's home.
    var folder: Video? = nil
    /// The source's home as another page already has it (Watch Now's recommendations): shown at once, then refreshed.
    var preview: (videos: [Video], categories: [TVCore.Category])? = nil
    private var canLoad: Bool { site.canBrowse(jarURL: jarURL) }
    private var isIndex: Bool { (site.raw["indexs"]?.int ?? 0) == 1 }
    #if os(iOS)
    @State private var browser = CatalogBrowser(usesInitialFilters: false)
    #else
    @State private var browser = CatalogBrowser()
    #endif
    @State private var query = ""
    /// The Bilibili login this page loaded with; signing in or out reloads it with the account's lists.
    @State private var bilibiliLogin = BilibiliAccount.load().cookie
    private var initialLoading: Bool { browser.videos.isEmpty && browser.error == nil && (browser.busy || !browser.loaded) }
    private var client: CatalogClient { CatalogClient(site: site, origin: origin, jarURL: jarURL) }
    @State private var requestTask: Task<Void, Never>?
    #if os(iOS)
    @State private var landscapePosters = false
    @State private var showsFilters = false
    @State private var showsSiteActions = false
    @State private var paginationVisible = false
    @State private var paginationVisibleRequest: CatalogBrowser.Request?
    private var posterStyleKey: String { "local.site.landscapePosters." + site.origin(or: origin).absoluteString + "|" + site.sourceKey }
    private var currentCategory: TVCore.Category? {
        browser.query.isEmpty ? browser.categories.first { $0.id == browser.category } : nil
    }
    #endif

    private func startRequest(_ operation: @escaping @MainActor () async -> Void) {
        #if os(iOS)
        guard localPageActive else { return }
        #endif
        requestTask?.cancel()
        requestTask = Task {
            guard !Task.isCancelled else { return }
            await operation()
        }
    }

    var body: some View {
        WithPerceptionTracking {
            siteContent
            .onDisappear { requestTask?.cancel(); browser.cancel() }
            #if os(iOS)
            .appOnChange(of: localPageActive) { _, active in
                if !active { requestTask?.cancel(); browser.cancel() }
                else if paginationVisible && paginationVisibleRequest == browser.request && browser.moreError == nil { Task { await loadMore() } }
            }
            #endif
            #if !os(iOS)
            .toolbar { WithPerceptionTracking {

                    // Handed the store: UIKit can size a bar item before SwiftUI gives it the page's environment, and these
                    // buttons read Store first thing (a TestFlight crash on iPhone).
                    Group {
                        PinSourceButton(site: site, origin: origin)
                        HideSourceButton(site: site, origin: origin)
                    }
                    .environment(store)

             }}
            #endif
            .screenBackdrop()
            .onAppear {
                guard site.isBilibili, browser.loaded else { return }
                let login = BilibiliAccount.load().cookie
                if login != bilibiliLogin { bilibiliLogin = login; query = ""; startRequest { await home(); await browser.loadCategories(client: client) } }
            }
            .modifier(LocalSitePageTitle(title: folder?.name ?? site.name))
            #if os(iOS)
            .onAppear { landscapePosters = UserDefaults.standard.bool(forKey: posterStyleKey) }
            .sheet(isPresented: $showsSiteActions) {
                LocalSiteActionsSheet(site: site, origin: origin) {
                    startRequest { await browser.load(browser.request, client: client); await browser.loadCategories(client: client) }
                    showsSiteActions = false
                }
                .environment(store)
            }
            .localGlassDialog(isPresented: $showsFilters, title: "筛选", maxWidth: 540, maxHeight: 640, layout: .centered) {
                WithPerceptionTracking {
                    if let category = currentCategory {
                        LocalSiteFilterSheet(filters: category.filters, choices: browser.filters) { choices in
                            startRequest { await browser.load(.list(category: category.id, query: "", page: 1, filters: choices), client: client) }
                        }
                    }
                }
            }
            #endif
            .task(id: pageActive) {
                guard pageActive else { return }
                store.searchModel.suspend()
                if let preview, folder == nil, initialQuery.isEmpty { browser.seed(videos: preview.videos, categories: preview.categories) }
                if canLoad && !browser.loaded {
                    if browser.request != .home {
                        await browser.load(browser.request, client: client)
                    } else if initialQuery.isEmpty {
                        await home()
                    }
                    else { query = initialQuery; await search(); await browser.loadCategories(client: client) }
                }
            }
        }
    }
    private var pageActive: Bool {
        #if os(iOS)
        localPageActive
        #else
        true
        #endif
    }
    private var siteContent: some View {
        Group {
            #if os(iOS)
            mobileSiteContent
            #else
            if !canLoad {
                unsupportedSource
            } else {
                ScrollView {
                    WithPerceptionTracking {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            WithPerceptionTracking { siteRows }
                        }.pageContainer()
                    }
                }
                .catalogSearchable(text: Binding(get: { query }, set: { value in
                    query = value
                    if value.isEmpty && !browser.query.isEmpty { startRequest { await home() } }
                }), prompt: L10n.text("Search videos"))
                .onSubmit(of: .search) { startRequest { await search() } }
            }
            #endif
        }
    }
    #if os(iOS)
    private var mobileSiteContent: some View {
        Group {
            if !canLoad { unsupportedSource }
            else {
                GeometryReader { viewport in
                    ScrollViewReader { proxy in
                        WithPerceptionTracking {
                            ScrollView {
                                WithPerceptionTracking {
                                    // Keep the column tied to the real viewport through loading,
                                    // empty and loaded states, including fixed-width placeholders.
                                    // The grid owns lazy rows; its growing height stays scrollable.
                                    VStack(alignment: .leading, spacing: 18) {
                                        Color.clear.frame(height: 0).id("site.top")
                                        siteRows
                                    }.pageContainer()
                                        .frame(width: viewport.size.width, alignment: .topLeading)
                                }
                            }
                            .frame(width: viewport.size.width, height: viewport.size.height)
                            .overlay(alignment: .bottomTrailing) {
                                WithPerceptionTracking {
                                    VStack(spacing: 10) {
                                        if currentCategory?.filters.isEmpty == false {
                                            Button { showsFilters = true } label: {
                                                Image(systemName: "line.3.horizontal.decrease").frame(width: 44, height: 44)
                                            }
                                            .accessibilityLabel("筛选").accessibilityIdentifier("site.filters")
                                        }
                                        Button { withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("site.top", anchor: .top) } } label: {
                                            Image(systemName: "arrow.up").frame(width: 44, height: 44)
                                        }
                                        .accessibilityLabel("回到顶部").accessibilityIdentifier("site.top")
                                    }
                                    .font(.headline).buttonStyle(.plain)
                                    .padding(6).background(.regularMaterial, in: Capsule())
                                    .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
                                    .localDockHitRegion()
                                    .padding(16)
                                    .padding(.bottom, localDockInset)
                                    .localDockHitRegions()
                                }
                            }
                        }
                    }
                }
            }
        }
        // Keep the source controls fixed while the catalog scrolls.
        .safeAreaInset(edge: .top, spacing: 0) { mobileSiteHeader }
    }

    private var mobileSiteHeader: some View {
        WithPerceptionTracking {
            HStack(spacing: 4) {
                Button { openHomeSources?() } label: {
                    HStack(spacing: 4) {
                        Text(folder?.name ?? SourceLabel(site.name).text).font(.headline).lineLimit(2)
                        Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                    }
                    .frame(minWidth: 48, idealWidth: 86, maxWidth: 132, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel("选择来源，" + SourceLabel(site.name).text)
                .accessibilityIdentifier("site.sources")
                Button {
                    landscapePosters.toggle()
                    UserDefaults.standard.set(landscapePosters, forKey: posterStyleKey)
                } label: {
                    Image(systemName: landscapePosters ? "rectangle.grid.1x2" : "square.grid.2x2")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(landscapePosters ? "切换为竖版海报网格" : "切换为横版海报网格")
                .accessibilityValue(landscapePosters ? "横版海报" : "竖版海报")
                .accessibilityIdentifier("site.layout")
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
                    TextField("搜索当前站点", text: Binding(get: { query }, set: { value in
                        query = value
                        if value.isEmpty && !browser.query.isEmpty { startRequest { await home() } }
                    }))
                        .font(.subheadline).submitLabel(.search)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .onSubmit { startRequest { await search() } }
                        .accessibilityIdentifier("site.search")
                    if !query.isEmpty {
                        Button {
                            query = ""
                            if !browser.query.isEmpty { startRequest { await home() } }
                        } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).frame(minWidth: 28, minHeight: 44) }
                            .buttonStyle(.plain).accessibilityLabel("清除站点搜索")
                    }
                }
                .padding(.horizontal, 9).frame(minWidth: 98, minHeight: 44)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                Button { showsSiteActions = true } label: {
                    Image(systemName: "ellipsis").rotationEffect(.degrees(90)).frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                    .buttonStyle(.plain)
                    .accessibilityLabel("站点更多操作").accessibilityIdentifier("site.menu")
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(.regularMaterial)
        }
    }
    #endif
    private var unsupportedSource: some View {
        AppContentUnavailableView {
            Label(site.compatibility, systemImage: "puzzlepiece.extension")
        } description: {
            if site.type != 3 {
                Text(L10n.text("This source format is not supported. Choose another source."))
            } else {
                Text(site.runtime == .jar ? L10n.text("This source uses a plugin that requires Android DEX and native libraries. This platform does not yet have the required compatibility layer.\n\n%@", site.api)
                     : site.runtime == .python ? L10n.text("This source requires a Python runtime, which is not available on this platform.")
                     : L10n.text("This source requires a JavaScript engine, which is not supported yet."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(tvOS)
        .focusable()
        .onExitCommand { dismiss() }
        #endif
    }

    @ViewBuilder private var siteRows: some View {
        #if os(tvOS)
        // The remote's keyboard has no return key, so typing only edits the query; as in
        // the Search tab, a focusable button below the keyboard runs the search.
        let pending = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pending.isEmpty, pending != browser.query {
            SearchQueryButton(query: pending) { startRequest { await search() } }
                .accessibilityIdentifier("site.search.submit")
        }
        #endif
        if site.isBilibili && !BilibiliAccount.load().signedIn { BilibiliSignInBanner() }
        if !browser.categories.isEmpty { categoryBar }
        else if initialLoading && folder == nil {
            #if os(iOS)
            // The six fixed chip widths total 524pt. A loading row must not propose
            // that width to the catalog grid on a 320–430pt phone.
            GeometryReader { viewport in
                ChipSkeletonRow().frame(width: viewport.size.width, alignment: .leading)
            }.frame(height: 44).clipped().allowsHitTesting(false)
            #else
            ChipSkeletonRow()
            #endif
        }
        #if !os(iOS)
        if browser.query.isEmpty, let current = browser.categories.first(where: { $0.id == browser.category }), !current.filters.isEmpty {
            CategoryFilterBar(filters: current.filters, choices: browser.filters) { choices in
                startRequest { await browser.load(.list(category: current.id, query: "", page: 1, filters: choices), client: client) }
            }
        }
        #endif
        if isIndex && !browser.videos.isEmpty {
            Text(L10n.text("Choose a title to find it across your sources.")).font(.subheadline).foregroundStyle(.secondary)
        }
        if browser.busy {
            LoadingCard { .source(site, origin: origin, title: L10n.text("Loading source content…")) }
        }
        if initialLoading { PosterSkeletonGrid().loadingFocus { dismiss() } }
        if let error = browser.error {
            ErrorStateCard(
                title: L10n.text("Unable to load this source"),
                message: L10n.text("Try again, or choose another source to keep watching."),
                details: error,
                retry: { startRequest { await browser.load(browser.request, client: client) } },
                goBack: { dismiss() },
                busy: browser.busy
            )
            .padding(.vertical, browser.videos.isEmpty ? 24 : 8)
        }
        if browser.videos.isEmpty && browser.loaded && !browser.busy && browser.error == nil { EmptyResults(symbol: "film", title: L10n.text("No Videos"), message: L10n.text("Try selecting a category or searching.")) }
        videoGrid
        if !browser.videos.isEmpty {
            // A focus section, so moving down from a cover in any column reaches Load More or Try Again.
            #if os(iOS)
            let paginationRequest = browser.request
            ZStack {
                Color.clear.frame(height: 76).accessibilityHidden(true)
                loadMoreFooter
            }.tvFocusSection()
                .onScrolledIntoView(threshold: 0.1) { visible in
                    guard paginationRequest == browser.request else { return }
                    paginationVisible = visible
                    paginationVisibleRequest = paginationRequest
                    if visible && browser.moreError == nil { Task { await loadMore() } }
                }
                // Recreate the visibility modifier as well as the footer. A
                // completed page must lay out before the new probe can paginate.
                .id(browser.page)
            #else
            loadMoreFooter.tvFocusSection()
            #endif
        }
    }

    private var videoGrid: some View {
        LazyVGrid(columns: catalogColumns, spacing: Layout.gridRowSpacing) {
            WithPerceptionTracking {
                ForEach(browser.videos) { video in
                    WithPerceptionTracking {
                        Group {
                            // An index source (a ranking or list site) names titles; other sources play them.
                            if isIndex {
                                Button { store.searchVideos(video.name) } label: { catalogPoster(video) }.cardButton()
                            } else {
                                RouteLink { WithPerceptionTracking { CatalogDestination(video: video, client: client) } } label: { WithPerceptionTracking { catalogPoster(video) } }.cardButton()
                            }
                        }
                        #if !os(iOS)
                        .onAppear {
                            guard browser.moreError == nil, video.id == browser.videos.last?.id else { return }
                            Task { await loadMore() }
                        }
                        #endif
                    }
                }
            }
        }
        .opacity(browser.busy && !browser.videos.isEmpty ? 0.55 : 1).animation(.appSmooth, value: browser.busy)
    }

    private var catalogColumns: [GridItem] {
        #if os(iOS)
        landscapePosters ? [GridItem(.adaptive(minimum: 160), spacing: 12, alignment: .top)] : Layout.posterColumns
        #else
        Layout.posterColumns
        #endif
    }

    @ViewBuilder private func catalogPoster(_ video: Video) -> some View {
        #if os(iOS)
        LocalSitePosterCard(video: video, landscape: landscapePosters)
        #else
        PosterCard(video: video)
        #endif
    }

    private var categoryBar: some View {
        ChipRow {
            GlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    Chip(title: L10n.text("Recommendations"), selected: browser.query.isEmpty && browser.category.isEmpty) { query = ""; startRequest { await home() } }
                    ForEach(browser.categories) { item in
                        WithPerceptionTracking {
                            Chip(title: item.name, selected: browser.query.isEmpty && browser.category == item.id) {
                                query = ""
                                let filters = browser.openingFilters(for: item)
                                startRequest { await browser.load(.list(category: item.id, query: "", page: 1, filters: filters), client: client) }
                            }
                        }
                    }
                }
            }.padding(.vertical, 4)
        }
    }
    @ViewBuilder private var loadMoreFooter: some View {
        if let message = browser.moreError {
            VStack(spacing: 12) {
                Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button(L10n.text("Try Again")) { startRequest { await loadMore() } }
                    .controlButton()
                    .accessibilityIdentifier("site.loadMore.retry")
            }
            .frame(maxWidth: .infinity).padding(.vertical, 16)
        } else if browser.loadingMore {
            ProgressView().controlSize(.large)
                .frame(maxWidth: .infinity).padding(.vertical, 24)
                .accessibilityLabel(L10n.text("Loading…"))
        } else if browser.hasMore {
            Button(L10n.text("Load More")) { startRequest { await loadMore() } }
                .controlButton()
                .frame(maxWidth: .infinity).padding(.vertical, 16)
                .accessibilityIdentifier("site.loadMore")
        }
    }
    private func home() async { await browser.load(folder.map { .list(category: $0.folderCategoryID, query: "", page: 1, filters: $0.folderFilters) } ?? .home, client: client) }
    private func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { await home() }
        else { await browser.load(.list(category: nil, query: text, page: 1), client: client) }
    }
    private func loadMore() async { guard pageActive else { return }; await browser.loadMore(client: client) }
}

/// A category's filters (TVBox `filters`: 类型, 地区, 年份…) drawn as Discover's catalog search draws its own: one
/// "地区：全部 ⌄" chip per filter. On the Mac a chip opens a popover of choices, on iPhone, iPad and Apple TV a
/// menu. Each choice reloads the category from its first page.
struct CategoryFilterBar: View {
    let filters: [CategoryFilter]
    let choices: [String: String]
    let choose: ([String: String]) -> Void
    #if os(macOS)
    @State private var open: String?
    #endif

    private func value(_ filter: CategoryFilter) -> String { choices[filter.key] ?? filter.initial }
    private func changed(_ filter: CategoryFilter) -> Bool { value(filter) != filter.initial }
    private var anyChanged: Bool { filters.contains(where: changed) }
    private func title(_ filter: CategoryFilter) -> String {
        let current = value(filter)
        let choice = filter.options.first { $0.value == current }?.name ?? current
        return filter.name.isEmpty ? choice : filter.name + "：" + choice
    }
    private func pick(_ filter: CategoryFilter, _ option: String) {
        guard value(filter) != option else { return }
        var next = choices
        next[filter.key] = option
        choose(next)
    }
    private func reset() { choose(CategoryFilter.initialChoices(filters)) }

    var body: some View {
        WithPerceptionTracking {
            #if os(macOS)
            DiscoverChipFlow(spacing: 8) {
                ForEach(filters) { filter in
                    WithPerceptionTracking {
                        Button { open = open == filter.key ? nil : filter.key } label: { FilterChipLabel(title: title(filter), open: open == filter.key) }
                            .buttonStyle(.plain)
                            .popover(isPresented: Binding(get: { open == filter.key }, set: { if !$0, open == filter.key { open = nil } }), arrowEdge: .bottom) {
                                WithPerceptionTracking {
                                    panel(filter)
                                }
                            }
                            .accessibilityIdentifier("site.filter.\(filter.key)")
                    }
                }
                if anyChanged {
                    Button(action: reset) {
                        Label(L10n.text("Reset Filters"), systemImage: "xmark").font(.system(size: 13)).padding(.horizontal, 12).frame(height: 30)
                            .contentShape(Capsule())
                    }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityIdentifier("site.filters.reset")
                }
            }
            .accessibilityIdentifier("site.filters")
            #elseif os(tvOS)
            ScrollView(.horizontal) {
                WithPerceptionTracking {
                    HStack(spacing: 18) {
                        ForEach(filters) { filter in
                            WithPerceptionTracking {
                                Menu { WithPerceptionTracking { picker(filter) } } label: { WithPerceptionTracking { Text(title(filter)) } }
                                    .menuStyle(.button)
                                    .buttonStyle(DiscoverTVChipStyle(active: changed(filter)))
                                    .accessibilityIdentifier("site.filter.\(filter.key)")
                            }
                        }
                        if anyChanged {
                            Button(action: reset) { Label(L10n.text("Reset Filters"), systemImage: "xmark") }
                                .buttonStyle(DiscoverTVChipStyle(active: false))
                                .accessibilityIdentifier("site.filters.reset")
                        }
                    }.padding(.vertical, 16)
                }
            }
            .scrollIndicators(.hidden).appScrollClipDisabled().focusSection()
            .accessibilityIdentifier("site.filters")
            #else
            ScrollView(.horizontal) {
                WithPerceptionTracking {
                    GlassGroup(spacing: 8) {
                        HStack(spacing: 8) {
                            ForEach(filters) { filter in
                                WithPerceptionTracking {
                                    Menu { WithPerceptionTracking { picker(filter) } } label: { WithPerceptionTracking { FilterChipLabel(title: title(filter)) } }
                                        .accessibilityIdentifier("site.filter.\(filter.key)")
                                }
                            }
                            if anyChanged {
                                Button(action: reset) { Image(systemName: "xmark").frame(width: 38, height: 38).glassSurface(.regular, in: Circle()).iosTouchTarget() }
                                    .accessibilityLabel(L10n.text("Reset Filters")).accessibilityIdentifier("site.filters.reset")
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.hidden).appScrollClipDisabled().frame(height: 44)
            .tint(.primary)
            .accessibilityIdentifier("site.filters")
            #endif
        }
    }

    #if os(macOS)
    /// The filter's choices as Discover's filter popovers lay them out; a long list (years) scrolls.
    private func panel(_ filter: CategoryFilter) -> some View {
        let grid = LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            WithPerceptionTracking {
                ForEach(filter.options, id: \.value) { option in
                    WithPerceptionTracking {
                        FilterChoiceButton(title: option.name, selected: value(filter) == option.value) {
                            pick(filter, option.value)
                            open = nil
                        }
                    }
                }
            }
        }.padding(14)
        return Group {
            if filter.options.count > 30 { ScrollView { WithPerceptionTracking { grid } }.frame(height: 340) } else { grid }
        }
        .frame(width: 360)
    }
    #else
    private func picker(_ filter: CategoryFilter) -> some View {
        Picker(filter.name, selection: Binding(get: { value(filter) }, set: { pick(filter, $0) })) {
            ForEach(filter.options, id: \.value) { perceptionArgument0 in WithPerceptionTracking { Text(perceptionArgument0.name).tag(perceptionArgument0.value) } }
        }
    }
    #endif
}

/// Where a listed title opens: its details, for a drive source's folder the folder's listing, and for a plugin
/// setting listed among titles (`Video.action`) that setting.
struct CatalogDestination: View {
    let video: Video
    let client: CatalogClient
    var body: some View {
        WithPerceptionTracking {
            if let action = video.action { PluginActionPage(video: video, client: client, action: action) }
            else if video.isFolder { SiteView(site: client.site, origin: client.origin, jarURL: client.jarURL, folder: video) }
            else { VideoDetailView(video: video, client: client) }
        }
    }
}

/// A plugin setting listed among a source's titles (aowu's 配置中心, FTY's 我的云盘┃配置). It runs in the plugin, as
/// in TVBox; the window the plugin opens for it is drawn here (`PluginScreen`), and the viewer's taps and typing go
/// back to the plugin's own code.
struct PluginActionPage: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    #if os(iOS)
    @Environment(\.localDockInset) private var localDockInset
    #endif
    let video: Video
    let client: CatalogClient
    let action: String
    private enum Phase: Equatable { case running, showing, finished(String?), failed(String) }
    @State private var phase = Phase.running
    @State private var screen = PluginScreen()
    /// What the viewer typed, by field, until it goes to the plugin with the next tap.
    @State private var typed: [Int: String] = [:]
    @State private var sending = false
    @State private var notice: String?
    @State private var noticeTask: Task<Void, Never>?

    var body: some View {
        WithPerceptionTracking {
            ScrollView {
                WithPerceptionTracking {
                    switch phase {
                    case .running:
                        ProgressView().padding(.vertical, 80).frame(maxWidth: .infinity)
                    case .showing:
                        if let window = screen.windows.last {
                            PluginWindowView(window: window, typed: $typed, layers: screen.windows.count, send: send)
                                .id(window.id)
                                .disabled(sending)
                        }
                    case .finished(let message):
                        // Back is focusable, so the remote has somewhere to land on Apple TV.
                        EmptyResults(symbol: message == nil ? "checkmark.circle" : "info.circle", title: video.name,
                                     message: message ?? L10n.text("The plugin finished without a message."),
                                     action: L10n.text("Back"), actionSymbol: "chevron.backward") { dismiss() }
                        // Each tap runs the setting once more, as a tap on its row does in TVBox: settings that ask for a
                        // double tap to confirm (a reset) take two quick taps here. Never disabled, so the second tap counts.
                        Button { runAgain() } label: { Label(L10n.text("Run Again"), systemImage: "hand.tap").padding(.horizontal, 8) }
                            .controlButton()
                            .accessibilityIdentifier("pluginSetting.runAgain")
                    case .failed(let message):
                        EmptyResults(symbol: "exclamationmark.triangle", title: video.name, message: message,
                                     action: L10n.text("Try Again")) { Task { await run() } }
                    }
                }
            }
            .overlay(alignment: .bottom) {
                WithPerceptionTracking {
                    if let notice {
                        Text(notice)
                            .font(.callout)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 18).padding(.vertical, 12)
                            .glassPanel(cornerRadius: 22)
                            .padding(.bottom, 24).padding(.horizontal, 24)
                            #if os(iOS)
                            .padding(.bottom, localDockInset)
                            #endif
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                }
            }
            .animation(.easeOut(duration: 0.2), value: notice)
            .navigationTitle(video.name)
            .task { await run() }
            .task(id: phase == .showing) {
                // Plugins change their windows on their own (a QR code arriving, a sign-in confirmed): look again.
                guard phase == .showing else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1.5))
                    guard !Task.isCancelled, !sending, let window = screen.windows.last else { continue }
                    await deliver(PluginEvent(window: window.id, kind: .poll), quietly: true)
                }
            }
            .onDisappear {
                noticeTask?.cancel()
                guard let window = screen.windows.last else { return }
                let client = client
                Task { _ = try? await client.pluginWindow(PluginEvent(window: window.id, kind: .closeAll)) }
            }
        }
    }

    private func run() async {
        phase = .running
        typed = [:]
        do { show(try await client.runAction(action), first: true) }
        catch is CancellationError { }
        catch { phase = .failed(error.localizedDescription) }
    }

    private func runAgain() {
        Task {
            do { show(try await client.runAction(action), first: true) }
            catch is CancellationError { }
            catch { phase = .failed(error.localizedDescription) }
        }
    }

    /// A page the plugin opens. A sign-in page that only works in its service's app (Bilibili's confirmation page)
    /// goes there when the app is on this device; anything else, or no app, opens as it is.
    private func open(_ link: URL) {
        #if os(iOS)
        let tries = (DriveAppLink.app(opening: link)?.urls ?? []) + [link]
        #else
        let tries = [link]
        #endif
        func attempt(_ index: Int) {
            guard index < tries.count else { return }
            openURL(tries[index]) { opened in if !opened { attempt(index + 1) } }
        }
        attempt(0)
    }


    private func send(_ event: PluginEvent) {
        var event = event
        // Typed text reaches the plugin's fields before the tap runs, as on Android.
        for (field, text) in typed where event.values[field] == nil { event.values[field] = .text(text) }
        Task { await deliver(event, quietly: false) }
    }

    private func deliver(_ event: PluginEvent, quietly: Bool) async {
        if !quietly { sending = true }
        defer { if !quietly { sending = false } }
        do { show(try await client.pluginWindow(event), first: false) }
        catch is CancellationError { }
        catch { if !quietly { phase = .failed(error.localizedDescription) } }
    }

    private func show(_ next: PluginScreen, first: Bool) {
        if screen.windows.last?.id != next.windows.last?.id { typed = [:] }
        screen = next
        for link in next.links { open(link) }
        var said = next.notices.joined(separator: "\n")
        if let copied = next.clipboard {
            // What the plugin copied goes on the pasteboard (Apple TV has none, so it is shown instead).
            #if os(iOS)
            UIPasteboard.general.string = copied
            if said.isEmpty { said = L10n.text("Copied to the clipboard.") }
            #elseif os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(copied, forType: .string)
            if said.isEmpty { said = L10n.text("Copied to the clipboard.") }
            #else
            said = said.isEmpty ? copied : said + "\n" + copied
            #endif
        }
        if next.windows.isEmpty {
            // The setting is done: what it said stays on the page; with nothing to say the page goes.
            let failure = next.error.map { L10n.text("The plugin stopped with an error: %@", $0) }
            let message = [first ? next.message : nil, said.isEmpty ? nil : said, failure].compactMap { $0 }.joined(separator: "\n")
            if message.isEmpty && !first { dismiss() } else { phase = .finished(message.isEmpty ? nil : message) }
            return
        }
        phase = .showing
        guard !said.isEmpty else { return }
        notice = said
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { notice = nil }
        }
    }
}

/// A QR code in a plugin window (a sign-in page, TVBox's "remote input" page) can't be scanned by the device showing
/// it, so its link opens here. A page the plugin serves from this device (its network address) opens in the app, which
/// has to keep running to answer it; other links open as links do. Apple TV has no browser: its codes are scanned.
private struct PluginCodeLink: View {
    let image: Data
    @State private var link: URL?
    @State private var showsPage = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        WithPerceptionTracking {
            #if os(tvOS)
            EmptyView()
            #else
            Group {
                if let link {
                    Button { open(link) } label: { Label(L10n.text("Open Link"), systemImage: "link").padding(.horizontal, 8) }
                        .controlButton()
                        .accessibilityIdentifier("pluginSetting.openCode")
                }
            }
            .task(id: image) { link = await Self.decode(image) }
            #if os(iOS)
            .sheet(isPresented: $showsPage) {
                WithPerceptionTracking {
                    if let link { ConfigCenterView { ConfigCenter.local(link) ?? link } }
                }
            }
            #endif
            #endif
        }
    }

    private func open(_ url: URL) {
        #if os(iOS)
        if ConfigCenter.local(url) != nil { showsPage = true } else { openURL(url) }
        #else
        openURL(ConfigCenter.local(url) ?? url)
        #endif
    }

    /// The web address a QR code in the picture holds, if any.
    nonisolated static func decode(_ data: Data) async -> URL? {
        guard let picture = CIImage(data: data),
              let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        else { return nil }
        for case let code as CIQRCodeFeature in detector.features(in: picture) {
            guard let text = code.messageString?.trimmingCharacters(in: .whitespacesAndNewlines), let url = URL(string: text),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
            return url
        }
        return nil
    }
}

/// One plugin window, drawn from the plugin's own views. When the plugin paints its window (most do: white
/// cards), its colors are kept on that surface; a plain Android alert takes the app's look instead.
private struct PluginWindowView: View {
    let window: PluginWindow
    @Binding var typed: [Int: String]
    /// Windows open, this one included: under another one, Back returns to it.
    let layers: Int
    let send: (PluginEvent) -> Void
    #if os(tvOS)
    static let scale = 1.7
    private let width: CGFloat = 1100
    #else
    static let scale = 1.0
    private let width: CGFloat = 620
    #endif

    var body: some View {
        WithPerceptionTracking {
            let painted = window.surface.map { $0.alpha > 0.5 } ?? false
            VStack(alignment: .leading, spacing: 14 * Self.scale) {
                if layers > 1 {
                    Button { send(PluginEvent(window: window.id, kind: .back)) } label: {
                        Label(L10n.text("Back"), systemImage: "chevron.backward")
                    }
                    .buttonStyle(.bordered)
                }
                if let title = window.title { Text(title).font(.headline) }
                if let message = window.message { Text(message).font(.body).fixedSize(horizontal: false, vertical: true) }
                if let header = window.header { PluginNodeView(node: header, context: context(painted)) }
                if let root = window.root { PluginNodeView(node: root, context: context(painted)) }
                if !window.items.isEmpty { items }
                if let progress = window.progress { PluginNodeView(node: progress, context: context(painted)) }
                if !window.buttons.isEmpty { buttons }
            }
            .padding(painted ? 0 : 20 * Self.scale)
            .frame(maxWidth: width, alignment: .leading)
            .background {
                WithPerceptionTracking {
                    if let surface = window.surface, painted {
                        RoundedRectangle(cornerRadius: 18 * Self.scale, style: .continuous).fill(surface.color)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18 * Self.scale, style: .continuous))
            .environment(\.colorScheme, painted ? ((window.surface?.luminance ?? 0) > 0.5 ? .light : .dark) : colorSchemeFallback)
            .padding(20)
            .frame(maxWidth: .infinity)
        }
    }

    @Environment(\.colorScheme) private var colorSchemeFallback

    private func context(_ painted: Bool) -> PluginNodeView.Context {
        PluginNodeView.Context(window: window.id, painted: painted, typed: $typed, send: send)
    }

    private var items: some View {
        VStack(spacing: 8) {
            ForEach(Array(window.items.enumerated()), id: \.offset) { index, item in
                WithPerceptionTracking {
                    Button { send(PluginEvent(window: window.id, kind: .item, index: index)) } label: {
                        HStack {
                            Text(item.text).frame(maxWidth: .infinity, alignment: .leading)
                            if window.choice == .multi {
                                Image(systemName: item.checked == true ? "checkmark.square.fill" : "square").foregroundStyle(.tint)
                            } else if item.checked == true {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PluginTapStyle())
                }
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            ForEach(window.buttons.sorted { order($0.role) < order($1.role) }) { button in
                WithPerceptionTracking {
                    if button.role == .positive {
                        Button(button.text) { send(PluginEvent(window: window.id, kind: .click, view: button.id)) }
                            .buttonStyle(.borderedProminent).disabled(!button.enabled)
                    } else {
                        Button(button.text) { send(PluginEvent(window: window.id, kind: .click, view: button.id)) }
                            .buttonStyle(.bordered).disabled(!button.enabled)
                    }
                }
            }
        }
    }

    /// Android's order: neutral first, then negative, positive last.
    private func order(_ role: PluginWindow.Button.Role) -> Int {
        switch role { case .neutral: 0; case .negative: 1; case .positive: 2 }
    }
}

private struct PluginNodeView: View {
    struct Context {
        let window: Int
        /// The window has the plugin's own background, so its colors are kept.
        let painted: Bool
        let typed: Binding<[Int: String]>
        let send: (PluginEvent) -> Void
        func tap(_ node: PluginNode) { send(PluginEvent(window: window, kind: .click, view: node.id)) }
        func change(_ node: PluginNode, _ value: PluginEvent.Value) { send(PluginEvent(window: window, kind: .change, values: [node.id: value])) }
    }
    let node: PluginNode
    let context: Context
    private var scale: Double { PluginWindowView.scale }

    var body: some View {
        WithPerceptionTracking {
            content
                .opacity(node.enabled ? (node.alpha ?? 1) : 0.45)
        }
    }

    @ViewBuilder private var content: some View {
        switch node.kind {
        case .stack, .scroll, .radios: tappable(container)
        case .text: tappable(label(node))
        case .button:
            Button { context.tap(node) } label: { label(node).frame(maxWidth: node.fillWidth ? .infinity : nil) }
                .buttonStyle(.bordered).disabled(!node.enabled)
        case .input: field
        case .check, .switch:
            Toggle(isOn: Binding(get: { node.checked }, set: { context.change(node, .on($0)) })) { label(node) }
                .disabled(!node.enabled)
        case .radio:
            Button { if !node.checked { context.change(node, .on(true)) } } label: {
                HStack(spacing: 10) {
                    Image(systemName: node.checked ? "largecircle.fill.circle" : "circle").foregroundStyle(.tint)
                    label(node)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PluginTapStyle())
        case .progress:
            if node.indeterminate { ProgressView().frame(maxWidth: .infinity) }
            else { ProgressView(value: Double(node.progress - node.minimum), total: Double(max(1, node.maximum - node.minimum))) }
        case .slider: slider
        case .image: tappable(picture)
        case .view: spacer
        }
    }

    // Containers: Android's LinearLayout and FrameLayout, each child with its share of the line.
    @ViewBuilder private var container: some View {
        let spacing = 8 * scale
        switch node.axis {
        case .h:
            let row = HStack(alignment: .center, spacing: spacing) { children }
            if node.kind == .scroll { ScrollView(.horizontal, showsIndicators: false) { WithPerceptionTracking { row } } }
            else { ViewThatFits(in: .horizontal) { row; ScrollView(.horizontal, showsIndicators: false) { WithPerceptionTracking { row } } } }
        case .z:
            ZStack(alignment: .topLeading) { children }
        case .v:
            VStack(alignment: node.centered ? .center : .leading, spacing: spacing) { children }
        }
    }

    @ViewBuilder private var children: some View {
        ForEach(node.children) { child in
            WithPerceptionTracking {
                let view = PluginNodeView(node: child, context: context)
                if node.axis == .h, child.weight != nil { view.frame(maxWidth: .infinity, alignment: child.trailing ? .trailing : .leading) }
                else if node.axis == .v, child.fillWidth { view.frame(maxWidth: .infinity, alignment: child.centered ? .center : child.trailing ? .trailing : .leading) }
                else { view }
            }
        }
    }

    /// A view with a listener is a button; one the plugin paints gets its color and rounded plate.
    @ViewBuilder private func tappable(_ inner: some View) -> some View {
        let plated = inner
            .padding(insets)
            .background { WithPerceptionTracking { if let plate { RoundedRectangle(cornerRadius: 10 * scale, style: .continuous).fill(plate) } } }
        if node.tappable {
            Button { context.tap(node) } label: { plated.contentShape(Rectangle()) }
                .buttonStyle(PluginTapStyle())
                .disabled(!node.enabled)
                .accessibilityLabel(node.spokenText)
        } else {
            plated
        }
    }

    /// The plugin's own padding; a painted plate without one still gets room around its content.
    private var insets: EdgeInsets {
        if let p = node.padding { return EdgeInsets(top: p[1] * scale, leading: p[0] * scale, bottom: p[3] * scale, trailing: p[2] * scale) }
        let room = plate == nil ? 0 : 10 * scale
        return EdgeInsets(top: room, leading: room, bottom: room, trailing: room)
    }

    private var plate: Color? {
        guard let background = node.background, background.alpha > 0.05 else { return nil }
        if context.painted { return background.color }
        return node.selected ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.15)
    }

    private func label(_ node: PluginNode) -> some View {
        Text(node.text ?? "")
            .font(.system(size: (node.size ?? 15) * scale, weight: node.bold ? .semibold : .regular))
            .foregroundStyle(textColor(node))
            .lineLimit(node.lines)
            .multilineTextAlignment(node.centered ? .center : node.trailing ? .trailing : .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func textColor(_ node: PluginNode) -> Color {
        guard context.painted, let color = node.color else { return node.selected ? .accentColor : .primary }
        return color.color
    }

    @ViewBuilder private var field: some View {
        let text = Binding(get: { context.typed.wrappedValue[node.id] ?? node.text ?? "" },
                           set: { context.typed.wrappedValue[node.id] = $0 })
        let prompt = Text(node.hint ?? "")
        Group {
            if node.secure { SecureField(node.hint ?? "", text: text, prompt: prompt) }
            else if node.multiline { TextField(node.hint ?? "", text: text, prompt: prompt, axis: .vertical).lineLimit(3...8) }
            else { TextField(node.hint ?? "", text: text, prompt: prompt) }
        }
        #if !os(tvOS)
        .textFieldStyle(.roundedBorder)
        #endif
        #if os(iOS)
        .keyboardType(node.keyboard == "number" ? .numberPad : node.keyboard == "url" ? .URL : node.keyboard == "email" ? .emailAddress : .default)
        .textInputAutocapitalization(.never)
        #endif
        .autocorrectionDisabled()
        .onSubmit { context.send(PluginEvent(window: context.window, kind: .submit, view: node.id, values: [node.id: .text(text.wrappedValue)])) }
        .disabled(!node.enabled)
    }

    @ViewBuilder private var slider: some View {
        #if os(tvOS)
        HStack(spacing: 20) {
            Button { context.change(node, .number(max(node.minimum, node.progress - node.step))) } label: { Image(systemName: "minus") }
            Text("\(node.progress)").monospacedDigit().frame(minWidth: 80)
            Button { context.change(node, .number(min(node.maximum, node.progress + node.step))) } label: { Image(systemName: "plus") }
        }
        #else
        PluginSlider(node: node) { context.change(node, .number($0)) }
        #endif
    }

    @ViewBuilder private var picture: some View {
        if let data = node.image, let image = PlatformImage(data: data) {
            let width = (node.width ?? Double(image.size.width) / 2) * scale, height = (node.height ?? Double(image.size.height) / 2) * scale
            #if os(macOS)
            let drawn = Image(nsImage: image)
            #else
            let drawn = Image(uiImage: image)
            #endif
            // Plugins' pictures are mostly QR codes: keep their pixels sharp.
            VStack(spacing: 10 * scale) {
                drawn.resizable().interpolation(.none)
                    .aspectRatio(contentMode: node.fill ? .fill : .fit)
                    .overlay { WithPerceptionTracking { touchArea } }
                    .frame(maxWidth: width, maxHeight: height)
                    .clipped()
                if !node.touch { PluginCodeLink(image: data) }
            }
            .frame(maxWidth: .infinity)
        } else {
            spacer
        }
    }

    /// On a picture the plugin reads touches on (a color wheel), a tap or the end of a drag sends where it landed.
    @ViewBuilder private var touchArea: some View {
        #if os(tvOS)
        EmptyView()
        #else
        if node.touch, node.enabled {
            GeometryReader { frame in
                WithPerceptionTracking {
                    Color.clear.contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onEnded { drag in
                            guard frame.size.width > 0, frame.size.height > 0 else { return }
                            context.send(PluginEvent(window: context.window, kind: .touch, view: node.id,
                                                     x: drag.location.x / frame.size.width, y: drag.location.y / frame.size.height))
                        })
                }
            }
        }
        #endif
    }

    /// An empty view: a gap, or a line or block when the plugin colors it.
    @ViewBuilder private var spacer: some View {
        if let plate, let height = node.height {
            Rectangle().fill(plate).frame(height: CGFloat(height * scale))
                .frame(maxWidth: node.fillWidth ? .infinity : node.width.map { CGFloat($0 * scale) } ?? .infinity)
        } else if node.weight != nil {
            Spacer(minLength: 0)
        } else if let height = node.height {
            Color.clear.frame(height: CGFloat(height * scale))
        }
    }
}

#if !os(tvOS)
/// A plugin's SeekBar: the plugin hears the value once the drag ends, as Android's onStopTrackingTouch.
private struct PluginSlider: View {
    let node: PluginNode
    let commit: (Int) -> Void
    @State private var value: Double?
    var body: some View {
        WithPerceptionTracking {
            HStack {
                Slider(value: Binding(get: { value ?? Double(node.progress) }, set: { value = $0 }),
                       in: Double(node.minimum)...Double(max(node.minimum + 1, node.maximum)), step: Double(node.step)) { editing in
                    if !editing, let value { commit(Int(value)); self.value = nil }
                }
                Text("\(Int(value ?? Double(node.progress)))").monospacedDigit().frame(minWidth: 40)
            }
        }
    }
}
#endif

/// Taps on a plugin's own rows: no extra chrome (the plugin paints them), a lift on Apple TV focus.
private struct PluginTapStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        WithPerceptionTracking {
            #if os(tvOS)
            PluginFocusLift(label: configuration.label, pressed: configuration.isPressed)
            #else
            configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
            #endif
        }
    }
}

#if os(tvOS)
private struct PluginFocusLift<Label: View>: View {
    @Environment(\.isFocused) private var focused
    let label: Label
    let pressed: Bool
    var body: some View {
        WithPerceptionTracking {
            label
                .overlay { WithPerceptionTracking { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.accentColor, lineWidth: focused ? 4 : 0) } }
                .scaleEffect(pressed ? 0.98 : focused ? 1.03 : 1)
                .shadow(color: .black.opacity(focused ? 0.3 : 0), radius: 12, y: 6)
                .animation(.easeOut(duration: 0.15), value: focused)
        }
    }
}
#endif

private extension PluginColor {
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
}

#if os(macOS)
private typealias PlatformImage = NSImage
#else
private typealias PlatformImage = UIImage
#endif

struct VideoDetailView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dismiss) private var dismiss
    @Environment(Store.self) private var store
    let video: Video
    let client: CatalogClient
    /// Opened from Continue Watching: retain its position until the viewer presses Play.
    var resume: PlaybackHistoryEntry? = nil
    /// A push source already resolved this detail, including provider file IDs and lines.
    var preloaded: Video? = nil
    var metadataHint: MediaMetadataHint? = nil
    #if os(iOS)
    @Environment(\.isLocalPageActive) private var localPageActive
    @Environment(\.localDockInset) private var localDockInset
    /// The source's config center, open in the app (`ConfigCenterView`).
    @State private var showsConfigCenter = false
    #endif
    @State private var requestTask: Task<Void, Never>?
    @State private var detail: Video?
    /// Short labels (第1集) for lines whose episode names are file names, by episode id (#318). Display only.
    @State private var episodeLabels: [Episode.ID: String] = [:]
    /// Resolution and size read from file names (4K · 5.2G, #620), under the episodes' names.
    @State private var episodeDetails: [Episode.ID: String] = [:]
    @State private var error: String?
    @State private var busy = false
    @State private var synopsisExpanded = false
    @State private var selectedFlag: String?
    /// The last episode chosen on this page; both play modes keep this same target on its line.
    @State private var selectedEpisode: Episode?
    @State private var rejectedArtworkSelection = false
    @State private var rejectedArtworkURL: URL?
    /// 倒序: the episode lists show the last episode first. Remembered for every video.
    @AppStorage("episodesReversed") private var reversesEpisodes = false
    /// Play takes over focus from the loading placeholder; otherwise nothing is focused once details load.
    @FocusState private var playFocused: Bool
    @State private var containerWidth: CGFloat = 0
    /// The cover's width over height once it loads; landscape covers are common (Bilibili, short dramas).
    @State private var artAspect: CGFloat?
    @State private var titleLogoAspect: CGFloat?
    #if os(iOS)
    @State private var detailArtworkSelection = 0
    @State private var detailArtworkPaused = false
    @State private var detailArtworkPaint: DiscoverPaint?
    @State private var choosingDetailArtwork = false
    @State private var choosingDetailMatch = false
    @State private var showingDetailOverview = false
    @State private var showingDetailCalendar = false
    @State private var detailSectionsPresented = false
    @State private var mobileEpisodeGroup = 0
    @State private var mobileEpisodeGroupFlag: String?
    @State private var mobileEpisodeList = false
    #endif
    /// TMDB's backdrop once its picture has loaded. The source's cover stays until then, and when it never does
    /// (image.tmdb.org is blocked on some networks, #237).
    @State private var loadedBackdrop: URL?
    /// The episode whose playback is being prepared; its row and the Play button show progress.
    @State private var loadingEpisode: Episode.ID?
    @State private var loadingMode: PlaybackResumeMode?
    /// A failed or blocked playback attempt, shown as an inline banner beside the artwork.
    @State private var playbackIssue: PlaybackIssue?
    /// A drive sign-in the source's CatPawOpen bundle runs itself, with its own code (`CatPawSignIn`).
    @State private var bundleSignIn: BundleSignIn?
    @State private var choosingDownloads = false
    /// How many episodes were just queued, shown briefly under the header.
    @State private var queuedNotice: Int?
    /// TMDB's details for the video (TMDBViews.swift). The page shows the source's own until they are in, then fades them in.
    @State private var tmdb = TMDBLookup()
    private var flags: [String] {
        var seen = Set<String>()
        return (detail?.episodes ?? []).map(\.flag).filter { seen.insert($0).inserted }
    }
    private var activeFlag: String { flags.contains(selectedFlag ?? "\u{0}") ? selectedFlag! : (flags.first ?? "") }
    /// The active line's episodes. `activeFlag` goes through every episode, so it is read once, not once per episode:
    /// in the filter it made each page update quadratic (4 lines of 1,000 episodes took seconds, and iOS killed the app).
    private var activeEpisodes: [Episode] {
        let flag = activeFlag
        return (detail?.episodes ?? []).filter { $0.flag == flag }
    }
    private var wideMinWidth: CGFloat {
        #if os(tvOS)
        1200
        #else
        760
        #endif
    }
    private func startRequest(_ operation: @escaping @MainActor () async -> Void) {
        #if os(iOS)
        guard localPageActive else { return }
        #endif
        let previous = requestTask
        previous?.cancel()
        requestTask = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await operation()
        }
    }

    var body: some View {
        WithPerceptionTracking {
            pageBody
            #if os(iOS)
            .overlay(alignment: .bottom) {
                WithPerceptionTracking {
                    loadingCard.padding(.bottom, localDockInset).allowsHitTesting(false)
                }
            }
            #else
            .safeAreaInset(edge: .bottom) { WithPerceptionTracking { loadingCard } }
            #endif
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { containerWidth = $0 }
            #if os(macOS)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { WithPerceptionTracking { DetailAurora(poster: video.poster, headers: video.posterHeaders) } }
            #else
            .screenBackdrop()
            #endif
            #if os(iOS)
            .navigationTitle("").navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(mobileDetailDark ? .dark : .light, for: .navigationBar)
            #else
            .screenTitle(video.name)
            #endif
            .task {
                store.searchModel.suspend()
                if detail == nil { await loadDetail() }
            }
            .onDisappear { requestTask?.cancel() }
            #if os(iOS)
            .appOnChange(of: localPageActive) { _, active in if !active { requestTask?.cancel() } }
            #endif
            .task(id: detail?.id) { await startTMDB() }
            .task(id: artworkDecisionID) { await retainMatchedArtwork() }
            .onReceive(NotificationCenter.default.publisher(for: TMDBServiceSettings.changed)) { _ in
                tmdb = TMDBLookup(); loadedBackdrop = nil
                Task { await startTMDB() }
            }
            #if os(iOS)
            .sheet(isPresented: $showsConfigCenter) { WithPerceptionTracking { ConfigCenterView { await configCenterAddress() } } }
            .localGlassDialog(isPresented: $choosingDetailMatch, title: "手动匹配 TMDB", layout: .centered) {
                WithPerceptionTracking { TMDBPicker(lookup: tmdb, title: currentVideo().name) }
            }
            .sheet(isPresented: $choosingDetailArtwork) {
                WithPerceptionTracking {
                    LocalCatalogPosterPicker(images: mobileDetailArtwork, video: currentVideo(), selection: $detailArtworkSelection, paused: $detailArtworkPaused)
                }
            }
            .localGlassDialog(isPresented: $showingDetailOverview, title: "剧情简介", layout: .centered) {
                WithPerceptionTracking {
                    LocalCatalogSynopsisSheet(title: tmdb.details?.name ?? currentVideo().name, overview: mobileDetailOverview, sourceOverview: mobileSourceOverview)
                }
            }
            .localGlassDialog(isPresented: $showingDetailCalendar, title: "播出日历", maxWidth: 510, layout: .calendar) {
                WithPerceptionTracking {
                    if let details = tmdb.details {
                        DiscoverBroadcastCalendarView(item: mobileCatalogItem(details), seasons: details.seasons.filter { $0.number > 0 }, details: details)
                    }
                }
            }
            #endif
            // The source's own sign-in where playback failed, then the episode that needed the account plays. Plugins that
            // sign in by themselves show their code while the request runs (PluginSignIn); the app's sign-ins stay in
            // Settings, whose accounts every source gets.
            #if os(tvOS)
            .fullScreenCover(item: $bundleSignIn) { pending in
                WithPerceptionTracking {
                    CatPawSignInView(client: client, provider: pending.provider) { retryAfterSignIn() }
                }
            }
            #else
            .sheet(item: $bundleSignIn) { pending in
                WithPerceptionTracking {
                    CatPawSignInView(client: client, provider: pending.provider) { retryAfterSignIn() }
                }
            }
            #endif
            .downloadPicker(isPresented: $choosingDownloads) {
                DownloadPicker(video: video, site: client.site, flag: activeFlag,
                               episodes: activeEpisodes) { count in
                    guard count > 0 else { return }
                    withAnimation(.appSmooth(duration: 0.2)) { queuedNotice = count }
                    Task { try? await Task.sleep(for: .seconds(6)); withAnimation(.appSmooth(duration: 0.2)) { queuedNotice = nil } }
                }
            }

        }
    }

    /// A detail page on every device. Playback starts only through the Play or episode actions.
    @ViewBuilder
    private var pageBody: some View {
        #if os(iOS)
        mobileDetailPage
        #else
        ScrollView {
            WithPerceptionTracking {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    if detail != nil {
                        episodePanel
                        tmdbExtras
                    } else if let error {
                        errorCard(error).padding(.top, 12)
                    } else {
                        // The Play placeholder in the header holds focus while details load.
                        DetailSkeleton()
                    }
                }
                .pageContainer()
            }
        }
        #endif
    }

    @ViewBuilder private var loadingCard: some View {
        if busy {
            // Keyed by the step, so the timer restarts when details turn into resolving a link.
            LoadingCard { .source(client.site, origin: client.origin, title: busyTitle) }
                .id(busyTitle)
                .frame(maxWidth: .infinity).padding(.horizontal, Layout.gutter).padding(.bottom, 24)
        }
    }
    @ViewBuilder private var playbackBanner: some View {
        if let count = queuedNotice {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Brand.accent)
                Text(count == 1 ? L10n.text("1 episode added to Downloads.") : L10n.text("%lld episodes added to Downloads.", count)).font(.subheadline.weight(.medium))
                Spacer(minLength: 8)
                Button(L10n.text("Show Downloads")) { store.section = .downloads }.settingsButton()
            }
            .padding(14)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
        if let issue = playbackIssue {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: issue.signIn != nil ? "person.crop.circle.badge.exclamationmark.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(Brand.amber)
                    .frame(width: 36, height: 36)
                    .background(Brand.amber.opacity(0.15), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.text("Couldn't play %@", EpisodeRow.title(issue.episode.name)))
                            .font(.headline).lineLimit(2)
                        Text(issue.message).font(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).selectable()
                    }
                    HStack(spacing: 8) {
                        if let provider = issue.signIn {
                            Button(provider == "ucToken" ? L10n.text("Get UC TV Token") : L10n.text("Sign In to %@", CatPawSignIn.driveName(provider))) {
                                bundleSignIn = BundleSignIn(provider: provider)
                            }
                            .settingsButton(prominent: true)
                            .accessibilityIdentifier("playbackIssue.bundleSignIn")
                        }
                        Button(L10n.text("Retry")) { startRequest { await play(issue.episode, mode: issue.mode) } }
                            .settingsButton(prominent: issue.signIn == nil)
                        #if os(tvOS)
                        // A focusable action instead of the small corner close button.
                        Button(L10n.text("Dismiss")) { withAnimation(.appSmooth(duration: 0.2)) { playbackIssue = nil } }.settingsButton()
                        #endif
                    }
                }
                Spacer(minLength: 0)
                #if !os(tvOS)
                Button { withAnimation(.appSmooth(duration: 0.2)) { playbackIssue = nil } } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Color.primary.opacity(0.07), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain).accessibilityLabel(L10n.text("Dismiss")).help(L10n.text("Dismiss"))
                #endif
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay { WithPerceptionTracking { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.08)) } }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
    private func errorCard(_ error: String) -> some View {
                    ErrorStateCard(
                        title: detail == nil ? L10n.text("Unable to load video details") : L10n.text("Unable to start playback"),
                        message: detail == nil
                            ? L10n.text("Try again, or go back and choose another video.")
                            : L10n.text("Try another episode or playback source."),
                        details: error,
                        retry: detail == nil ? { startRequest { await loadDetail() } } : nil,
                        goBack: { dismiss() },
                        busy: busy,
                        backTitle: L10n.text("Go back")
                    )
    }
    private var busyTitle: String {
        if detail == nil { return L10n.text("Loading video details…") }
        let episode = detail?.episodes.first { $0.id == loadingEpisode }
        return episode.map { L10n.text("Getting the video link for %@…", EpisodeRow.title($0.name)) } ?? L10n.text("Getting the video link…")
    }
    private func loadDetail() async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let value: Video
            if let preloaded { value = preloaded }
            else { value = try await client.detail(video.id, cached: client.site.type == 3 || client.site.type == 4) }
            try Task.checkCancellation()
            // Worked out once, off the main thread: a line can hold thousands of episodes.
            let episodes = value.episodes
            (episodeLabels, episodeDetails) = await Task.detached(priority: .userInitiated) {
                let labels = EpisodeLabels.labels(episodes)
                return (labels, EpisodeFileInfo.details(episodes, labels: labels))
            }.value
            detail = value
            // Start on the line watched last (#362), else on one that can play: not one from a drive the viewer has no
            // way to sign in to.
            if selectedFlag == nil { selectedFlag = watchedFlag ?? CloudDrive.preferredFlag(flags) }
            #if os(tvOS)
            Task { try? await Task.sleep(for: .milliseconds(100)); playFocused = true }
            #endif
        } catch {
            guard !Task.isCancelled else { return }
            Diagnostics.shared.failure("catalog", "detail \(client.reportContext)", error)
            self.error = error.localizedDescription
            #if os(tvOS)
            // The loading placeholder that held focus is gone: Retry in the hero takes it.
            Task { try? await Task.sleep(for: .milliseconds(100)); playFocused = true }
            #endif
        }
    }
    /// What this device knows shows at once; otherwise the lookup starts once the source's details are in (their
    /// synopsis and episodes help tell works of the same name apart).
    private func startTMDB() async {
        guard TMDBLookup.applies(to: client.site) else { return }
        let sourceIdentity = PosterPresentation.matchSourceIdentity(origin: client.origin, sourceKey: client.site.sourceKey)
        let key = TMDBMatchStore.key(source: sourceIdentity, video: video.id)
        // Starting a cached selection before source details arrive is cancelled by task(id: detail?.id).
        // Keep one request lifetime, with the synopsis and episode names available from the outset.
        guard let detail else { return }
        if let hint = metadataHint {
            _ = await tmdb.prepare(key: key)
            if !tmdb.chosen { await tmdb.choose(hint.mediaType, id: hint.id, season: hint.season) }
            return
        }
        let request = TMDBMatch.Request(video: detail.keepingPoster(video.poster), listVideo: video,
                                        source: TMDBMatch.SourceRef(key: client.site.key, name: client.site.name))
        // AI-generated videos and short dramas aren't on TMDB: the page keeps the source's own data.
        guard !TMDBMatch.labeledNotOnTMDB(request) else { tmdb.skip(); return }
        await tmdb.run(key: key, request: request)
    }
    /// A video without episodes. A config center entry (a CatPawOpen bundle's, #311, or a Wex plugin's, #360) opens its page in the app.
    @ViewBuilder private func noEpisodes(_ detail: Video) -> some View {
        #if os(iOS)
        if ConfigCenter.page(of: detail, site: client.site) != nil {
            Button { showsConfigCenter = true } label: { Label(L10n.text("Open Config Center"), systemImage: "gearshape") }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("detail.configCenter")
        } else {
            Text(L10n.text("No playable sources were found for this video.")).foregroundStyle(.secondary)
        }
        #else
        Text(L10n.text("No playable sources were found for this video.")).foregroundStyle(.secondary)
        #endif
    }
    #if os(iOS)
    /// The config center's address now. Asking the bundle again gives its current port, which changes when iOS took
    /// back its socket while the app was suspended; the page's details can be older than that, or cached.
    private func configCenterAddress() async -> URL? {
        let fresh = try? await client.detail(video.id)
        return (fresh ?? detail).flatMap { ConfigCenter.page(of: $0, site: client.site) }
    }
    #endif
    /// TMDB's story when it has one, else the source's synopsis.
    private func synopsisText(_ detail: Video) -> String {
        if let story = tmdb.details?.story, !story.isEmpty { return story }
        return detail.synopsis
    }
    /// The lookup's progress or its question, then TMDB's cast, facts and notice, under the page's own content.
    @ViewBuilder private var tmdbStatus: some View {
        TMDBLookupStatus(lookup: tmdb)
    }
    @ViewBuilder private var tmdbExtras: some View {
        if let details = tmdb.details {
            #if os(iOS)
            CatalogDetailSections(details: details) { detailSectionsPresented = $0 }
                .id("\(details.mediaType.rawValue):\(details.id)")
                .padding(.horizontal, -20)
            #else
            VStack(alignment: .leading, spacing: 22) {
                if !details.cast.isEmpty { TMDBCastRow(cast: details.cast) }
                TMDBInfoGrid(details: details)
                if let related = details.recommendations, !related.isEmpty {
                    TMDBRelatedRow(titles: related) { store.searchVideos($0) }
                }
                TMDBFooter(lookup: tmdb, title: currentVideo().name)
            }
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            #endif
        } else if let detail {
            #if os(iOS)
            CatalogSourceDetailSections(video: detail, sourceName: client.site.name)
            #else
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.text("Information")).font(.headline)
                Text(detail.name).font(.subheadline).selectable()
                Text(SourceLabel(client.site.name).text).font(.subheadline).foregroundStyle(.secondary)
                if let category = detail.category, !category.isEmpty { Text(category).font(.subheadline).foregroundStyle(.secondary) }
            }
            #endif
        }
    }
    private var bannerHeight: CGFloat {
        #if os(tvOS)
        // Leaves the synopsis in view under it.
        min(max(containerWidth * 0.38, 480), 680)
        #else
        min(max(containerWidth * 0.42, 280), 540)
        #endif
    }
    /// TMDB's backdrop banner once its picture is in, the source's cover and title until then.
    @ViewBuilder private var tmdbHero: some View {
        if let details = tmdb.details, let backdrop = details.backdrop, backdrop == loadedBackdrop {
            let banner = TMDBBanner(details: details, backdrop: backdrop, unmatched: tmdb.answer?.unmatched ?? "") { playControl }
            banner.frame(height: bannerHeight).transition(.opacity)
        } else {
            hero.transition(.opacity)
        }
    }
    private var headerLayout: AnyLayout {
        #if os(iOS)
        if sizeClass == .compact { return AnyLayout(HStackLayout(alignment: .top, spacing: 16)) }
        #endif
        return AnyLayout(HStackLayout(alignment: .top, spacing: 24))
    }
    private var compactDetail: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }
    @ViewBuilder private func synopsis(_ detail: Video) -> some View {
        let text = synopsisText(detail)
        if !text.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(text).foregroundStyle(.secondary)
                    .lineLimit(synopsisExpanded ? nil : synopsisLineLimit)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                if text.count > 100 {
                    let toggle = Button(L10n.text(synopsisExpanded ? "Show Less" : "Show Full Synopsis")) { synopsisExpanded.toggle() }
                    #if os(tvOS)
                    toggle.controlButton()
                    #else
                    toggle.buttonStyle(.plain).font(.subheadline.weight(.semibold)).frame(minHeight: 44, alignment: .leading)
                    #endif
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Full width, so Down from the banner's buttons reaches Show Full Synopsis wherever they sit.
            .tvFocusSection()
        }
    }
    private var synopsisLineLimit: Int {
        #if os(tvOS)
        4
        #else
        3
        #endif
    }
    private var posterWidth: CGFloat {
        #if os(macOS)
        150
        #elseif os(iOS)
        compactDetail ? 104 : 150
        #else
        Layout.detailPoster
        #endif
    }
    private var isWide: Bool { containerWidth >= wideMinWidth }
    /// Explicit home or matched work artwork replaces a push site's generic cover. Ordinary sources
    /// keep their own art, and a missing detail cover still falls back to the original list image.
    private func currentVideo() -> Video {
        let current = sourceVideo()
        if rejectedArtworkSelection { return current }
        if let artwork = matchedArtwork { return PosterPresentation.applying(artwork, to: current) }
        if let hint = metadataHint, hint.id > 0, !(tmdb.chosen && tmdb.phase == .notFound) {
            return PosterPresentation.applying(hint.poster, headers: hint.posterHeaders ?? [:], to: current)
        }
        return current
    }
    private func sourceVideo() -> Video {
        let raw = PosterPresentation.catalogDetail(detail ?? video, listing: video, preferListing: client.site.runtime == .python)
        let source = raw.poster
        // A home hint was injected before opening this push page. If its TMDB work is rejected,
        // it is no longer a source fallback; use the fixed placeholder until the source is refreshed.
        let rejectedHint = rejectedArtworkSelection && (source == metadataHint?.poster || source == rejectedArtworkURL)
        return PosterPresentation.replacing(rejectedHint ? nil : source,
                                            headers: raw.posterHeaders, in: raw)
    }
    private var matchedArtwork: URL? {
        guard tmdb.phase == .matched,
              client.pushInput != nil || PosterPresentation.imageURL((detail ?? video).poster) == nil else { return nil }
        return PosterPresentation.imageURL(tmdb.details?.poster ?? tmdb.details?.heroPoster)
    }
    private struct ArtworkDecisionID: Equatable {
        let details: TMDBMatch.Details?
        let rejected: Bool
    }
    private var artworkDecisionID: ArtworkDecisionID {
        ArtworkDecisionID(details: tmdb.details, rejected: tmdb.chosen && tmdb.phase == .notFound)
    }
    private func retainMatchedArtwork() async {
        guard let episode = (detail ?? video).episodes.first else { return }
        let rejected = tmdb.chosen && tmdb.phase == .notFound
        let wasRejected = rejectedArtworkSelection
        if rejected { rejectedArtworkSelection = true }
        else if tmdb.phase == .matched { rejectedArtworkSelection = false }
        guard rejected || matchedArtwork != nil else { return }
        var context = PlaybackHistoryContext(origin: client.origin, site: client.site, video: sourceVideo(), episode: episode)
        context.historyScope = store.historyScope ?? ""
        let reference = context
        let decidedAt = Date()
        if rejected {
            if wasRejected { return }
            rejectedArtworkURL = context.posterIsConfirmed == true ? context.poster : metadataHint?.poster
            let source = sourceVideo()
            store.playbackHistory.resetArtwork(for: context, poster: source.poster, headers: source.posterHeaders, decidedAt: decidedAt)
            await Task.detached(priority: .utility) {
                PushMediaLibrary.shared.resetArtwork(origin: reference.origin, sourceKey: reference.sourceKey, videoID: reference.videoID,
                                                     poster: source.poster, headers: source.posterHeaders, decidedAt: decidedAt)
            }.value
            return
        }
        guard let poster = matchedArtwork else { return }
        store.playbackHistory.updateArtwork(for: context, poster: poster, decidedAt: decidedAt)
        await Task.detached(priority: .utility) {
            PushMediaLibrary.shared.updateArtwork(origin: reference.origin, sourceKey: reference.sourceKey, videoID: reference.videoID,
                                                  poster: poster, decidedAt: decidedAt)
        }.value
    }

    private func videoFavorite() -> FavoriteItem {
        .video(FavoriteVideo(origin: client.origin, site: client.site, video: currentVideo()))
    }

    private func episodeFavorite(_ episode: Episode) -> FavoriteItem {
        .episode(FavoriteEpisode(video: FavoriteVideo(origin: client.origin, site: client.site, video: currentVideo()), episodeFlag: episode.flag, episodeName: episode.name, episodeID: episode.id))
    }

    @ViewBuilder private var playControl: some View {
        if let detail {
            // The episode watched last, or the next one once it is finished, so Play continues the video instead of
            // starting the line again (#593).
            let selection = DetailPlaybackSelection(episodes: detail.episodes, activeFlag: activeFlag,
                                                    selectedEpisode: selectedEpisode, history: watchHistories)
            if let first = selection.episode {
                #if os(iOS)
                VStack(alignment: .leading, spacing: 10) {
                    DetailPlaybackControls(selection: selection, busy: busy, loadingMode: loadingMode) { mode in
                        selectedEpisode = first
                        startRequest { await play(first, mode: mode) }
                    }
                    HStack(spacing: 10) { videoFavoriteButton; downloadButton(iconOnly: true) }
                }
                #else
                let continues = first == watchHistory?.continuation(in: activeEpisodes)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { playButton(first, continuation: continues); downloadButton(iconOnly: false); videoFavoriteButton }
                    HStack(spacing: 10) { playButton(first, continuation: continues); downloadButton(iconOnly: true); videoFavoriteButton }
                }
                #endif
            } else {
                #if os(tvOS)
                // No episodes, so no Play: without a button here nothing on the page could take focus, and Back
                // did nothing at all.
                goBackButton(prominent: true).focused($playFocused)
                #endif
            }
        } else if error == nil {
            // On Apple TV the hero fills the screen and the skeleton below it is off-screen: the
            // Play button's placeholder holds focus, so Back leaves the page instead of the app.
            SkeletonBlock(cornerRadius: 10).frame(width: 150, height: 40).loadingFocus(takeFocus: true) { dismiss() }
        } else {
            #if os(tvOS)
            // The details failed. The error card's buttons are below the full-screen hero, out of the remote's reach,
            // so the hero offers them too; they hold focus, and Back leaves the page again.
            HStack(spacing: 10) {
                Button { startRequest { await loadDetail() } } label: { Label(L10n.text("Retry"), systemImage: "arrow.clockwise") }
                    .controlButton(prominent: true).tint(Brand.accent).controlSize(.large)
                    .disabled(busy)
                    .focused($playFocused)
                    .accessibilityIdentifier("detail.retry")
                goBackButton(prominent: false)
            }
            #endif
        }
    }
    #if os(tvOS)
    private func goBackButton(prominent: Bool) -> some View {
        Button { dismiss() } label: { Label(L10n.text("Go back"), systemImage: "chevron.backward") }
            .controlButton(prominent: prominent).controlSize(.large)
            .accessibilityIdentifier("detail.goBack")
    }
    #endif
    private func playButton(_ episode: Episode, continuation: Bool = false) -> some View {
        Button { startRequest { await play(episode) } } label: {
            HStack(spacing: 8) {
                if loadingEpisode == episode.id { ProgressView().controlSize(.small) } else { Image(systemName: "play.fill") }
                #if os(iOS)
                Text(continuation ? "继续播放" : "开始播放")
                #else
                Text(L10n.text(continuation ? "Continue" : "Play"))
                #endif
            }
            .font(.headline).lineLimit(1).fixedSize().padding(.horizontal, 8)
        }
        .controlButton(prominent: true).tint(Brand.accent).controlSize(.large)
        .focused($playFocused)
        .accessibilityIdentifier("detail.play")
    }
    private func downloadButton(iconOnly: Bool) -> some View {
        Button { choosingDownloads = true } label: {
            Label(L10n.text("Download"), systemImage: "arrow.down.circle")
                .labelStyle(DownloadLabelStyle(iconOnly: iconOnly))
                .font(.headline).lineLimit(1).fixedSize()
        }
        .controlButton().controlSize(.large).accessibilityLabel(L10n.text("Download"))
    }
    /// Icon-only, beside Play and Download. An empty heart keeps the control color; a saved one is rose.
    /// Set as text in their font, so the button is as tall as theirs: a bare image made a smaller one on Apple TV.
    private var videoFavoriteButton: some View {
        let saved = store.favorites.contains(videoFavorite())
        let title = saved ? L10n.text("Remove %@ from favorites", currentVideo().name) : L10n.text("Add %@ to favorites", currentVideo().name)
        return Button { store.favorites.toggle(videoFavorite()) } label: {
            Group {
                #if os(iOS)
                Label(saved ? "已收藏" : "收藏", systemImage: saved ? "heart.fill" : "heart")
                    .foregroundStyle(saved ? Brand.rose : Color.primary)
                #else
                if saved {
                    Text(Image(systemName: "heart.fill")).foregroundStyle(Brand.rose)
                } else {
                    Text(Image(systemName: "heart"))
                }
                #endif
            }
            .font(.headline).lineLimit(1).fixedSize()
        }
        .controlButton().controlSize(.large)
        .accessibilityLabel(title).help(title)
        .accessibilityIdentifier("detail.favorite")
    }
    /// The source's cover in TMDB's banner shape, so the page keeps its layout when TMDB's backdrop fades in, and for
    /// titles TMDB doesn't have.
    private var hero: some View {
        PosterBanner(poster: video.poster, headers: video.posterHeaders, title: video.name, subtitle: video.remarks,
                     aspect: $artAspect) { playControl }
            .frame(height: bannerHeight)
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            #if os(iOS)
            mobileDetailHeader
            #else
            // TMDB's banner at any width, so a matched title's page looks the same everywhere.
            if isWide || hasBackdrop {
                tmdbHero
                playbackBanner
                tmdbStatus
                if let detail, !synopsisText(detail).isEmpty {
                    synopsis(detail).font(.body).padding(.horizontal, 18).padding(.vertical, 14)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            } else {
                HStack(alignment: .top, spacing: 14) {
                    Color.clear.aspectRatio(2.0 / 3.0, contentMode: .fit).frame(width: posterWidth)
                        .overlay { WithPerceptionTracking { PosterImage(url: video.poster, headers: video.posterHeaders) } }
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    // As tall as the 2:3 poster, so the buttons line up with its bottom edge.
                    MinHeightLayout(minHeight: posterWidth * 1.5) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(video.name).font(.title3.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                            if !video.remarks.isEmpty { Text(video.remarks).font(.subheadline).foregroundStyle(.secondary) }
                            if let facts = tmdb.details?.facts, !facts.isEmpty {
                                Text(facts).font(.subheadline).foregroundStyle(.secondary).transition(.opacity)
                            }
                            Spacer(minLength: 0)
                            playControl
                        }
                    }
                    Spacer(minLength: 0)
                }
                playbackBanner
                tmdbStatus
                if let detail { synopsis(detail) }
            }
            #endif
        }
        .animation(.appSmooth(duration: 0.45), value: tmdb.details)
        .animation(.appSmooth(duration: 0.45), value: loadedBackdrop)
        .animation(.appSmooth(duration: 0.3), value: tmdb.phase)
        #if !os(iOS)
        .task(id: tmdb.details?.backdrop) {
            // Into TMDBArtwork's cache, so the banner shows it at once.
            guard let backdrop = tmdb.details?.backdrop,
                  await TMDBArtwork.load(backdrop, maxPixels: TMDBBannerMetrics.backdropPixels) != nil,
                  !Task.isCancelled else { return }
            loadedBackdrop = backdrop
        }
        #endif
    }
    #if os(iOS)
    private var mobileDetailArtwork: [URL] { LocalCatalogDetailArtwork.images(video: currentVideo(), details: tmdb.details) }
    private var mobileSourceMetadata: LocalCatalogSourceMetadata { LocalCatalogSourceMetadata(currentVideo()) }
    private var mobileDetailDark: Bool { detailArtworkPaint?.isDark ?? true }
    private var mobileDetailOverview: String {
        let tmdbText = tmdb.details?.overview.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return tmdbText.isEmpty ? mobileSourceMetadata.overview : tmdbText
    }
    private var mobileSourceOverview: String {
        let source = mobileSourceMetadata.overview
        let compact: (String) -> String = { $0.components(separatedBy: .whitespacesAndNewlines).joined().lowercased() }
        return tmdb.details?.overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false && compact(source) != compact(mobileDetailOverview) ? source : ""
    }
    private var mobileDetailPage: some View {
        GeometryReader { geometry in
            WithPerceptionTracking {
                let width = geometry.size.width
                let height = width < 600 ? width * 1.5 : min(760, width * 0.7)
                ZStack(alignment: .top) {
                    (detailArtworkPaint?.color ?? Color.black).ignoresSafeArea()
                    LocalCatalogArtworkCarousel(video: currentVideo(), images: mobileDetailArtwork,
                                                presented: !choosingDetailArtwork && !choosingDetailMatch && !showingDetailOverview && !showingDetailCalendar && !detailSectionsPresented,
                                                selection: $detailArtworkSelection, paused: $detailArtworkPaused, paint: $detailArtworkPaint)
                        .frame(height: height).accessibilityIdentifier("detail.poster")
                    ScrollView {
                        WithPerceptionTracking {
                            VStack(alignment: .leading, spacing: 24) {
                                header
                                if detail != nil {
                                    episodePanel
                                    tmdbExtras
                                } else if let error { errorCard(error).padding(.top, 12) }
                                else { DetailSkeleton() }
                            }
                            .padding(.horizontal, 20).padding(.bottom, 40)
                        }
                    }.scrollIndicators(.hidden)
                }
            }
        }
        .foregroundStyle(mobileDetailDark ? Color.white : Color.black)
        .environment(\.colorScheme, mobileDetailDark ? .dark : .light)
        .ignoresSafeArea(edges: .top)
    }

    private var mobileDetailHeader: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 16) {
                Color.clear.frame(height: containerWidth < 600 ? containerWidth * 0.95 : containerWidth * 0.25)
                    .overlay(alignment: .top) {
                        mobileDetailTools.padding(.top, containerWidth < 600 ? 110 : 80)
                    }
                if let original = tmdb.details?.originalName, !original.isEmpty, original != tmdb.details?.name {
                    Text(original).font(.system(size: 13)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).multilineTextAlignment(.center)
                }
                LocalCatalogDetailTitle(title: tmdb.details?.name ?? currentVideo().name, logo: tmdb.details?.logo, width: containerWidth)
                    .id(tmdb.details?.logo)
                LocalCatalogMetadataPills(details: tmdb.details, year: mobileSourceMetadata.year,
                                          area: mobileSourceMetadata.area, remarks: mobileSourceMetadata.remarks,
                                          calendar: { showingDetailCalendar = true })
                if !mobileDetailOverview.isEmpty {
                    LocalCatalogSynopsisButton(overview: mobileDetailOverview) { showingDetailOverview = true }
                }
                playControl
                playbackBanner
                if tmdb.phase == .ambiguous { tmdbStatus }
            }
        }
    }
    private var mobileDetailTools: some View {
        HStack(spacing: 4) {
            Text([tmdb.details.map { $0.mediaType == .movie ? "电影" : "剧集" } ?? mobileSourceMetadata.type,
                  SourceLabel(client.site.name).text].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.system(size: 11, weight: .medium)).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityValue(mobileTMDBStatus)
            if containerWidth >= 600 {
                if tmdb.phase == .looking { ProgressView().controlSize(.mini) }
                Text(mobileTMDBStatus).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            LocalCatalogArtworkControls(count: mobileDetailArtwork.count, selection: $detailArtworkSelection, paused: $detailArtworkPaused) {
                choosingDetailArtwork = true
            }.fixedSize()
            if TMDBLookup.applies(to: client.site), tmdb.phase != .off {
                Button { choosingDetailMatch = true } label: {
                    if containerWidth >= 600 {
                        Label(tmdb.details == nil ? "匹配影片" : "更换匹配", systemImage: "magnifyingglass")
                            .font(.caption.weight(.semibold)).padding(.horizontal, 8).frame(minHeight: 44)
                    } else {
                        Image(systemName: tmdb.phase == .failed ? "exclamationmark.magnifyingglass" : "magnifyingglass")
                            .frame(width: 44, height: 44)
                            .overlay(alignment: .topTrailing) { if tmdb.phase == .looking { ProgressView().controlSize(.mini) } }
                    }
                }
                .buttonStyle(.plain).accessibilityIdentifier("detail.match")
                .accessibilityLabel(tmdb.details == nil ? "匹配影片" : "更换匹配").accessibilityValue(mobileTMDBStatus)
                .contextMenu { if tmdb.phase == .failed { Button("重试 TMDB") { Task { await tmdb.retry() } } } }
            }
        }.frame(height: 44)
    }
    private var mobileTMDBStatus: String {
        if detail == nil { return "正在读取影片详情…" }
        if !TMDBLookup.applies(to: client.site) || tmdb.phase == .off { return "来源资料" }
        switch tmdb.phase {
        case .looking: return "正在获取 TMDB 资料…"
        case .failed: return "TMDB 暂时不可用"
        case .matched: return "TMDB"
        default: return "未匹配到 TMDB 作品"
        }
    }
    private func mobileCatalogItem(_ details: TMDBMatch.Details) -> TMDBCatalog.Item {
        TMDBCatalog.Item(id: details.id, mediaType: details.mediaType, name: details.name, originalName: details.originalName,
                         year: details.year, overview: details.overview, poster: details.poster, backdrop: details.backdrop,
                         rating: details.rating, genreIDs: [])
    }
    #endif
    private var hasBackdrop: Bool {
        tmdb.details?.backdrop != nil && tmdb.details?.backdrop == loadedBackdrop
    }
    @ViewBuilder private var episodePanel: some View {
        if let detail {
            if detail.episodes.isEmpty {
                noEpisodes(detail)
            } else {
                let items = activeEpisodes
                #if os(iOS)
                mobileEpisodePanel(items)
                #else
                VStack(alignment: .leading, spacing: 12) {
                    #if os(iOS)
                    Text("线路").font(.headline)
                    mobileFlagPicker
                    #endif
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        #if os(tvOS)
                        if items.count > 1 {
                            episodeOrderButton(count: items.count)
                        } else {
                            Text(L10n.text("Episodes")).font(.headline)
                        }
                        #else
                        Text(L10n.text("Episodes")).font(.headline)
                        Text("\(items.count)").font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                        if items.count > 1 { episodeOrderButton }
                        #endif
                        Spacer(minLength: 8)
                        if flags.count == 1, !activeFlag.isEmpty {
                            Text(SourceLabel(activeFlag).text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    #if !os(iOS)
                    flagPicker
                    #endif
                    episodeList(items)
                }
                #endif
            }
        }
    }
    #if os(iOS)
    private func mobileEpisodePanel(_ items: [Episode]) -> some View {
        let metadata = tmdb.episodes(items)
        let entries = LocalCatalogDetailEpisode.entries(items, metadata: metadata, details: tmdb.details,
                                                        sourceTitle: currentVideo().name, flag: activeFlag, fileDetails: episodeDetails)
        let ordered = LocalCatalogDetailRules.ordered(entries.map(\.key))
        let count = (entries.count + LocalCatalogDetailRules.groupSize - 1) / LocalCatalogDetailRules.groupSize
        let group = mobileEpisodeGroupFlag == activeFlag ? min(mobileEpisodeGroup, max(0, count - 1)) : 0
        let visible = LocalCatalogDetailRules.page(ordered, group: group, descending: reversesEpisodes).map { entries[$0.index] }
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text("线路").font(.headline)
                mobileFlagPicker
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text("剧集").font(.headline)
                    Text("\(items.count) 集").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                    if count > 1 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 5) {
                                ForEach(0..<count, id: \.self) { index in
                                    WithPerceptionTracking {
                                        let start = index * LocalCatalogDetailRules.groupSize + 1
                                        let end = min((index + 1) * LocalCatalogDetailRules.groupSize, entries.count)
                                        Button { mobileEpisodeGroupFlag = activeFlag; mobileEpisodeGroup = index } label: {
                                            Text(start == end ? "\(start)" : "\(start)-\(end)")
                                                .font(.system(size: 11)).monospacedDigit().padding(.horizontal, 10).frame(minHeight: 44)
                                                .foregroundStyle(index == group ? Brand.accent : Color.secondary)
                                                .background(index == group ? Brand.accent.opacity(0.1) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                                                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(index == group ? Brand.accent.opacity(0.45) : Color.primary.opacity(0.12), lineWidth: 0.5) }
                                        }.buttonStyle(.plain).accessibilityLabel("剧集分段 \(start) 到 \(end)")
                                            .accessibilityAddTraits(index == group ? .isSelected : [])
                                            .accessibilityIdentifier("detail.episodeGroup.\(index)")
                                    }
                                }
                            }
                        }
                    } else { Spacer(minLength: 0) }
                }
                HStack(spacing: 4) {
                    if tmdb.phase == .looking {
                        ProgressView().controlSize(.mini)
                        Text("正在获取剧集资料…").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    } else if tmdb.phase == .failed {
                        Button { Task { await tmdb.retry() } } label: { Label("重试剧集资料", systemImage: "arrow.clockwise").font(.system(size: 11)).frame(minHeight: 44) }
                            .buttonStyle(.plain).accessibilityIdentifier("detail.episodeMetadata.retry")
                    }
                    Spacer(minLength: 0)
                    if items.count > 1 {
                        Button { reversesEpisodes.toggle() } label: {
                            Label(reversesEpisodes ? "倒序" : "正序", systemImage: reversesEpisodes ? "arrow.up" : "arrow.down")
                                .font(.system(size: 11)).padding(.horizontal, 8).frame(minHeight: 44)
                        }.buttonStyle(.plain).accessibilityLabel(reversesEpisodes ? "切换为正序" : "切换为倒序")
                            .accessibilityIdentifier("episodes.reverse")
                    }
                    Button { mobileEpisodeList.toggle() } label: {
                        Label(mobileEpisodeList ? "缩略图" : "列表", systemImage: mobileEpisodeList ? "rectangle.stack" : "list.bullet")
                            .font(.system(size: 11)).padding(.horizontal, 8).frame(minHeight: 44)
                            .foregroundStyle(mobileEpisodeList ? Brand.accent : Color.primary)
                    }.buttonStyle(.plain).accessibilityLabel(mobileEpisodeList ? "显示剧集缩略图" : "显示默认剧集列表")
                        .accessibilityIdentifier("detail.episodes.layout")
                }
            }
            if loadingEpisode != nil {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在解析播放地址…").font(.system(size: 12)).foregroundStyle(.secondary) }
                    .accessibilityElement(children: .combine)
            }
            if mobileEpisodeList {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10, alignment: .top)], spacing: 10) {
                    ForEach(visible) { value in WithPerceptionTracking { mobileEpisodeButton(value, list: true) } }
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 16) {
                        ForEach(visible) { value in WithPerceptionTracking { mobileEpisodeButton(value, list: false) } }
                    }.padding(.vertical, 2)
                }.id("\(activeFlag):\(group):\(reversesEpisodes)")
            }
        }
        .appOnChange(of: activeFlag) { _, flag in mobileEpisodeGroupFlag = flag; mobileEpisodeGroup = 0 }
        .accessibilityIdentifier("detail.episodes")
    }

    private func mobileEpisodeButton(_ value: LocalCatalogDetailEpisode, list: Bool) -> some View {
        let episode = value.episode
        let saved = download(episode)
        let movie = tmdb.details?.mediaType == .movie
        return Button { selectedEpisode = episode; startRequest { await play(episode) } } label: {
            if list { LocalCatalogDetailEpisodeRow(value: value, movie: movie, loading: loadingEpisode == episode.id) }
            else {
                LocalCatalogDetailEpisodeCard(value: value, video: currentVideo(),
                                              movieArtwork: movie ? tmdb.details?.backdrop ?? tmdb.details?.poster : nil,
                                              movie: movie,
                                              loading: loadingEpisode == episode.id)
            }
        }
        .buttonStyle(.plain).disabled(loadingEpisode != nil)
        .accessibilityLabel("播放 \(episode.name)").accessibilityIdentifier("detail.episode." + episode.id)
        .overlay(alignment: .topTrailing) { if saved?.status == .completed { DownloadedBadge().padding(4) } }
        .overlay(alignment: .bottomTrailing) {
            if store.favorites.contains(episodeFavorite(episode)) {
                Image(systemName: "heart.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(Brand.rose).padding(4).allowsHitTesting(false)
            }
        }
        .contextMenu {
            WithPerceptionTracking {
                Text(episode.name)
                Button("从头播放", systemImage: "arrow.counterclockwise") {
                    selectedEpisode = episode
                    startRequest { await play(episode, mode: .beginning) }
                }
                FavoriteMenuButton(item: episodeFavorite(episode), name: episode.name)
                if saved == nil || saved?.status == .failed {
                    Button(L10n.text("Download"), systemImage: "arrow.down.circle") {
                        DownloadLibrary.shared.download(DownloadSource(site: client.site, videoID: video.id, episode: episode),
                                                        title: video.name, poster: video.poster, posterHeaders: video.posterHeaders)
                    }
                } else if let saved {
                    Button(L10n.text(saved.status == .completed ? "Delete Download" : "Cancel Download"), systemImage: "trash", role: .destructive) { DownloadLibrary.shared.remove([saved.id]) }
                }
            }
        }
    }

    private var mobileFlagPicker: some View {
        WithPerceptionTracking {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(flags, id: \.self) { flag in
                        WithPerceptionTracking {
                            Button { selectedFlag = flag } label: {
                                Text(flag.isEmpty ? "默认线路" : SourceLabel(flag).text)
                                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                                    .padding(.horizontal, 15).frame(minHeight: 44)
                                    .foregroundStyle(flag == activeFlag ? Brand.onAccent : Color.primary)
                                    .background(flag == activeFlag ? Brand.accent : Color.primary.opacity(0.06), in: Capsule())
                            }
                            .buttonStyle(.plain).accessibilityIdentifier("detail.line." + flag)
                            .accessibilityAddTraits(flag == activeFlag ? .isSelected : [])
                        }
                    }
                }
            }.scrollIndicators(.hidden)
        }
    }
    #endif
    @ViewBuilder private var flagPicker: some View {
        if flags.count > 1 {
            #if os(tvOS)
            ChipRow {
                HStack(spacing: 8) {
                    ForEach(flags, id: \.self) { flag in
                        WithPerceptionTracking {
                            Chip(title: flag.isEmpty ? L10n.text("Play") : flag, selected: flag == activeFlag) { selectedFlag = flag }
                        }
                    }
                }
            }.tvFocusSection()
            #else
            SourceStrip(items: flags.map { .init(id: $0, name: $0.isEmpty ? L10n.text("Play") : $0) }, selection: activeFlag, horizontalInset: 16) { selectedFlag = $0 }
            #endif
        }
    }
    #if os(tvOS)
    /// On Apple TV the heading itself turns the list around (倒序): one glass button whose arrow shows the order,
    /// up for the first episode first, down for the last.
    private func episodeOrderButton(count: Int) -> some View {
        Button { reversesEpisodes.toggle() } label: {
            HStack(spacing: 10) {
                Image(systemName: reversesEpisodes ? "arrow.down" : "arrow.up").appSymbolReplaceTransition()
                Text(L10n.text("Episodes"))
                Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .glassPill()
        .accessibilityLabel(L10n.text("Reverse Order"))
        .accessibilityAddTraits(reversesEpisodes ? .isSelected : [])
        .accessibilityIdentifier("episodes.reverse")
    }
    #else
    /// The small button beside the episode count that turns the lists around (倒序).
    private var episodeOrderButton: some View {
        Button { reversesEpisodes.toggle() } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(reversesEpisodes ? Brand.accent : Color.secondary)
                .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.text("Reverse Order"))
        .accessibilityLabel(L10n.text("Reverse Order"))
        .accessibilityAddTraits(reversesEpisodes ? .isSelected : [])
        .accessibilityIdentifier("episodes.reverse")
    }
    #endif

    /// What the pickers show for an episode: its short label when its line has them, else its name without the size tag.
    private func episodeTitle(_ episode: Episode) -> String { episodeLabels[episode.id] ?? EpisodeRow.title(episode.name) }

    /// The episodes in the order the lists show them. Only the lists: Play and the next episode still follow the source.
    private func shownOrder(_ items: [Episode]) -> [Episode] { reversesEpisodes ? items.reversed() : items }

    private func episodeList(_ items: [Episode]) -> some View {
        // A chip fits about six characters before it truncates (《一…); longer names get rows.
        let longNames = (items.map { (episodeLabels[$0.id] ?? $0.name).count }.max() ?? 0) > 6
        // Under a full-width banner, long names fill columns rather than one stretched list.
        let rowColumns = isWide ? [GridItem(.adaptive(minimum: 320), spacing: 8)] : [GridItem(.flexible())]
        // TMDB's stills, when its season lines up with most of the episodes and has pictures for them; without
        // pictures the small chips read better than empty tiles. While TMDB is still looking, tiles with the episode
        // numbers, so its stills fade into the same tiles instead of chips turning into tiles.
        let stills = tmdb.episodes(items)
        #if os(iOS)
        let showsStills = true
        #else
        let showsStills = items.count > 1
            && (stills.values.filter { $0.still != nil }.count * 2 >= items.count || (tmdbPending && items.count <= 60))
        #endif
        #if os(iOS)
        let columns = [GridItem(.adaptive(minimum: 150), spacing: 12, alignment: .top)]
        #else
        let columns = showsStills ? [GridItem(.adaptive(minimum: TMDBMetrics.episodeTile), spacing: TMDBMetrics.spacing, alignment: .top)]
            : longNames ? rowColumns : [GridItem(.adaptive(minimum: episodeMin), spacing: 8)]
        #endif
        return LazyVGrid(columns: columns, spacing: showsStills ? TMDBMetrics.spacing : longNames ? 4 : 8) {
            WithPerceptionTracking {
                ForEach(shownOrder(items)) { episode in
                    WithPerceptionTracking {
                        let saved = download(episode)
                        Group {
                            if showsStills {
                                Button { startRequest { await play(episode) } } label: {
                                    #if os(iOS)
                                    LocalCatalogEpisodePoster(name: episodeTitle(episode), sourceName: episode.name, info: stills[episode.id],
                                                              fileDetail: episodeDetails[episode.id], video: currentVideo(),
                                                              loading: loadingEpisode == episode.id)
                                    #else
                                    TMDBEpisodeTile(name: episodeTitle(episode), info: stills[episode.id], detail: episodeDetails[episode.id],
                                                    loading: loadingEpisode == episode.id, width: nil)
                                    #endif
                                }
                                .tmdbCardButton()
                                .overlay(alignment: .topTrailing) { WithPerceptionTracking { if saved?.status == .completed { DownloadedBadge().padding(4) } } }
                                .accessibilityLabel(episode.name)
                            } else if longNames {
                                EpisodeRow(name: episode.name, label: episodeLabels[episode.id], file: episodeDetails[episode.id],
                                           loading: loadingEpisode == episode.id, download: saved) {
                                    startRequest { await play(episode) }
                                }
                            } else {
                                Chip(title: episodeLabels[episode.id] ?? episode.name, selected: loadingEpisode == episode.id, fill: true,
                                     subtitle: episodeDetails[episode.id]) { startRequest { await play(episode) } }
                                    .overlay(alignment: .topTrailing) { WithPerceptionTracking { if saved?.status == .completed { DownloadedBadge() } } }
                            }
                        }
                        .accessibilityIdentifier("detail.episode." + episode.id)
                        .overlay(alignment: .topLeading) {
                            WithPerceptionTracking {
                                if store.favorites.contains(episodeFavorite(episode)) {
                                    Image(systemName: "heart.fill")
                                        .font(.system(size: DownloadMetrics.thumb > 60 ? 18 : 12, weight: .semibold))
                                        .foregroundStyle(Brand.rose)
                                        .padding(4)
                                        .allowsHitTesting(false)
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                        .contextMenu {
                            WithPerceptionTracking {
                                // The file name a label stands for: its resolution and codec can matter on a netdisk line.
                                if episodeLabels[episode.id] != nil { Text(episode.name) }
                                FavoriteMenuButton(item: episodeFavorite(episode), name: episode.name)
                                if saved == nil || saved?.status == .failed {
                                    Button(L10n.text("Download"), systemImage: "arrow.down.circle") {
                                        DownloadLibrary.shared.download(DownloadSource(site: client.site, videoID: video.id, episode: episode),
                                                                        title: video.name, poster: video.poster, posterHeaders: video.posterHeaders)
                                    }
                                } else if let saved {
                                    Button(L10n.text(saved.status == .completed ? "Delete Download" : "Cancel Download"), systemImage: "trash", role: .destructive) {
                                        DownloadLibrary.shared.remove([saved.id])
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        #if os(tvOS)
        // Room for the focused glass row, which grows toward the trailing edge.
        .padding(.trailing, 16).padding(.vertical, 6)
        #endif
        .tvFocusSection()
        .animation(.appSmooth(duration: 0.4), value: showsStills)
    }
    /// Mac and iPad, under the banner: TMDB hasn't answered yet. Short-drama-length lists stay chips (see episodeList).
    private var tmdbPending: Bool {
        #if os(tvOS)
        false
        #else
        isWide && (tmdb.phase == .looking || (tmdb.phase == .idle && TMDBLookup.applies(to: client.site)))
        #endif
    }
    private var episodeMin: CGFloat {
        #if os(tvOS)
        170
        #else
        // Room for 第 10 集 / 第01集 without an ellipsis.
        100
        #endif
    }
    private func download(_ episode: Episode) -> DownloadItem? {
        DownloadLibrary.shared.item(for: DownloadSource(site: client.site, videoID: video.id, episode: episode))
    }
    private func play(_ episode: Episode, mode: PlaybackResumeMode = .resume) async {
        guard !busy else { return }
        selectedEpisode = episode
        let sourceStarted = Date(), startupRequest = UUID()
        Diagnostics.shared.record(.info, "player.startup", "entry=detail request=\(startupRequest) stage=resolve-begin")
        defer { Diagnostics.shared.record(.info, "player.startup", "entry=detail request=\(startupRequest) stage=resolve-end elapsed=\(Date().timeIntervalSince(sourceStarted)) cancelled=\(Task.isCancelled)") }
        // Normal play retains this episode's own progress; an explicit beginning overrides it with zero.
        let selection = DetailPlaybackSelection(episodes: detail?.episodes ?? [episode], activeFlag: episode.flag,
                                                selectedEpisode: episode, history: watchHistories)
        let resume = selection.position(for: mode)
        // A downloaded episode plays from the device: no link to fetch, and it works offline.
        if let saved = download(episode), saved.status == .completed {
            store.playing = store.catalogChannel(DownloadLibrary.shared.channel(for: saved), video: currentVideo(),
                                                 episode: episode, client: client, resumePosition: resume)
            return
        }
        // A drive line goes to the plugin even without an app sign-in: the plugin asks for its account itself, with
        // its own code, which the app shows (PluginSignIn, or the bundle's sign-in below).
        busy = true; loadingEpisode = episode.id; loadingMode = mode
        withAnimation(.appSmooth(duration: 0.2)) { playbackIssue = nil }
        defer { busy = false; loadingEpisode = nil; loadingMode = nil }
        do {
            let plan = try await client.preparePlayback(episode)
            try Task.checkCancellation()
            guard let choice = plan.choices.first else { throw URLError(.cannotParseResponse) }
            let playback = store.subscription.map { client.applying($0) } ?? client
            let resolved = try await playback.resolvePlayback(plan, choice: choice)
            try Task.checkCancellation()
            Diagnostics.shared.record(.info, "player.startup", "entry=detail request=\(startupRequest) stage=source-ready elapsed=\(Date().timeIntervalSince(sourceStarted))")
            store.playing = store.catalogChannel(resolved, video: currentVideo(), episode: episode, client: playback, resumePosition: resume)
        } catch { fail(episode, error, mode: mode) }
    }
    private func retryAfterSignIn() {
        if let issue = playbackIssue { startRequest { await play(issue.episode, mode: issue.mode) } }
    }
    private func fail(_ episode: Episode, _ error: Error, mode: PlaybackResumeMode = .resume) {
        guard !Task.isCancelled, !(error is CancellationError) else { return }
        // A CatPawOpen bundle without a drive's sign-in sends the viewer to its config center ("请先去配置中心登录夸克"):
        // its own sign-in for that drive runs here instead.
        let provider = client.site.isCatPawOpen ? CatPawSignIn.provider(for: error.localizedDescription) : nil
        // A drive that needs signing in is expected, not a failure to report.
        if provider == nil && !(error is CloudDriveLoginRequired) {
            Diagnostics.shared.failure("catalog", "play \(client.reportContext) flag=\(episode.flag)", error)
        }
        withAnimation(.appSmooth(duration: 0.25)) {
            if let provider {
                let message = provider == "ucToken"
                    // Signed in, but the bundle wants a token its own code gives; signing in again would change nothing.
                    ? L10n.text("You're signed in to UC, but this source plays UC accounts without premium through UC's TV app, which needs a token of its own. Get it once with the UC Browser app, or choose another line.")
                    : L10n.text("This source needs your %@ account for this line. Sign in with its code, and the episode plays.", CatPawSignIn.driveName(provider))
                playbackIssue = PlaybackIssue(episode: episode, message: message, signIn: provider, mode: mode)
            } else {
                // Other plugins say in their own words what their sign-in needs.
                playbackIssue = PlaybackIssue(episode: episode, message: error.localizedDescription, mode: mode)
            }
        }
    }

    /// Where the viewer stopped last time, for Continue.
    private var watchHistories: [PlaybackHistoryEntry] {
        let origin = client.site.origin(or: client.origin)
        let identifiers = Set([video.id, detail?.id].compactMap { $0 })
        var entries = store.visibleHistory.filter {
            $0.context.matchesVideo(origin: origin, sourceKey: client.site.sourceKey, videoIDs: identifiers)
        }
        if let resume, store.historyClient(resume) != nil,
           resume.context.matchesVideo(origin: origin, sourceKey: client.site.sourceKey, videoIDs: identifiers),
           !entries.contains(where: { $0.id == resume.id }) { entries.append(resume) }
        return entries
    }
    private var watchHistory: PlaybackHistoryEntry? {
        watchHistories.first
    }
    /// The line of the episode playing, else of the one watched last, while the details still have it: the page opens
    /// on that line so the episode shows in its list, not on the first line (#362).
    private var watchedFlag: String? {
        guard let episodes = detail?.episodes else { return nil }
        let context = watchHistory?.context
        return context?.episode(in: episodes)?.flag
    }

}

#if os(iOS)
/// Kept for history callers; detail presentation no longer owns a player.
enum WatchPage {
    @MainActor static func applies(_ horizontal: UserInterfaceSizeClass?, _ vertical: UserInterfaceSizeClass?) -> Bool { false }
}
#endif

extension PlaybackHistoryEntry {
    /// The watched title as a list card, to open its page with.
    var listVideo: Video {
        Video(id: context.videoID, name: context.videoName, poster: context.poster, posterHeaders: context.posterHeaders ?? [:], year: context.year)
    }
}

private struct PlaybackIssue {
    let episode: Episode
    let message: String
    /// A sign-in the source's CatPawOpen bundle runs itself (`CatPawSignIn.provider(for:)`).
    var signIn: String? = nil
    var mode: PlaybackResumeMode = .resume
}

private struct BundleSignIn: Identifiable {
    let provider: String
    var id: String { provider }
}

/// Cloud drives a line plays from, to start a video on a line that can play now.
private enum CloudDrive {
    /// Xunlei's sign-in is only for CatPawOpen bundles, which say when it is missing; other sources play their Xunlei
    /// lines without it, so those lines are never held back for it.
    case quark, uc, xunlei
    /// FTY names its lines after drive nicknames: 夸父 is Quark, 优汐 is UC.
    init?(flag: String) {
        let text = flag.lowercased()
        if text.contains("夸克") || text.contains("夸父") || text.contains("quark") { self = .quark }
        else if text.hasPrefix("uc") || text.contains("uc网盘") || text.contains("优汐") { self = .uc }
        else if text.contains("迅雷") || text.contains("xunlei") { self = .xunlei }
        else { return nil }
    }
    /// Lines from drives that sign in through the plugin's own QR code (FTY's 嘟嘟 is Baidu, 阿狸 is
    /// Aliyun). They ask for a scan the first time, so they never start a title on their own.
    static func withoutSignIn(_ flag: String) -> Bool {
        let text = flag.lowercased()
        return ["嘟嘟", "百度", "度盘", "baidu", "阿狸", "阿里", "aliyun"].contains { text.contains($0) }
    }
    /// The first line that can play now: not from a drive without a sign-in, nor one without the app's sign-in.
    /// Those lines still play when chosen: their plugin asks for the account with its own code.
    static func preferredFlag(_ flags: [String]) -> String? {
        let accounts = (try? CloudDriveAccounts.load()) ?? CloudDriveAccounts()
        return flags.first { flag in
            if withoutSignIn(flag) { return false }
            guard let drive = CloudDrive(flag: flag), drive != .xunlei else { return true }
            let cookie = drive == .quark ? accounts.quarkCookie : accounts.ucCookie
            return !cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

/// Episode names often lead with a size tag ("[1.18GB] S01E41.mkv"); show it as trailing detail.
struct EpisodeRow: View {
    let name: String
    /// The episode's short label (第1集), shown in place of the name; the size tag stays as detail.
    var label: String? = nil
    /// Resolution and size from the file name (4K · 5.2G), shown in place of the size tag.
    var file: String? = nil
    let loading: Bool
    var download: DownloadItem? = nil
    let action: () -> Void
    @State private var hovering = false
    static func split(_ name: String) -> (title: String, detail: String?) {
        if let match = name.firstMatch(of: /^\s*\[([^\]]+)\]\s*(.+)$/) { return (String(match.2), String(match.1)) }
        return (name, nil)
    }
    static func title(_ name: String) -> String { split(name).title }
    /// Row type and height per platform: a Mac list size is unreadable from a sofa.
    private static var metrics: (text: CGFloat, icon: CGFloat, height: CGFloat, inset: CGFloat) {
        #if os(tvOS)
        (28, 18, 42, 0) // GlassRowStyle adds its own padding and focus glass
        #elseif os(iOS)
        (15, 11, 44, 14)
        #else
        (13, 10, 36, 12)
        #endif
    }
    private var parts: (title: String, detail: String?) {
        let parts = Self.split(name)
        return (label ?? parts.title, file ?? parts.detail)
    }
    var body: some View {
        WithPerceptionTracking {
            let parts = parts
            let button = Button(action: action) {
                HStack(spacing: 10) {
                    ZStack {
                        if loading { ProgressView().controlSize(.mini) }
                        else { Image(systemName: "play.fill").font(.system(size: Self.metrics.icon)).foregroundStyle(hovering ? .primary : .tertiary) }
                    }
                    .frame(width: Self.metrics.icon + 6)
                    Text(parts.title).font(.system(size: Self.metrics.text, weight: loading ? .semibold : .medium))
                        .lineLimit(2).multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    if let detail = parts.detail {
                        Text(detail).font(.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let download { DownloadState(item: download) }
                }
                .padding(.horizontal, Self.metrics.inset).frame(minHeight: Self.metrics.height)
                .frame(maxWidth: .infinity, alignment: .leading)
                #if !os(tvOS)
                .background(Color.primary.opacity(loading ? 0.12 : (hovering ? 0.08 : 0.04)),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                #endif
                .contentShape(Rectangle())
            }
            .accessibilityLabel(name)
            #if os(tvOS)
            button.glassRow()
            #else
            button.buttonStyle(.plain)
                .onHover { hovering = $0 }
                .animation(.appSmooth(duration: 0.15), value: hovering)
            #endif
        }
    }
}

private struct DownloadLabelStyle: LabelStyle {
    let iconOnly: Bool
    func makeBody(configuration: Configuration) -> some View {
        WithPerceptionTracking {
            if iconOnly { configuration.icon } else { HStack(spacing: 6) { configuration.icon; configuration.title } }
        }
    }
}

/// Gives its one subview at least `minHeight`, even in a scroll view, where `frame(minHeight:)`
/// leaves the content at its ideal height and spacers inside it never grow.
private struct MinHeightLayout: SwiftUI.Layout {
    var minHeight: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let size = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: size.width, height: max(size.height, minHeight))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
