import SwiftUI
import Perception
import TVCore

#if os(iOS)
import UIKit
private struct LocalDockKey: EnvironmentKey { static let defaultValue = false }
private struct LocalDockInsetKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
private struct LocalDockTopKey: EnvironmentKey { static let defaultValue: CGFloat? = nil }
private struct LocalHTMLDockClearanceKey: EnvironmentKey { static let defaultValue: CGFloat = 68 }
private struct LocalDockVisibleKey: EnvironmentKey { static let defaultValue = true }
private struct LocalHTMLDockHiddenKey: EnvironmentKey { static let defaultValue = Binding.constant(false) }
private struct LocalDockScrollEnabledKey: EnvironmentKey { static let defaultValue = false }
private struct LocalDockActivityKey: EnvironmentKey { static let defaultValue: (@MainActor @Sendable (UUID, Bool) -> Void)? = nil }
private struct LocalPageActiveKey: EnvironmentKey { static let defaultValue = true }
private struct LocalHomeSourcePanelKey: EnvironmentKey { static let defaultValue: (@MainActor @Sendable () -> Void)? = nil }
extension EnvironmentValues {
    var localDockScrollEnabled: Bool {
        get { self[LocalDockScrollEnabledKey.self] }
        set { self[LocalDockScrollEnabledKey.self] = newValue }
    }
    var localDockActivity: (@MainActor @Sendable (UUID, Bool) -> Void)? {
        get { self[LocalDockActivityKey.self] }
        set { self[LocalDockActivityKey.self] = newValue }
    }
    var localDockVisible: Bool {
        get { self[LocalDockVisibleKey.self] }
        set { self[LocalDockVisibleKey.self] = newValue }
    }
    var localHTMLDockHidden: Binding<Bool> {
        get { self[LocalHTMLDockHiddenKey.self] }
        set { self[LocalHTMLDockHiddenKey.self] = newValue }
    }
    var openLocalHomeSources: (@MainActor @Sendable () -> Void)? {
        get { self[LocalHomeSourcePanelKey.self] }
        set { self[LocalHomeSourcePanelKey.self] = newValue }
    }
    var localDockInset: CGFloat {
        get { self[LocalDockInsetKey.self] }
        set { self[LocalDockInsetKey.self] = newValue }
    }
    /// The reserved dock's top in global coordinates; pushed and full-bleed
    /// pages can have different safe-area origins but share this boundary.
    var localDockTop: CGFloat? {
        get { self[LocalDockTopKey.self] }
        set { self[LocalDockTopKey.self] = newValue }
    }
    /// Full dock clearance, including the music strip, even while the dock is hidden.
    var localHTMLDockClearance: CGFloat {
        get { self[LocalHTMLDockClearanceKey.self] }
        set { self[LocalHTMLDockClearanceKey.self] = newValue }
    }
    var isLocalPageActive: Bool {
        get { self[LocalPageActiveKey.self] }
        set { self[LocalPageActiveKey.self] = newValue }
    }
    var usesLocalDock: Bool {
        get { self[LocalDockKey.self] }
        set { self[LocalDockKey.self] = newValue }
    }
}

/// A stable stack per visited page. Switching tabs never destroys an in-flight detail or the music queue.
struct LocalAppNavigation: View {
    @Environment(Store.self) private var store
    @State private var visited: Set<AppSection> = [.home]
    @State private var sourcePanel: LocalHomeSourceKind?
    @State private var sourcePanelBlocksInput = false
    @State private var pickedSites: [AppSection: Site] = [:]
    @State private var metadataRevision = TMDBServiceSettings.identity
    @State private var keyboardVisible = false
    @State private var dockHiddenByScroll = false
    @State private var activeScrollObservers: Set<UUID> = []
    @State private var htmlDockHidden = false
    @State private var restoredDestination = false
    @State private var dockConfiguration = LocalDockConfiguration.load()
    @State private var preparedHomeSource = false
    @State private var homeRevision = 0
    @State private var homeResetID: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(LocalHTMLHomeStore.key) private var htmlHomeData = Data()
    let page: (AppSection) -> AnyView
    /// The dock's buttons as arranged in Settings > Dock 按钮 (order + hidden).
    private var dockButtons: [LocalDockButton] { dockConfiguration.visible }
    private var current: AppSection {
        switch store.section {
        case .discover, .live: .home
        case .more: .settings
        default: store.section
        }
    }
    private var htmlHomeSelected: Bool {
        _ = htmlHomeData
        return current == .home && LocalHTMLHomeStore.load().active != nil
    }
    private var dockVisible: Bool { !keyboardVisible && !dockHiddenByScroll && !(htmlHomeSelected && htmlDockHidden) }

