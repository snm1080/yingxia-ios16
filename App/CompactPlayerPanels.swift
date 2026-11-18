#if os(iOS)
import SwiftUI
import Perception
import TVCore
@preconcurrency import AVKit

/// KS decodes the picture itself. A system audio route does not transfer that picture, so expose
/// real receiver playback and screen mirroring separately instead of presenting an inert video picker.
struct CompactPlayerCastingPanel: View {
    let channel: Channel
    let session: PlaybackSession
    let browser: PlayOnBrowser
    let sent: (String) -> Void
    @Environment(Store.self) private var store
    @State private var sending: String?
    @State private var issue: String?
    @State private var work: Task<Void, Never>?
    @State private var connectedDisplay = false
    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 14) {
                Text("播放到其他映匣设备").font(.system(size: 13, weight: .semibold))
                if browser.receivers.isEmpty {
                    Text("暂未发现设备。在同一 Wi-Fi 的 Mac 或 Apple TV 上打开映匣，并允许本地网络访问。").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(browser.receivers) { receiver in
                    WithPerceptionTracking {
                        Button { send(to: receiver) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: receiver.kind == .tv ? "appletv" : "display")
                                Text(receiver.name).lineLimit(1)
                                Spacer(minLength: 4)
                                if sending == receiver.id { ProgressView() }
                                else { Image(systemName: "chevron.right").font(.caption) }
                            }.frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(sending != nil)
                    }
                }
                if let issue { Text(issue).font(.caption).foregroundStyle(.orange).accessibilityIdentifier("player.cast.error") }
                Divider()
                Label("AirPlay 视频投屏", systemImage: "rectangle.on.rectangle").font(.system(size: 13, weight: .semibold))
                if connectedDisplay {
                    Label("已连接外接屏幕，正在输出播放画面", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                } else {
                    Text("从屏幕右上角向下滑，打开控制中心 → 屏幕镜像，选择电视或 Mac，然后回到映匣继续播放。").font(.caption).foregroundStyle(.secondary)
                    Text("此处的系统音频设备选择器只切换声音；视频请使用「屏幕镜像」或上方的映匣设备。").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    CastingAudioRoutePicker().frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("系统音频设备").font(.subheadline)
                        Text("AirPlay 音箱、耳机或电视声音").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
            .onAppear { refreshDisplay() }
            .onReceive(NotificationCenter.default.publisher(for: UIScene.didActivateNotification)) { _ in refreshDisplay() }
            .onReceive(NotificationCenter.default.publisher(for: UIScene.didDisconnectNotification)) { _ in refreshDisplay() }
            .onDisappear { work?.cancel() }
        }
    }
    private func refreshDisplay() {
        connectedDisplay = UIApplication.shared.connectedScenes.contains { $0.session.role == .windowExternalDisplayNonInteractive }
    }
    private func send(to receiver: PlayOnBrowser.Receiver) {
        guard sending == nil else { return }
        let identity = session.activeChannelID
        let request = PlayOn.Request(sender: PlayOnDevice.name, channel: channel, position: session.isLive ? nil : session.position,
                                     video: store.catalog(for: channel)?.video)
        sending = receiver.id; issue = nil
        work = Task {
            defer { sending = nil; work = nil }
            do {
                let reply = try await PlayOnBrowser.send(request, to: receiver)
                try Task.checkCancellation()
                guard session.activeChannelID == identity else { return }
                if reply.accepted { sent(receiver.name) }
                else { issue = reply.message ?? "接收设备未接受播放请求，请确认它能打开当前来源。" }
            } catch {
                if !Task.isCancelled { issue = error.localizedDescription }
            }
        }
    }
}

private struct CastingAudioRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        view.tintColor = .label
        view.accessibilityLabel = "选择系统音频设备"
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

