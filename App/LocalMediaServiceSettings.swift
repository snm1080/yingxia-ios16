import SwiftUI
import Perception
import TVCore

@MainActor enum LocalMediaServiceSettings {
    static func apply() async throws {
        try await MobileMediaServices.configure([
            "subtitles": .object(LocalOnlineSubtitlePreferences.load().values),
            "ai": .object(LocalAISubtitlePreferences.load().values),
        ])
    }
}

struct LocalDanmakuSettingsView: View {
    @Environment(Store.self) private var store
    @State private var hasBuiltin = false
    @AppStorage("danmakuEnabled") private var enabled = true
    @AppStorage("danmakuAutoMatch") private var automatic = true
    var body: some View {
        WithPerceptionTracking {
            SettingsPage(title: "弹幕", symbol: "text.bubble") {
                SettingsGroup(title: "弹幕") {
                    Toggle("启用弹幕", isOn: $enabled).settingsSwitch()
                    Toggle("自动匹配", isOn: $automatic).settingsSwitch()
                }
                LocalDanmakuAPISettings(hasBuiltin: hasBuiltin)

            }.navigationTitle("弹幕")
                .task(id: store.subscription?.importedAt) {
                    hasBuiltin = false
                    if let subscription = store.subscription { hasBuiltin = await NativeDanmakuCatalog.hasBuiltin(subscription: subscription) }
                }
                .appOnChange(of: enabled) { _, _ in notify() }
                .appOnChange(of: automatic) { _, _ in notify() }

        }
    }
    private func notify() { NotificationCenter.default.post(name: LocalDanmakuPreferences.changed, object: nil) }
}

struct LocalOnlineSubtitleSettingsView: View {
    @State private var config = LocalOnlineSubtitlePreferences.load()
    @State private var status = ""
    var body: some View {
        SettingsPage(title: "在线字幕", symbol: "captions.bubble") {
            SettingsGroup(title: "在线字幕来源") {
                Toggle("迅雷字幕", isOn: $config.xunlei).settingsSwitch()
                Toggle("射手字幕（本地 / 网盘文件匹配）", isOn: $config.shooter).settingsSwitch()
                Toggle("Assrt 字幕", isOn: $config.assrt).settingsSwitch()
                Toggle("SubtitleCat 多语言字幕", isOn: $config.subtitlecat).settingsSwitch()
                Toggle("SubHD 字幕", isOn: $config.subhd).settingsSwitch()
            }
            SettingsGroup(title: "偏好", footer: "播放器的字幕面板可搜索、下载并加载字幕；支持时间校正。修改后保存生效。") {
                Picker("字幕语言", selection: $config.language) { Text("中文").tag("zh"); Text("英文").tag("en") }
                SecureField("Assrt Token", text: $config.assrtToken)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                if !config.assrtToken.isEmpty { Button("清除已保存的密钥") { config.assrtToken = ""; status = "密钥将在保存后清除" } }
                Button("保存在线字幕设置") {
                    do { try config.save(); status = "已保存" } catch { status = error.localizedDescription }
                }.settingsButton(prominent: true).accessibilityIdentifier("settings.subtitles.save")
                if !status.isEmpty { Text(status).font(.system(size: 14)).foregroundStyle(.secondary) }
            }
        }
    }
}