    var body: some View {
        WithPerceptionTracking {
            GeometryReader { viewport in
                WithPerceptionTracking {
                    ZStack {
                        ForEach(Array(visited).sorted { $0.rawValue < $1.rawValue }) { section in
                            WithPerceptionTracking {
                                RouteStack(reset: section == .home ? homeResetID : nil) {
                                    WithPerceptionTracking {
                                        if section == .sites || section == .python {
                                            sourcePage(section)
                                        } else if section == .home {
                                            if preparedHomeSource { LocalHTMLHomeContent { page(section) } }
                                            else { Color.clear }
                                        } else { page(section) }
                                    }
                                }
                                .frame(width: viewport.size.width, height: viewport.size.height)
                                .environment(\.isLocalPageActive, current == section && !sourcePanelBlocksInput)
                                .environment(\.localDockInset, keyboardVisible ? 0 : dockInset)
                                .id(stackIdentity(section))
                                .opacity(current == section ? 1 : 0)
                                .disabled(current != section || sourcePanelBlocksInput)
                                .allowsHitTesting(current == section && !sourcePanelBlocksInput)
                                .accessibilityHidden(current != section || sourcePanelBlocksInput)
                                .zIndex(current == section ? 1 : 0)
                            }
                        }
                    }
                    .environment(\.localDockTop, keyboardVisible ? nil : viewport.frame(in: .global).maxY - dockInset)
                    .frame(width: viewport.size.width, height: viewport.size.height)
                    .overlay(alignment: .bottom) {
                        WithPerceptionTracking {
                            if dockVisible {
                                VStack(spacing: LocalDockLayout.musicSpacing) {
                                    if store.music.showsStrip(videoPlaying: store.playing != nil) {
                                        MusicMiniPlayer().frame(height: LocalDockLayout.musicHeight)
                                            .localGlassSurface(cornerRadius: 28)
                                    }
                                    dock(availableWidth: viewport.size.width - 2 * LocalDockLayout.horizontalPadding)
                                }
                                .padding(.horizontal, LocalDockLayout.horizontalPadding)
                                .padding(.top, LocalDockLayout.topPadding).padding(.bottom, LocalDockLayout.bottomPadding)
                                .localDockHitRegions(frames: LocalDockLayout.touchFrames(containerWidth: viewport.size.width,
                                    showsMusic: store.music.showsStrip(videoPlaying: store.playing != nil), buttonCount: dockButtons.count))
                                .disabled(sourcePanelBlocksInput)
                                .allowsHitTesting(!sourcePanelBlocksInput)
                                // Fade only: sliding the dock in moved the painted bar
                                // away from its hit region while it travelled.
                                .transition(.opacity)
                            }
                        }
                    }
                }
            }
            .environment(\.usesLocalDock, true)
            .environment(\.localDockVisible, dockVisible)
            .environment(\.localHTMLDockClearance, dockInset)
            .environment(\.localHTMLDockHidden, $htmlDockHidden)
            .environment(\.localDockScrollEnabled, !keyboardVisible && !sourcePanelBlocksInput)
            .environment(\.localDockActivity, { id, active in scrolled(id: id, active: active) })
            .environment(\.openLocalHomeSources, { openHomeSources() })
            .onAppear { prepareHomeDestination(); visited.insert(current); revealDock() }
            .task(id: sourceRevision) { prepareHomeDestination(); synchronizeSources() }
            .appOnChange(of: store.section) { _, _ in
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                visited.insert(current)
                revealDock()
            }
            .onReceive(NotificationCenter.default.publisher(for: LocalDockConfiguration.changed)) { _ in
                dockConfiguration = LocalDockConfiguration.load()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
            // Keep the dock out of the keyboard's shrinking safe area until dismissal finishes.
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in keyboardVisible = false }
            .onReceive(NotificationCenter.default.publisher(for: TMDBServiceSettings.changed)) { _ in
                metadataRevision = TMDBServiceSettings.identity
            }
            .localGlassDialog(isPresented: Binding(get: { sourcePanel != nil }, set: { if !$0 { sourcePanel = nil } }), title: "",
                              maxWidth: 440, maxHeight: 700, layout: .centered,
                              onDismiss: { sourcePanelBlocksInput = false }) {
                RouteStack {
                    WithPerceptionTracking {
                        LocalHomeSourcePanel(initialKind: sourcePanel ?? .sites, pickedSites: pickedSites, homeSelected: current == .home,
                                             pick: select, home: selectHome)
                    }
                }
                .environment(store)
                .toolbarBackground(.hidden, for: .navigationBar)
            }
            .onDisappear { revealDock() }
            .fullScreenCover(isPresented: Binding(get: { store.music.presentsPlayer }, set: { store.music.presentsPlayer = $0 })) {
                MusicNowPlayingScreen().environment(store)
            }
        }
    }