/// The same display modes and custom-dimension limits as MacCat's video-aspect settings.
struct PlayerVideoAspect: Codable, Equatable {
    enum Mode: Int, Codable, CaseIterable, Identifiable {
        case original = 0, widescreen = 1, standard = 2, fill = 3, crop = 4, cinema = 5, adaptive = 6, custom = 7
        var id: Int { rawValue }
        static var ordered: [Self] { [.original, .widescreen, .standard, .cinema, .fill, .crop, .adaptive, .custom] }
        var title: String {
            switch self {
            case .original: "原始"; case .widescreen: "16:9"; case .standard: "4:3"; case .cinema: "21:9"
            case .fill: "填充"; case .crop: "裁剪"; case .adaptive: "自适应"; case .custom: "自定义"
            }
        }
    }
    static let key = "local.playback.videoAspect"
    var mode: Mode = .original
    var customWidth = 21.0
    var customHeight = 9.0
    static func valid(width: Double, height: Double) -> Bool {
        width.isFinite && height.isFinite && width > 0 && height > 0 && width <= 10_000 && height <= 10_000
            && (0.0001...10).contains(width / height)
    }
    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: key), let value = try? JSONDecoder().decode(Self.self, from: data),
              valid(width: value.customWidth, height: value.customHeight) else { return Self() }
        return value
    }
    func save() { if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) } }
    var forcedRatio: CGFloat? {
        switch mode {
        case .widescreen: 16 / 9; case .standard: 4 / 3; case .cinema: 21 / 9
        case .custom: CGFloat(customWidth / customHeight)
        default: nil
        }
    }
    var contentMode: UIView.ContentMode {
        switch mode {
        case .original: .scaleAspectFit
        case .crop: .scaleAspectFill
        default: .scaleToFill
        }
    }
    func frame(in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: size) }
        // MacCat's adaptive mode overrides the display ratio with the current viewport ratio and fits it.
        // Fill disables aspect preservation. Their settled frames coincide; adaptive recomputes its ratio
        // whenever the viewport rotates or changes size, exactly as MacCat's aspect=viewport mapping does.
        let ratio = mode == .adaptive ? size.width / size.height : forcedRatio
        guard let ratio else { return CGRect(origin: .zero, size: size) }
        let fitted = ratio > size.width / size.height
            ? CGSize(width: size.width, height: size.width / ratio)
            : CGSize(width: size.height * ratio, height: size.height)
        return CGRect(x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2, width: fitted.width, height: fitted.height)
    }
    func pictureFrame(in size: CGSize, source: CGSize) -> CGRect {
        guard source.width > 0, source.height > 0, size.width > 0, size.height > 0 else { return frame(in: size) }
        guard mode == .original || mode == .crop else { return frame(in: size) }
        let scale = mode == .crop ? max(size.width / source.width, size.height / source.height)
            : min(size.width / source.width, size.height / source.height)
        let fitted = CGSize(width: source.width * scale, height: source.height * scale)
        return CGRect(x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2, width: fitted.width, height: fitted.height)
    }
}

struct PlayerBitmapSubtitles: View {
    let engine: KSPlaybackEngine
    let aspect: PlayerVideoAspect
    var body: some View {
        GeometryReader { geometry in
            WithPerceptionTracking {
                bitmapLayers(in: geometry.size)
            }
        }.clipped().allowsHitTesting(false).accessibilityHidden(true)
    }
    private func bitmapLayers(in size: CGSize) -> some View {
        let picture = aspect.pictureFrame(in: size, source: engine.presentationSize)
        let bitmaps = engine.subtitleBitmaps + engine.secondarySubtitleBitmaps
        return ForEach(bitmaps.indices, id: \.self) { index in
            PlayerSubtitleBitmapLayer(bitmap: bitmaps[index], picture: picture)
        }
    }
}

private struct PlayerSubtitleBitmapLayer: View {
    let bitmap: KSPlaybackSubtitleBitmap
    let picture: CGRect
    private var rectangle: CGRect? {
        PlayerSubtitleBitmapGeometry.rectangle(origin: bitmap.origin, imageSize: bitmap.image.size,
                                               canvasSize: bitmap.canvasSize, picture: picture)
    }
    var body: some View {
        if let rectangle {
            Image(uiImage: bitmap.image).resizable()
                .frame(width: rectangle.width, height: rectangle.height)
                .position(x: rectangle.midX, y: rectangle.midY)
        }
    }
}

/// Drawing and companion-subtitle reservation must use the same canvas and fitted/cropped picture.
enum PlayerSubtitleBitmapGeometry {
    static func rectangle(origin: CGPoint, imageSize: CGSize, canvasSize: CGSize, picture: CGRect) -> CGRect? {
        SubtitleBitmapGeometry.rectangle(origin: origin, imageSize: imageSize, canvasSize: canvasSize, picture: picture)
    }
}

