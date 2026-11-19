#if os(iOS)
import SwiftUI
import Perception
import TVCore

struct CompactSubtitleStylePanel: View {
    let section: String
    let subtitles: ExternalSubtitles
    let engine: KSPlaybackEngine
    @State private var style = SubtitleStyle.load()
    @State private var timingStep = 0.5
    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 14) {
                if section == "外观" {
                    SubtitleLines(lines: ["字幕效果预览"], style: style, letters: min(32, max(12, style.size * 4.8)), oneLine: true)
                        .frame(maxWidth: .infinity).padding(12).background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                    Toggle("覆盖 ASS/SSA 自带样式", isOn: $style.overrideAssStyle)
                        .accessibilityIdentifier("player.subtitle.overrideAssStyle")
                    if isASS {
                        Label(style.overrideAssStyle ? "正在使用统一字幕样式" : "正在保留 ASS/SSA 自带样式",
                              systemImage: style.overrideAssStyle ? "textformat" : "doc.richtext")
                            .font(.system(size: 16)).foregroundStyle(.secondary)
                            .accessibilityIdentifier("player.subtitle.assStyleStatus")
                    }
                    if isASS && !style.overrideAssStyle { Text("保留 ASS/SSA 的字体、颜色、对齐、定位、移动和淡入淡出。高级卡拉 OK、绘图和复杂变换暂不支持。开启覆盖后应用所选样式。").font(.system(size: 16)).foregroundStyle(.secondary) }
                    if isBitmap { Text("当前为图片字幕，字体、字号和颜色不适用于图片内容。").font(.system(size: 16)).foregroundStyle(.secondary) }
                    PlayerFontPicker(family: Binding(get: { style.font ?? "" }, set: { style.font = $0.isEmpty ? nil : $0 }))
                    PlaybackStyleRange(title: "字号", value: Binding(get: { style.size * 10 }, set: { style.size = $0 / 10 }), range: 12...96, step: 1, unit: " px")
                    PlaybackStyleColorPicker(title: "字幕颜色", value: Binding(get: { style.customColor ?? colorHex }, set: { style.customColor = $0 }))
                    PlaybackStyleRange(title: "透明度", value: Binding(get: { (1 - style.opacity) * 100 }, set: { style.opacity = 1 - $0 / 100 }), range: 0...100, unit: "%")
                    Toggle("字幕粗体", isOn: $style.bold)
                } else if section == "位置" {
                    PlaybackStyleRange(title: "垂直位置", value: Binding(get: { style.y * 100 }, set: { style.y = $0 / 100 }), range: 0...100, unit: "%")
                    PlaybackStyleColorPicker(title: "字幕描边颜色", value: $style.outlineColor)
                    PlaybackStyleRange(title: "描边大小", value: $style.outlineSize, range: 0...8, step: 0.1, unit: " px")
                    PlaybackStyleRange(title: "阴影大小", value: $style.shadowOffset, range: 0...8, step: 0.1, unit: " px")
                } else {
                    let external = subtitles.document != nil
                    let delay = external ? subtitles.timing.delay : engine.subtitleDelay
                    Text("字幕时间").font(.system(size: 21, weight: .semibold))
                    Text("步长").font(.system(size: 16)).foregroundStyle(.secondary)
                    HStack {
                        ForEach([0.1, 0.5, 1, 5], id: \.self) { step in
                            Button(step.formatted() + " 秒") { timingStep = step }
                                .buttonStyle(CompactPlayerControlStyle(selected: timingStep == step))
                                .accessibilityIdentifier("player.subtitle.step." + step.formatted())
                        }
                    }
                    Text(delay == 0 ? "同步 0 秒" : String(format: "%@ %.1f 秒", delay < 0 ? "提前" : "延后", abs(delay)))
                        .monospacedDigit().accessibilityIdentifier("player.subtitle.delay")
                    HStack {
                        Button("提前 \(timingStep.formatted()) 秒") { changeDelay(currentDelay - timingStep, external: external) }
                            .accessibilityIdentifier("player.subtitle.earlier")
                        Button("延后 \(timingStep.formatted()) 秒") { changeDelay(currentDelay + timingStep, external: external) }
                            .accessibilityIdentifier("player.subtitle.later")
                    }.buttonStyle(.bordered)
                    Button("重置字幕时间") { changeDelay(0, external: external) }.buttonStyle(.bordered).disabled(delay == 0)
                    PlaybackStyleRange(title: "延迟", value: Binding(get: { currentDelay }, set: { changeDelay($0, external: external) }), range: -60...60, step: 0.1, unit: " 秒")
                    Text("正值延后显示，负值提前显示。").font(.system(size: 16)).foregroundStyle(.secondary)
                    if external {
                        LocalGlassChoicePicker(title: "原始帧率", selection: Binding(get: { subtitles.timing.rate?.id ?? "" }, set: { id in
                            subtitles.setTiming(SubtitleTiming(delay: subtitles.timing.delay, scale: SubtitleTiming.rates.first { $0.id == id }?.scale ?? 1))
                        }), options: [LocalGlassChoice("", "保持原样")] +
                            SubtitleTiming.rates.map { LocalGlassChoice($0.id, $0.title + " fps") })
                    }
                }
                if section != "时间" {
                    Button("恢复默认") { style = SubtitleStyle(); changeDelay(0, external: subtitles.document != nil) }.buttonStyle(.bordered)
                }
                Text("实时生效 · 自动保存").font(.system(size: 16)).foregroundStyle(.secondary)
            }
            .appOnChange(of: style) { _, value in value.save() }
        }
    }
    private var codec: String {
        engine.tracks.first { $0.kind == .subtitle && ($0.id == engine.subtitleSelection || engine.subtitleSelection == nil && $0.selected) }?.codec?.lowercased() ?? ""
    }
    private var currentDelay: Double { subtitles.document != nil ? subtitles.timing.delay : engine.subtitleDelay }
    private var isASS: Bool { subtitles.document?.format.isStyled == true || ["ass", "ssa"].contains(codec) }
    private var isBitmap: Bool { ["pgs", "dvd_subtitle", "dvb_subtitle", "xsub", "hdmv_pgs_subtitle"].contains(codec) }
    private var colorHex: String {
        let rgb = style.color.rgb
        return String(format: "#%02X%02X%02X", Int(rgb.red * 255), Int(rgb.green * 255), Int(rgb.blue * 255))
    }
    private func changeDelay(_ value: Double, external: Bool) {
        guard value.isFinite else { return }
        let clamped = (min(60, max(-60, value)) * 10).rounded() / 10
        if external { subtitles.setTiming(SubtitleTiming(delay: clamped, scale: subtitles.timing.scale)) }
        else {
            UserDefaults.standard.set(clamped, forKey: "local.playback.subtitleDelay")
            engine.setSubtitleDelay(clamped)
        }
    }
}