    private func stackIdentity(_ section: AppSection) -> String {
        guard section == .sites || section == .python, let site = pickedSites[section] else {
            return section == .home || section == .discover ? section.rawValue + "|" + metadataRevision + "|\(homeRevision)" : section.rawValue
        }
        // Only the live stack uses this process-local hash. Persisted identity stays origin + original key.
        return section.rawValue + "|" + site.key + "|\(site.hashValue)"
    }

    @ViewBuilder private func sourcePage(_ section: AppSection) -> some View {
        if let site = pickedSites[section], let config = store.subscription {
            SiteView(site: site, origin: config.origin, jarURL: config.spiderURL)
                .id(site.key + "|" + site.origin(or: config.origin).absoluteString)
        } else {
            VStack(spacing: 18) {
                Image(systemName: section.icon).font(.system(size: 44)).foregroundStyle(.secondary)
                Text(section == .python ? "选择 python 来源" : "选择站点").font(.title2)
                Button("选择来源") { presentSources(section == .python ? .python : .sites) }.buttonStyle(.borderedProminent)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).screenBackdrop()
        }
    }

    private var sourceRevision: String {
        let readiness = store.subscriptions.map { entry in
            "\(entry.address)|\(entry.enabled)|\(store.documents[entry.address] != nil)|\(store.subscriptionErrors[entry.address] != nil)"
        }.joined(separator: "\n")
        guard let config = store.subscription else { return "empty|\(store.importing)|" + readiness }
        return config.importedAt.description + "|\(store.importing)|" + readiness + "|" + config.sites.map {
            $0.key + "|" + $0.origin(or: config.origin).absoluteString
        }.joined(separator: "\n")
    }

    private func prepareHomeDestination() {
        guard !preparedHomeSource else { return }
        var home = LocalHTMLHomeStore.load()
        let previous = home
        let preference = LocalHomeDestination(rawValue: UserDefaults.standard.string(forKey: LocalHomeDestination.key) ?? "") ?? .home
        home.restoreStartup(preference)
        if home != previous {
            do { try home.save() }
            catch { Diagnostics.shared.record(.warning, "home", "startup home could not be saved") }
        }
        preparedHomeSource = true
    }

    private func selection(for site: Site, origin: URL) -> LocalHomeSourceSelection {
        LocalHomeSourceSelection(origin: site.origin(or: origin).absoluteString, sourceKey: site.sourceKey, python: store.localSourceGroup(for: site) == .python)
    }

    private func synchronizeSources() {
        guard !store.importing else { return }
        let defaults = UserDefaults.standard
        let sites = store.subscription.map { config in store.orderedSites(config).filter { !$0.isBuiltIn } } ?? []
        if let config = store.subscription {
            for section in [AppSection.sites, .python] {
                let remembered = pickedSites[section].map { selection(for: $0, origin: config.origin) }
                    ?? LocalHomeSourceSelection.saved(python: section == .python, defaults: defaults)
                pickedSites[section] = sites.first { selection(for: $0, origin: config.origin) == remembered }
            }
        } else { pickedSites = [:] }
        guard !restoredDestination else { return }
        let preference = defaults.string(forKey: "local.home.defaultDestination") ?? "home"
        guard current == .home, preference == "lastSite" || preference == "lastPython",
              LocalHomeSourceSelection.saved(python: preference == "lastPython", defaults: defaults) != nil else {
            restoredDestination = true
            return
        }
        let desired = store.subscription.flatMap { config in
            LocalHomeSourceSelection.destination(preference, available: sites.map { selection(for: $0, origin: config.origin) }, defaults: defaults)
        }
        // Another category can already have a cached document when the target's restore has not begun.
        // Each category has one enabled owner; failed, disabled and deleted entries settle on home.
        let targetGroup: LocalSourceGroup = preference == "lastPython" ? .python : .subscription
        if desired == nil, store.subscriptions.contains(where: { entry in
            entry.enabled && (store.localSourceGroups[entry.address] ?? .subscription) == targetGroup
                && store.documents[entry.address] == nil && store.subscriptionErrors[entry.address] == nil
        }) { return }
        restoredDestination = true
        guard let config = store.subscription, let desired,
              let site = sites.first(where: { selection(for: $0, origin: config.origin) == desired }) else { return }
        select(site)
    }