struct PlayerAspectPanel: View {
    @Binding var value: PlayerVideoAspect
    let close: () -> Void
    @State private var editing = false
    @State private var width = ""
    @State private var height = ""
    @State private var issue: String?
    var body: some View {
        WithPerceptionTracking {
            if editing {
                VStack(alignment: .leading, spacing: 14) {
                    Text("自定义显示比例").font(.subheadline)
                    HStack {
                        dimension("宽度", value: $width)
                        Text(":")
                        dimension("高度", value: $height)
                    }
                    Text("例如 21:9。宽高会保存，下次可继续使用。").font(.caption).foregroundStyle(.secondary)
                    if let issue { Text(issue).font(.caption).foregroundStyle(.orange) }
                    HStack {
                        Button("取消") { editing = false; issue = nil }
                        Spacer()
                        Button("确定") {
                            guard let w = Double(width), let h = Double(height), PlayerVideoAspect.valid(width: w, height: h) else {
                                issue = "宽高须大于 0 且不超过 10000，比例须在 1:10000 到 10:1 之间。"; return
                            }
                            value = PlayerVideoAspect(mode: .custom, customWidth: w, customHeight: h); close()
                        }.buttonStyle(.borderedProminent)
                    }
                }
            } else {
                VStack(spacing: 2) {
                    ForEach(PlayerVideoAspect.Mode.ordered) { mode in
                        Button {
                            if mode == .custom {
                                width = value.customWidth.formatted(.number.grouping(.never)); height = value.customHeight.formatted(.number.grouping(.never)); editing = true
                            } else { value.mode = mode; close() }
                        } label: {
                            HStack { Text(mode.title); Spacer(); if value.mode == mode { Image(systemName: "checkmark") } }
                                .padding(.horizontal, 12).frame(minHeight: 44).contentShape(Rectangle())
                                .background(value.mode == mode ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).accessibilityAddTraits(value.mode == mode ? [.isSelected] : [])
                    }
                }
            }
        }
    }
    private func dimension(_ label: String, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, text: value).keyboardType(.decimalPad).textFieldStyle(LocalGlassTextFieldStyle())
                .accessibilityLabel(label)
        }
    }
}

/// A popup lives inside the picture, leaving playback and the active control visible around it.
struct CompactPlayerPopup<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    var scrolls = true
    let close: () -> Void
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    if let subtitle { Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 4)
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 14, weight: .semibold)).frame(width: 44, height: 44).contentShape(Rectangle()) }
                    .buttonStyle(.plain).accessibilityLabel("关闭面板").accessibilityIdentifier("player.popup.close")
            }.padding(.leading, 16).padding(.trailing, 6).padding(.vertical, 6)
            Divider().opacity(0.5)
            if scrolls {
                ScrollView { VStack(alignment: .leading, spacing: 12) { content() }.padding(14).frame(maxWidth: .infinity, alignment: .leading) }
                    .scrollDismissesKeyboard(.interactively)
            } else { content().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .foregroundStyle(.white.opacity(0.96))
        .localPlayerGlassSurface(cornerRadius: 22)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .tint(.accentColor)
        .font(.system(size: 14))
        .environment(\.colorScheme, .dark)
        .textFieldStyle(LocalGlassTextFieldStyle())
        .accessibilityElement(children: .contain)
    }
}

/// Both player rows use the same unplated symbols, hit targets and selected feedback.
struct PlayerToolbarButtonStyle: ButtonStyle {
    var selected = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 24, weight: .medium))
            .frame(minWidth: 44, minHeight: 44)
            .foregroundStyle(.white.opacity(enabled ? 0.96 : 0.3))
            .background(selected ? Color.accentColor.opacity(0.2) : Color.white.opacity(configuration.isPressed ? 0.12 : 0),
                        in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
    }
}

extension View {
    /// Expand the actual Button label, so iOS 16's hit testing includes the
    /// space around an unplated symbol as well as the visible glyph.
    func playerControlTarget(_ size: CGFloat = 44) -> some View {
        frame(minWidth: max(44, size), minHeight: max(44, size)).contentShape(Rectangle())
    }
}

struct CompactPlayerTabs: View {
    let names: [String]
    @Binding var selected: String
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(names, id: \.self) { name in
                    Button { selected = name } label: {
                        Text(name).font(.system(size: 12, weight: .medium)).padding(.horizontal, 12).frame(height: 44)
                            .contentShape(Rectangle())
                            .background(selected == name ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).accessibilityAddTraits(selected == name ? [.isSelected] : [])
                        .accessibilityIdentifier("player.tab." + name)
                }
            }
        }.fixedSize(horizontal: false, vertical: true)
    }
}

