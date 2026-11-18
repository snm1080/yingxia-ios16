import SwiftUI
import Perception
import TVCore

#if os(iOS)
struct LocalSettingsView: View {
    @Environment(\.dynamicTypeSize) private var dynamicType
    private var columns: [GridItem] {
        dynamicType.isAccessibilitySize ? [GridItem(.flexible())] :
            [GridItem(.flexible()), GridItem(.flexible())]
    }
    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                LocalSettingsCard(symbol: "house.fill", title: "首页") { LocalHomeSettingsView() }
                LocalSettingsCard(symbol: "dock.rectangle", title: "Dock 按钮") { LocalDockButtonsSettingsView() }
                LocalSettingsCard(symbol: "list.bullet.rectangle", title: "订阅") { LocalSourceSettingsView(kind: .subscription) }
                LocalSettingsCard(symbol: "chevron.left.forwardslash.chevron.right", title: "python") { LocalSourceSettingsView(kind: .python) }
                LocalSettingsCard(symbol: "heart.fill", title: "收藏") { FavoritesView() }
                LocalSettingsCard(symbol: "film.stack", title: "TMDB") { TMDBServiceSettingsView() }
                LocalSettingsCard(symbol: "captions.bubble", title: "在线字幕") { LocalOnlineSubtitleSettingsView() }
                LocalSettingsCard(symbol: "waveform", title: "AI字幕") { LocalAISubtitleSettingsView() }
                LocalSettingsCard(symbol: "internaldrive", title: "视频缓存") { LocalCacheSettingsView() }
                LocalSettingsCard(symbol: "text.bubble", title: "弹幕") { LocalDanmakuSettingsView() }
                LocalSettingsCard(symbol: "seal.fill", title: "媒体徽章") { LocalMediaBadgeSettingsView() }
                LocalSettingsCard(symbol: "shield.lefthalf.filled", title: "去广告") { LocalAdSettingsView() }
                LocalSettingsCard(symbol: "archivebox", title: "备份迁移") { LocalBackupSettingsView() }
            }
            .frame(maxWidth: Layout.settingsWidth).padding(16).frame(maxWidth: .infinity)
        }
        // One Dynamic Type step up, matching SettingsPage: the hub's cards scale,
        // and the size carries into destinations that are not SettingsPage-based
        // (the Dock buttons list, favorites).
        .dynamicTypeSize(.xLarge)
        .localGlassSettingsCanvas().navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                RouteLink { LocalAboutView() } label: { SettingsIcon(symbol: "info.circle", tint: Brand.indigo).frame(width: 44, height: 44).contentShape(Rectangle()) }
                    .accessibilityLabel("关于")
            }
        }
    }
}

private struct LocalSettingsCard<Destination: View>: View {
    let symbol: String
    let title: String
    @ViewBuilder var destination: @MainActor @Sendable () -> Destination
    var body: some View {
        RouteLink(destination: destination) {
            HStack(spacing: 10) {
                MonogramIcon(seed: title, label: SourceLabel(title), size: 36, systemImage: symbol)
                    .frame(width: 36, height: 48)
                Text(title).font(.headline).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(12).frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
            .localGlassSurface(cornerRadius: 22)
            .contentShape(RoundedRectangle(cornerRadius: 22))
        }.buttonStyle(.plain).accessibilityIdentifier("settings." + title)
    }
}

struct LocalHomeSettingsView: View {
    @AppStorage(LocalHomeDestination.key) private var destination = LocalHomeDestination.home
    @AppStorage("local.home.continueWatching") private var recent = true
    var body: some View {
        SettingsPage(title: "首页", symbol: "house.fill") {
            LocalAppearanceSettingsSection()
            SettingsGroup(title: "首页") {
                Picker("默认打开", selection: $destination) {
                    ForEach(LocalHomeDestination.allCases) { Text($0.title).tag($0) }
                }
                Toggle("继续观看", isOn: $recent)
            }
            LocalHTMLHomeSettingsSection()
        }
    }
}

struct LocalAboutView: View {
    @Environment(Updates.self) private var updates
    @Environment(Store.self) private var store
    var body: some View {
        WithPerceptionTracking {
            SettingsPage(title: "关于", symbol: "info.circle") {
                SettingsGroup {
                    LabeledContent("版本", value: updates.current)
                    LabeledContent("构建", value: String(updates.build))
                    Text("iOS 16.2 本地维护版").foregroundStyle(.secondary)
                }
                SettingsGroup {
                    SettingsLinkRow(symbol: "doc.plaintext", title: "开源许可") { LicensesView() }
                    SettingsLinkRow(symbol: "stethoscope", title: "诊断") { DiagnosticsView() }
                    SettingsLinkRow(symbol: "hand.raised", title: "数据与隐私") { LocalDataSettingsView() }
                }
            }
        }
    }
}

private struct LocalDataSettingsView: View {
    @Environment(Store.self) private var store
    @AppStorage(CloudSync.enabledKey) private var sync = true
    var body: some View {
        SettingsPage(title: "数据与隐私", symbol: "hand.raised") {
            SettingsGroup {
                Toggle("iCloud 同步", isOn: $sync)
                    .appOnChange(of: sync) { _, enabled in store.cloudSync?.setEnabled(enabled) }
                Text("同步订阅、收藏与观看记录。内置 TMDB 保持可用，自定义服务在 TMDB 页面设置。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}
#endif