    private func select(_ site: Site) {
        store.cancelResume()
        let section: AppSection = store.localSourceGroup(for: site) == .python ? .python : .sites
        pickedSites[section] = site
        if let config = store.subscription { selection(for: site, origin: config.origin).save() }
        UserDefaults.standard.set(section == .python ? "python" : "sites", forKey: LocalHomeDestination.lastKindKey)
        store.section = section
        visited.insert(section)
        sourcePanel = nil
    }

    private func selectHome() {
        store.cancelResume()
        // HTML selection has already been saved by the selector. Its source.id
        // controls actual source changes; returning to it preserves web history.
        // Explicit native Home still resets a pushed native detail stack.
        if LocalHTMLHomeStore.load().active == nil { homeRevision += 1 }
        homeResetID = UUID()
        store.section = .home
        visited.insert(.home)
        sourcePanel = nil
    }

    /// Home goes straight to the site used last, instead of popping the source
    /// panel. Only when no last site resolves (first run, or the site is gone
    /// from the subscription) does it fall back to the panel. Switching sites
    /// still goes through the panel, via the site name at the top of a site page.
    private func openLastSite() {
        let defaults = UserDefaults.standard
        let kind = defaults.string(forKey: LocalHomeDestination.lastKindKey)
        if kind == "html", LocalHTMLHomeStore.load().active != nil {
            selectHome()
            return
        }
        if let config = store.subscription {
            let sites = store.orderedSites(config).filter { !$0.isBuiltIn }
            let available = sites.map { selection(for: $0, origin: config.origin) }
            // The remembered kind first, then the other kind, so a deleted last
            // site still lands on the other kind's last site instead of the panel.
            for preference in kind == "python" ? ["lastPython", "lastSite"] : ["lastSite", "lastPython"] {
                if let desired = LocalHomeSourceSelection.destination(preference, available: available, defaults: defaults),
                   let site = sites.first(where: { selection(for: $0, origin: config.origin) == desired }) {
                    select(site)
                    return
                }
            }
        }
        openHomeSources()
    }

    private func openHomeSources() {
        restoredDestination = true
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        presentSources(current == .python ? .python : htmlHomeSelected ? .html : .sites)
    }

    private func presentSources(_ kind: LocalHomeSourceKind) {
        store.cancelResume()
        // Remain blocked after a selection sets sourcePanel to nil. UIKit's
        // dismissal completion owns re-enabling the underlying retained page.
        sourcePanelBlocksInput = true
        sourcePanel = kind
    }

    private var dockInset: CGFloat {
        LocalDockLayout.inset(showsMusic: store.music.showsStrip(videoPlaying: store.playing != nil))
    }

