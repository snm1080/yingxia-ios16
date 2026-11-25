import SwiftUI
import Perception
import TVCore

#if os(iOS)
enum LocalHomeSourceKind: String, CaseIterable, Identifiable {
    case sites, python, html
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sites: "站点"
        case .python: "python"
        case .html: "html"
        }
    }
}

/// All homepage destinations live in the same compact dock selector.
struct LocalHomeSourcePanel: View {
    @Environment(Store.self) private var store
    @State private var keyboardVisible = false
    @AppStorage(LocalHTMLHomeStore.key) private var htmlHomeData = Data()
    @State private var kind: LocalHomeSourceKind
    @State private var websiteShown = false
    @State private var htmlFailure = ""
    @State private var htmlQuery = ""
    let pickedSites: [AppSection: Site]
    let homeSelected: Bool
    let pick: (Site) -> Void
    let home: () -> Void

    init(initialKind: LocalHomeSourceKind, pickedSites: [AppSection: Site], homeSelected: Bool, pick: @escaping (Site) -> Void, home: @escaping () -> Void) {
        _kind = State(initialValue: initialKind)
        self.pickedSites = pickedSites
        self.homeSelected = homeSelected
        self.pick = pick
        self.home = home
    }

    private var sourceGroup: LocalSourceGroup { kind == .python ? .python : .subscription }
    private var activeSubscription: SubscriptionEntry? { store.managedSubscriptions(in: sourceGroup).first(where: \.enabled) }
    private var htmlHomes: LocalHTMLHomeStore { _ = htmlHomeData; return .load() }
    private var websiteSite: Site? {
        guard let activeSubscription, let document = store.documents[activeSubscription.address] else { return nil }
        return document.sites.first { $0.raw["catPawOpen"] != nil }
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                if !keyboardVisible {
                    kindPicker
                    header
                }
                if kind == .html {
                    htmlSources
                } else {
                    let python = kind == .python
                    let candidates = store.subscription.map { config in
                        store.homeSourceSites(config).filter { !$0.isBuiltIn && (store.localSourceGroup(for: $0) == .python) == python }
                    } ?? []
                    SitesView(pick: pick, pickable: candidates, picked: pickedSites[python ? .python : .sites]?.key,
                              panelKind: kind.rawValue, builtinHome: python ? nil : { chooseHome("builtin") },
                              homeSelected: homeSelected && htmlHomes.active == nil)
                        .id(kind)
                }
            }
            .localGlassBackdrop()
            // The whole panel reads two Dynamic Type steps larger (build 38: was one); the tab row and the
            // subscription row use the same subheadline as the site names, so they
            // stay exactly as large as the names below them at any size.
            .dynamicTypeSize(.xxxLarge)
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in keyboardVisible = false }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $websiteShown) {
                WithPerceptionTracking {
                    if let entry = activeSubscription, let document = store.documents[entry.address], let site = websiteSite {
                        ConfigCenterView { await CatPawOpen.configCenter(site: site, origin: document.origin, jarURL: document.spiderURL) }
                    } else {
                        NavigationStack {
                            AppContentUnavailableView("当前订阅没有 website", systemImage: "globe", description: Text("此入口用于当前订阅提供的配置中心。"))
                                .navigationTitle("website").navigationBarTitleDisplayMode(.inline)
                                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭") { websiteShown = false } } }
                        }
                    }
                }
            }
        }
    }

    /// A segmented row drawn by hand: the system segmented control keeps its own
    /// small fixed font, while these labels take the site names' subheadline.
    private var kindPicker: some View {
        HStack(spacing: 0) {
            ForEach(LocalHomeSourceKind.allCases) { option in
                Button { kind = option } label: {
                    Text(option.title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background {
                            if kind == option {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.primary.opacity(0.13))
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(kind == option ? .isSelected : [])
                .accessibilityIdentifier("home.source.kind." + option.rawValue)
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 14).padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("来源类别")
        .accessibilityIdentifier("home.source.kind")
    }

    private var header: some View {
        WithPerceptionTracking {
            HStack(spacing: 0) {
                if kind == .sites {
                    Menu {
                        ForEach(store.managedSubscriptions(in: sourceGroup)) { entry in
                            Button {
                                Task { await store.setSubscription(entry, enabled: true) }
                            } label: {
                                if entry.enabled { Label(entry.title, systemImage: "checkmark") }
                                else { Text(entry.title) }
                            }
                        }
                        if store.managedSubscriptions(in: sourceGroup).isEmpty { Text("尚未导入订阅") }
                    } label: {
                        HStack(spacing: 6) {
                            Text(activeSubscription?.title ?? "选择订阅")
                                .font(.system(size: 17, weight: .semibold)).lineLimit(2)
                            Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                    }
                    .disabled(store.importing)
                    .accessibilityLabel("切换订阅，" + (activeSubscription?.title ?? "尚未选择"))
                    .accessibilityIdentifier("home.source.subscription")
                } else {
                    Spacer(minLength: 0).frame(minHeight: 44)
                }
                if kind == .sites && websiteSite != nil {
                    Button { websiteShown = true } label: { SettingsIcon(symbol: "globe", tint: Brand.teal).frame(width: 44, height: 44).contentShape(Rectangle()) }
                        .accessibilityLabel("website").accessibilityIdentifier("home.source.website")
                }
                RouteLink {
                    if kind == .html {
                        ScrollView { LocalHTMLHomeSettingsSection().padding(16) }
                            .navigationTitle("HTML 首页").navigationBarTitleDisplayMode(.inline)
                            .toolbar(.visible, for: .navigationBar)
                            .localGlassBackdrop()
                    } else {
                        LocalSourceSettingsView(kind: sourceGroup)
                            .toolbar(.visible, for: .navigationBar)
                    }
                } label: {
                    SettingsIcon(symbol: "slider.horizontal.3", tint: Brand.indigo).frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel(kind == .html ? "HTML 首页设置" : kind == .python ? "python 设置" : "订阅设置")
                .accessibilityIdentifier("home.source.settings." + (kind == .html ? "html" : kind == .python ? "python" : "subscription"))
            }
            .buttonStyle(.plain).font(.system(size: 19, weight: .medium))
            .padding(.horizontal, 16).padding(.bottom, 4)
        }
    }

    private var htmlSources: some View {
        let query = htmlQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = htmlHomes.sources.filter { query.isEmpty || $0.name.localizedStandardContains(query) || ($0.address?.localizedStandardContains(query) ?? false) }
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("筛选 HTML 首页名称或地址", text: $htmlQuery)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.search).accessibilityIdentifier("home.source.html.search")
                if !htmlQuery.isEmpty {
                    Button { htmlQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("清除 HTML 首页搜索")
                }
            }
            .padding(.leading, 12).frame(minHeight: 44).localGlassInputSurface()
            .padding(.horizontal, 16).padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(matches) { source in
                            htmlRow(source.name, id: source.id, symbol: source.isFile ? "doc.text" : "globe")
                        }
                    }
                    if htmlHomes.sources.isEmpty {
                        Text("添加在线地址或导入 HTML 文件后，可在这里切换。")
                            .font(.system(size: 15)).foregroundStyle(.secondary).padding(.vertical, 12)
                    } else if matches.isEmpty {
                        Text("没有匹配的 HTML 首页").font(.system(size: 15)).foregroundStyle(.secondary).padding(.vertical, 12)
                    }
                    if !htmlFailure.isEmpty { Text(htmlFailure).font(.system(size: 15)).foregroundStyle(.secondary) }
                }.padding(.horizontal, 16).padding(.bottom, 16)
            }
        }
        .accessibilityIdentifier("home.source.html")
    }

    private func htmlRow(_ title: String, id: String, symbol: String) -> some View {
        Button { chooseHome(id) } label: {
            HStack(spacing: 9) {
                MonogramIcon(seed: title, label: SourceLabel(title), size: 34, systemImage: symbol)
                Text(title).font(.system(size: 17, weight: .semibold)).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if homeSelected && htmlHomes.activeID == id {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.accent)
                }
            }
            .padding(10).frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }.tileButton().accessibilityIdentifier("home.source.html." + id)
            .accessibilityAddTraits(homeSelected && htmlHomes.activeID == id ? .isSelected : [])
    }

    private func chooseHome(_ id: String) {
        var next = htmlHomes
        next.select(id)
        do { try next.save(); home() }
        catch { htmlFailure = error.localizedDescription }
    }
}
#endif