struct CompactDanmakuStylePanel: View {
    let section: String
    @AppBindable var model: CatalogDanmakuModel
    @State private var fancy = FancyDanmakuPreferences.load()
    @State private var editNames = false
    @AppStorage("danmakuFontFamily") private var family = ""
    @AppStorage("danmakuFontWeight") private var weight = 400
    @AppStorage("danmakuLineSpacing") private var spacing = 7.0
    @AppStorage("danmakuDelay") private var delay = 0.0
    @AppStorage("danmakuSpeed") private var speed = 1.0
    @AppStorage("danmakuMaxRows") private var rows = 0
    @AppStorage("danmakuAreaPercent") private var areaPercent = 50.0
    @AppStorage("danmakuColorMode") private var colorMode = "source"
    @AppStorage("danmakuGradientStart") private var gradientStart = "#FFB86C"
    @AppStorage("danmakuGradientEnd") private var gradientEnd = "#8BE9FD"
    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 14) {
                if section == "花式弹幕" {
                    Text("花式弹幕").font(.system(size: 21, weight: .semibold))
                    Text("17 种效果 · 独立配比 · 即时保存").font(.system(size: 16)).foregroundStyle(.secondary)
                    Toggle("启用花式弹幕", isOn: $fancy.enabled)
                    PlaybackStyleRange(title: "总比例", value: $fancy.ratio, range: 0...100, unit: "%")
                    Toggle("显示装饰图标", isOn: $fancy.icons)
                    Text("约 \(Int(totalWeight > 0 ? fancy.ratio : 0))% 的普通弹幕使用花式，其余保持原样。徽章角色名 \(fancy.normalized.names.components(separatedBy: "\n").filter { !$0.isEmpty }.count) 个。")
                        .font(.system(size: 16)).foregroundStyle(.secondary)
                    HStack {
                        Button("全部启用") { fancy.kinds = FancyDanmakuPreferences.ids }
                        Button("全部关闭") { fancy.kinds = [] }
                        Button("角色名") { editNames.toggle() }
                    }.buttonStyle(.bordered)
                    if editNames {
                        Text("徽章角色名（每行一个）").font(.system(size: 19))
                        TextEditor(text: $fancy.names).scrollContentBackground(.hidden)
                            .frame(minHeight: 100).padding(8).localGlassInputSurface()
                        Text("最多 30 个，每个最多 16 字。").font(.system(size: 16)).foregroundStyle(.secondary)
                    }
                    ForEach(Array(NativeFancyDanmakuPainter.specs.enumerated()), id: \.element.id) { index, spec in
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle(String(format: "%02d %@", index + 1, spec.name), isOn: Binding(get: { fancy.kinds.contains(spec.id) }, set: { enabled in
                                fancy.kinds = FancyDanmakuPreferences.ids.filter { $0 == spec.id ? enabled : fancy.kinds.contains($0) }
                            }))
                            Text(fancy.kinds.contains(spec.id) && totalWeight > 0 ? "占花式 \(Int((fancy.weights[index] / totalWeight * 100).rounded()))%" : "未参与")
                                .font(.system(size: 16)).foregroundStyle(.secondary)
                            FancyDanmakuPreview(variant: spec.id, icons: fancy.icons, label: fancy.normalized.names.components(separatedBy: "\n").first ?? "")
                            PlaybackStyleRange(title: "比例权重", value: Binding(get: { fancy.weights[index] }, set: { fancy.weights[index] = $0 }), range: 0...100, unit: "%")
                        }.padding(12).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                    }
                } else if section == "外观" {
                    Text("弹幕效果预览").font(.custom(family.isEmpty ? ".AppleSystemUIFont" : family, size: min(32, model.fontSize * 0.72)))
                        .fontWeight(fontWeight).foregroundStyle(previewColor).opacity(model.opacity)
                        .frame(maxWidth: .infinity).padding(12).background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                    PlayerFontPicker(family: $family)
                    PlaybackStyleRange(title: "字号", value: $model.fontSize, range: 12...64, unit: " px")
                    LocalGlassChoicePicker(title: "字体粗细", selection: $weight,
                                           options: stride(from: 100, through: 900, by: 100).map { LocalGlassChoice($0, String($0)) })
                    PlaybackStyleRange(title: "透明度", value: Binding(get: { (1 - model.opacity) * 100 }, set: { model.opacity = 1 - $0 / 100 }), range: 0...100, unit: "%")
                    LocalGlassChoicePicker(title: "弹幕颜色", selection: $colorMode,
                                           options: [.init("source", "自带色"), .init("white", "白色"),
                                                     .init("random", "随机"), .init("gradient", "渐变"),
                                                     .init("gradientAuto", "自动渐变")])
                    if colorMode == "gradient" {
                        PlaybackStyleColorPicker(title: "渐变起始颜色", value: $gradientStart)
                        PlaybackStyleColorPicker(title: "渐变结束颜色", value: $gradientEnd)
                    }
                } else if section == "时间" {
                    PlaybackStyleRange(title: "滚动速度", value: $speed, range: 0.25...3, step: 0.05, unit: "×")
                    PlaybackStyleRange(title: "延迟", value: $delay, range: -60...60, step: 0.1, unit: " 秒")
                    Text("正值延后显示，负值提前显示。").font(.system(size: 16)).foregroundStyle(.secondary)
                } else {
                    PlaybackStyleRange(title: "显示区域", value: $areaPercent, range: 10...100, step: 5, unit: "%")
                    PlaybackStyleRange(title: "行间距", value: $spacing, range: -28...32, unit: " px")
                    PlaybackStyleRange(title: "最大滚动行数", value: Binding(get: { Double(rows) }, set: { rows = Int($0) }), range: 0...30, unit: " 行")
                    Text("弹幕限制在画面上方所选区域；行数 0 为自动，实际行数同时受区域和字号限制。").font(.system(size: 16)).foregroundStyle(.secondary)
                }
                Button("恢复默认") { reset() }.buttonStyle(.bordered)
                Text("实时生效 · 自动保存").font(.system(size: 16)).foregroundStyle(.secondary)
            }.appOnChange(of: fancy) { _, value in value.save() }
                .onAppear {
                    if UserDefaults.standard.object(forKey: "danmakuAreaPercent") == nil,
                       let legacyArea = UserDefaults.standard.object(forKey: DanmakuArea.key) as? Int { areaPercent = Double(legacyArea) }
                }
        }
    }
    private var totalWeight: Double { FancyDanmakuPreferences.ids.indices.reduce(0) { $0 + (fancy.kinds.contains(FancyDanmakuPreferences.ids[$1]) ? fancy.weights[$1] : 0) } }
    private var fontWeight: Font.Weight { [.ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black][min(8, max(0, weight / 100 - 1))] }
    private var previewColor: AnyShapeStyle {
        if colorMode == "gradient" { return AnyShapeStyle(LinearGradient(colors: [PlaybackStyleColorPicker.color(gradientStart), PlaybackStyleColorPicker.color(gradientEnd)], startPoint: .leading, endPoint: .trailing)) }
        // The preview line shows its own automatic gradient, computed from
        // the preview text exactly as a comment's would be.
        if colorMode == "gradientAuto", let stops = PlayerStyleColor.autoGradientColors(text: "弹幕效果预览") {
            return AnyShapeStyle(LinearGradient(colors: stops.map { PlaybackStyleColorPicker.color($0) }, startPoint: .leading, endPoint: .trailing))
        }
        return AnyShapeStyle(colorMode == "random" ? Color.pink : Color.white)
    }
    private func reset() {
        if section == "花式弹幕" { fancy = FancyDanmakuPreferences(); return }
        family = ""; weight = 400; spacing = 7; delay = 0; speed = 1; rows = 0; areaPercent = 50
        colorMode = "source"; gradientStart = "#FFB86C"; gradientEnd = "#8BE9FD"; model.fontSize = 25; model.opacity = 0.9
    }
}