struct CompactPlayerControlStyle: ButtonStyle {
    var selected = false
    var inset = true
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, inset ? 8 : 0).padding(.vertical, inset ? 5 : 0)
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .background(selected ? Color.accentColor.opacity(configuration.isPressed ? 0.23 : 0.13) : Color.primary.opacity(configuration.isPressed ? 0.10 : 0.035), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? Color.accentColor.opacity(0.28) : Color.primary.opacity(0.04), lineWidth: 0.5))
            .opacity(enabled ? 1 : 0.3)
            .contentShape(Rectangle())
    }
}

struct CompactEpisodeSkipPanel: View {
    let session: PlaybackSession
    @State private var issue: String?
    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("自动跳过片头片尾", isOn: Binding(get: { session.skipSettings.enabled }, set: { enabled in
                    var value = session.skipSettings; value.enabled = enabled; apply(value)
                })).accessibilityIdentifier("player.skip.enabled")
                skipRow(opening: true)
                skipRow(opening: false)
                Text(session.remoteSkip.status.isEmpty ? "等待视频信息" : session.remoteSkip.status)
                    .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("player.skip.remoteStatus")
                ForEach(Array(session.remoteSkip.segments.enumerated()), id: \.offset) { _, segment in
                    Text((segment.kind == "opening" ? "片头 " : "片尾 ") + EpisodeSkipSettings.formatTime(segment.start) + "–" + EpisodeSkipSettings.formatTime(segment.end) + " · " + segment.source)
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let issue { Text(issue).font(.caption).foregroundStyle(.orange) }
                Text("手动记录优先，复位后采用章节或远程匹配；片尾按剩余时长保存到当前剧集系列。").font(.caption).foregroundStyle(.secondary)
            }.font(.system(size: 12)).onAppear { session.remoteSkip.requestMatch() }
        }
    }
    private func skipRow(opening: Bool) -> some View {
        WithPerceptionTracking {
            let recorded = opening ? session.skipSettings.introEnd : session.skipSettings.outroLength
            let matched = session.remoteSkip.segments.first { $0.kind == (opening ? "opening" : "ending") && $0.end > session.position }
            HStack(spacing: 10) {
                Button(opening ? "片头" : "片尾") {
                    var value = session.skipSettings
                    if opening { value.introEnd = session.position } else { value.outroLength = max(0, session.duration - session.position) }
                    apply(value)
                }.buttonStyle(CompactPlayerControlStyle()).disabled(!session.hasTimeline || session.position <= 0 || session.position >= session.duration)
                    .accessibilityLabel(opening ? "将当前位置记录为片头结束" : "将当前位置记录为片尾开始")
                Text(recorded > 0 ? EpisodeSkipSettings.formatTime(recorded) : "未记录").monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier(opening ? "player.skip.introValue" : "player.skip.outroValue")
                if !session.skipSettings.enabled {
                    Button {
                        if let matched { session.engine.seek(to: min(matched.end, session.duration - 0.05)) }
                    } label: { Image(systemName: "forward.end").playerControlTarget() }
                        .buttonStyle(.plain).disabled(!session.hasTimeline || matched == nil)
                        .accessibilityLabel(opening ? "手动跳过片头" : "手动跳过片尾")
                }
                Button("复位") {
                    var value = session.skipSettings
                    if opening { value.introEnd = 0 } else { value.outroLength = 0 }
                    apply(value)
                }.buttonStyle(CompactPlayerControlStyle()).disabled(recorded <= 0)
                    .accessibilityIdentifier(opening ? "player.skip.resetIntro" : "player.skip.resetOutro")
            }
        }
    }
    private func apply(_ value: EpisodeSkipSettings) {
        if let error = value.validationError(duration: session.duration) { issue = error; return }
        session.applySkipSettings(value); issue = nil
    }
}

struct CompactSubtitleAddressPanel: View {
    let subtitles: ExternalSubtitles
    let back: () -> Void
    @State private var address = ""
    private var valid: Bool {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host?.isEmpty == false
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(action: back) { Label("返回字幕轨道", systemImage: "chevron.left").playerControlTarget() }.buttonStyle(.plain)
            TextField("https://example.com/subtitles.srt", text: $address)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .textFieldStyle(LocalGlassTextFieldStyle()).accessibilityIdentifier("player.subtitle.address")
            Text("支持 SRT、VTT、ASS 和 SSA 字幕地址。").font(.caption).foregroundStyle(.secondary)
            Button("添加字幕") { subtitles.add(address: address); back() }
                .buttonStyle(.borderedProminent).disabled(!valid).accessibilityIdentifier("player.subtitle.address.add")
        }
    }
}

#endif