    private func scrolled(id: UUID, active: Bool) {
        if active { activeScrollObservers.insert(id) } else { activeScrollObservers.remove(id) }
        let hidden = !activeScrollObservers.isEmpty
        guard dockHiddenByScroll != hidden else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: hidden ? 0.16 : 0.18)) { dockHiddenByScroll = hidden }
    }

    private func revealDock() {
        activeScrollObservers.removeAll()
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { dockHiddenByScroll = false }
    }

    private func dock(availableWidth: CGFloat) -> some View {
        // Sam: one capsule for every button (was two), so the whole bar is a
        // single hit region and nothing falls through the gap between groups.
        // The buttons shown, and their order, come from Settings > Dock 按钮.
        let buttons = dockButtons
        let metrics = LocalDockLayout.metrics(availableWidth: availableWidth, buttonCount: buttons.count)
        return HStack(spacing: metrics.buttonSpacing) {
            ForEach(buttons) { button in WithPerceptionTracking { dockButtonView(button, width: metrics.buttonWidth) } }
        }
        .padding(.horizontal, metrics.capsulePadding).padding(.vertical, LocalDockLayout.groupPadding)
        .localGlassSurface(cornerRadius: LocalDockLayout.dockHeight / 2)
        .frame(maxWidth: .infinity, alignment: .center).frame(height: LocalDockLayout.dockHeight)
    }

    @ViewBuilder private func dockButtonView(_ button: LocalDockButton, width: CGFloat) -> some View {
        switch button {
        case .search: searchButton(width: width)
        case .push: pushButton(width: width)
        default: dockButton(button.section, width: width)
        }
    }

    private func dockButton(_ entry: AppSection, width: CGFloat) -> some View {
        let selected = current == entry || entry == .home && (current == .sites || current == .python)
        let color = dockColor(entry)
        return Button {
            restoredDestination = true
            if entry == .home { openLastSite() }
            else { selectSection(entry) }
        } label: {
            Image(systemName: entry == .home ? "house.fill" : entry == .settings ? "gearshape.fill" : entry.icon)
            .font(.system(size: 28, weight: .semibold))
            .frame(width: width, height: LocalDockLayout.controlHeight)
            .foregroundStyle(selected ? color : .primary)
            .background(selected ? color.opacity(0.16) : .clear, in: Capsule())
            .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(entry.title)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("local.dock." + (entry == .home ? "home" : entry == .favorites ? "favorites" : entry == .history ? "history" : entry == .music ? "music" : "settings"))
    }

    private func dockColor(_ entry: AppSection) -> Color {
        switch entry {
        case .home: Color(light: Color(red: 0.04, green: 0.42, blue: 0.82), dark: Brand.cyan)
        case .favorites: Color(light: Color(red: 0.84, green: 0.20, blue: 0.28), dark: Color(red: 1.0, green: 0.45, blue: 0.50))
        case .history: Color(light: Color(red: 0.68, green: 0.36, blue: 0.02), dark: Brand.amber)
        case .music: Color(light: Color(red: 0.78, green: 0.18, blue: 0.34), dark: Brand.rose)
        case .settings: Color(light: Color(red: 0.36, green: 0.29, blue: 0.80), dark: Brand.indigo)
        default: Color(light: Color(red: 0.04, green: 0.46, blue: 0.44), dark: Brand.teal)
        }
    }

    private func searchButton(width: CGFloat) -> some View {
        let selected = current == .search
        let color = dockColor(.search)
        return Button {
            selectSection(.search)
        } label: {
            Image(systemName: "magnifyingglass").font(.system(size: 28, weight: .semibold))
                .frame(width: width, height: LocalDockLayout.controlHeight)
                .foregroundStyle(selected ? color : .primary)
                .background(selected ? color.opacity(0.16) : .clear, in: Capsule())
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("搜索").accessibilityIdentifier("local.search")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func pushButton(width: CGFloat) -> some View {
        let selected = current == .push
        let color = dockColor(.push)
        return Button {
            selectSection(.push)
        } label: {
            Image(systemName: selected ? "paperplane.fill" : "paperplane")
                .font(.system(size: 28, weight: .semibold)).frame(width: width, height: LocalDockLayout.controlHeight)
                .foregroundStyle(selected ? color : .primary)
                .background(selected ? color.opacity(0.16) : .clear, in: Capsule())
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("推送").accessibilityIdentifier("local.push")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func selectSection(_ section: AppSection) {
        restoredDestination = true
        guard current != section else { return }
        store.cancelResume()
        visited.insert(section)
        store.section = section
    }
}

struct LocalContinueWatching: View {
    @Environment(Store.self) private var store
    @AppStorage("local.home.continueWatching") private var enabled = true
    var body: some View {
        WithPerceptionTracking {
            if enabled, !store.visibleHistory.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Button { store.cancelResume(); store.section = .history } label: {
                        HStack {
                            Text("继续观看").font(.title3.weight(.bold))
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                        }.contentShape(Rectangle()).frame(minHeight: 44)
                    }.buttonStyle(.plain).padding(.horizontal, 17)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(store.visibleHistory.prefix(12)) { entry in HistoryCard(entry: entry) }
                        }.padding(.horizontal, 17)
                    }
                }.accessibilityIdentifier("home.continueWatching")
            }
        }
    }
}
#endif