private struct FancyDanmakuPreview: View {
    let variant: String
    let icons: Bool
    let label: String
    @Environment(\.displayScale) private var scale
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24)) { timeline in
            if let bitmap = NativeFancyDanmakuPainter.preview(variant: variant, icons: icons, label: label, size: 20, scale: scale, age: timeline.date.timeIntervalSinceReferenceDate) {
                Image(decorative: bitmap, scale: scale).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 46)
            }
        }.frame(height: 46).accessibilityLabel("花式效果预览")
    }
}

/// The danmaku panel's section titles （显示区域 / 行间距 / 最大滚动行数） and its
/// tab row （来源 / 花式弹幕 / 外观 / 时间 / 密度） share this one style, so the two
/// cannot drift apart in size again.
enum DanmakuPanelTextStyle {
    static let sectionTitle = Font.system(size: 19)
}

private struct PlaybackStyleRange: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step = 1.0
    var unit = ""
    var body: some View {
        VStack(spacing: 6) {
            HStack { Text(title); Spacer(); Text(value.formatted(.number.precision(.fractionLength(0...2))) + unit).monospacedDigit().foregroundStyle(.secondary) }
            HStack {
                Slider(value: $value, in: range, step: step)
                TextField(title, value: Binding(get: { value }, set: { if $0.isFinite { value = min(range.upperBound, max(range.lowerBound, $0)) } }), format: .number.precision(.fractionLength(0...2)))
                    .keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing)
                    .textFieldStyle(LocalGlassTextFieldStyle()).frame(width: 88)
            }
        }.font(DanmakuPanelTextStyle.sectionTitle)
    }
}

private struct PlaybackStyleColorPicker: View {
    let title: String
    @Binding var value: String
    var body: some View {
        HStack {
            ColorPicker(title, selection: Binding(get: { Self.color(value) }, set: { color in
                guard let components = UIColor(color).cgColor.converted(to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil)?.components, components.count >= 3 else { return }
                value = String(format: "#%02X%02X%02X", Int((components[0] * 255).rounded()), Int((components[1] * 255).rounded()), Int((components[2] * 255).rounded()))
            }), supportsOpacity: false)
            Text(value.uppercased()).font(.system(size: 16, design: .monospaced)).foregroundStyle(.secondary)
        }
    }
    static func color(_ hex: String) -> Color {
        let rgb = PlayerStyleColor.rgb(hex)
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

#endif
