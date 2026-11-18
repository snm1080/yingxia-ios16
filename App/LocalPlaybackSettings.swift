import SwiftUI
import TVCore

struct LocalCacheSettingsView: View {
    @AppStorage("local.videoCache.enabled") private var enabled = true
    @AppStorage("local.videoCache.sizeGB") private var size = 1
    @AppStorage("local.playback.prefetchNext") private var prefetch = true
    @State private var cachedBytes = 0
    @State private var reusedBytes = 0
    @State private var cacheStatus: String?
    @State private var clearing = false
    var body: some View {
        SettingsPage(title: "视频缓存", symbol: "internaldrive") {
            SettingsGroup(title: "视频缓存", footer: "按播放请求缓存媒体数据，切换媒体和退出后释放。用户下载单独保留。") {
                Toggle("开启视频缓存", isOn: $enabled)
                Picker("缓存容量", selection: $size) { ForEach(1...4, id: \.self) { Text("\($0) GB").tag($0) } }.disabled(!enabled)
                Toggle("预加载下一集", isOn: $prefetch)
            }
            SettingsGroup(title: "缓存使用情况") {
                SettingsRow(symbol: "internaldrive", tint: Brand.cyan, title: "已缓存 \(ByteCountFormatter.string(fromByteCount: Int64(cachedBytes), countStyle: .file))")
                SettingsRow(symbol: "arrow.triangle.2.circlepath", tint: .blue, title: "已复用 \(ByteCountFormatter.string(fromByteCount: Int64(reusedBytes), countStyle: .file))")
                if let cacheStatus { Text(cacheStatus).font(.footnote).foregroundStyle(.secondary) }
                SettingsActionRow(title: clearing ? "清理中…" : "清理视频缓存", destructive: true) {
                    clearing = true
                    Task {
                        do { try await MobileMediaServices.clearVideoCache(); await refreshUsage() }
                        catch { cacheStatus = "缓存服务暂不可用，下次播放会按当前设置重试。" }
                        clearing = false
                    }
                }.disabled(clearing)
            }
            SettingsGroup {
                SettingsLinkRow(symbol: "photo.stack", title: "图片、剧集和弹幕缓存") { CacheSettingsView() }
                SettingsLinkRow(symbol: "arrow.down.circle", title: "已下载视频") { DownloadsView() }
            }
        }
        .task(id: "\(enabled):\(size)") {
            do {
                try await MobileMediaServices.configureVideoCache(enabled: enabled, sizeGB: size)
                cacheStatus = nil
            } catch { cacheStatus = "缓存服务暂不可用，下次播放会按当前设置重试。" }
            while !Task.isCancelled {
                await refreshUsage()
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            }
        }
    }
    @MainActor private func refreshUsage() async {
        guard let value = try? await MobileMediaServices.videoCacheSummary(), !Task.isCancelled else { return }
        cachedBytes = value.bytes; reusedBytes = value.hits
    }
}

struct LocalAdSettingsView: View {
    @AppStorage("local.hlsAdClean") private var enabled = true
    var body: some View {
        SettingsPage(title: "去广告", symbol: "shield.lefthalf.filled") {
            SettingsGroup(footer: "对可识别的 M3U8 广告片段进行清理。分离音视频的流保留同步；遇到异常可关闭后重试。") {
                Toggle("M3U8 去广告", isOn: $enabled)
            }
        }
    }
}

#if os(iOS)
struct LocalPlayerSettingsView: View {
    @AppStorage(PlaybackInfo.key) private var showsPlaybackInfo = false
    @AppStorage("local.playback.osd") private var showsOSD = true
    @AppStorage("local.playback.osd.title") private var osdTitle = true
    @AppStorage("local.playback.osd.resolution") private var osdResolution = true
    @AppStorage("local.playback.osd.fps") private var osdFPS = true
    @AppStorage("local.playback.osd.clock") private var osdClock = true
    @AppStorage("local.playback.osd.progress") private var osdProgress = true
    @AppStorage("local.playback.osd.speed") private var osdSpeed = true
    var body: some View {
        SettingsPage(title: "播放器", symbol: "play.rectangle") {
            SettingsGroup(title: "播放信息") {
                Toggle("播放屏显", isOn: $showsOSD)
                Toggle("显示视频技术信息", isOn: $showsPlaybackInfo)
            }
            SettingsGroup(title: "屏显内容", footer: "每一项单独显隐；「播放屏显」关闭时整体隐藏。") {
                Toggle("标题", isOn: $osdTitle)
                Toggle("分辨率", isOn: $osdResolution)
                Toggle("帧率", isOn: $osdFPS)
                Toggle("时钟", isOn: $osdClock)
                Toggle("进度", isOn: $osdProgress)
                Toggle("网速", isOn: $osdSpeed)
            }.disabled(!showsOSD)
        }
    }
}
#endif
