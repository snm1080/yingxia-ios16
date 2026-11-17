import SwiftUI
import Perception
import TVCore

#if os(iOS)
/// Home detail opens this with its work identity; editing the query clears that identity.
struct PanSearchView: View {
    let title: String
    var year: String? = nil
    var metadataHint: MediaMetadataHint? = nil
    @State private var query = ""
    @FocusState private var queryFocused: Bool
    @State private var model = PanSearchModel()
    @State private var operation: Task<Void, Never>?
    @State private var showsSettings = false
    @State private var hideBad = true
    @State private var disk = ""
    @State private var checkError: String?
    @State private var checkEnabled = PanSearchSettings.load().panCheckLinks
    @State private var initialized = false
    @State private var manuallyChecked = false
    @State private var resumeSearch = false
    @Environment(Store.self) private var store
    @Environment(\.isLocalPageActive) private var pageActive
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openRoute) private var openRoute
    private var showChecks: Bool { checkEnabled || manuallyChecked }
    private var items: [PanSearchItem] { model.visibleItems }
    private func updateFilter() { model.setFilter(disk: disk, hideInvalid: hideBad, checksEnabled: showChecks) }
    /// Embedded panels share the same model and playback flow as the standalone page.
    var embedded = false
    var close: (() -> Void)? = nil
    var revealQuery: (() -> Void)? = nil
    var body: some View {
        WithPerceptionTracking {
            Group {
                if embedded { panel }
                else { ScrollView { WithPerceptionTracking { panel.padding(20) } }.navigationTitle("盘搜") }
            }
            .toolbar {
                if !embedded {
                    ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) { Button { showsSettings = true } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("盘搜设置") }
                }
            }
            .appOnChange(of: disk) { _, _ in updateFilter() }
            .appOnChange(of: hideBad) { _, _ in updateFilter() }
            .appOnChange(of: showChecks) { _, _ in updateFilter() }
            .onAppear {
                updateFilter()
                if !initialized {
                    initialized = true; query = title
                    model.updateQuery(title, year: year, metadataHint: metadataHint)
                    if pageActive { search() }
                } else if pageActive {
                    if resumeSearch { search() } else if checkEnabled { check(refresh: false) }
                }
            }
            .appOnChange(of: queryFocused) { _, focused in
                if focused { revealQuery?() }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                if queryFocused { revealQuery?() }
            }
            .appOnChange(of: query) { _, value in
                guard value != model.query else { return }
                cancel(); model.updateQuery(value); disk = ""
            }
            .onDisappear { resumeSearch = resumeSearch || model.searching; cancel() }
            .appOnChange(of: pageActive) { _, active in
                if !active { resumeSearch = resumeSearch || model.searching; cancel() }
                else if resumeSearch { search() }
                else if model.result != nil, checkEnabled { check(refresh: false) }
            }
            .onReceive(NotificationCenter.default.publisher(for: PanSearchSettings.changed)) { _ in
                checkEnabled = PanSearchSettings.load().panCheckLinks; manuallyChecked = false
                if checkEnabled, pageActive { check(refresh: false) } else { cancel() }
            }
            .localGlassDialog(isPresented: $showsSettings, title: "盘搜设置", maxWidth: 520, maxHeight: 680, layout: .centered) {
                PanSearchSettingsView()
            }
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("盘搜资源", systemImage: "cloud").font(.headline).lineLimit(1).minimumScaleFactor(0.8)
                    Text(model.result.map { "找到 \($0.items.count) 条资源" } ?? "搜索片名，选择资源查看详情")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                HStack(spacing: 0) {
                    Button { showsSettings = true } label: { Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44).contentShape(Rectangle()) }
                        .buttonStyle(.plain).accessibilityLabel("盘搜设置").accessibilityIdentifier("discover.pan.settings")
                    Button { store.searchVideos(query) } label: { Image(systemName: "magnifyingglass").frame(width: 44, height: 44).contentShape(Rectangle()) }
                        .buttonStyle(.plain).disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.subscription == nil)
                        .accessibilityLabel("全局搜索当前剧集").accessibilityIdentifier("discover.pan.globalSearch")
                }
                if let close {
                    Button { cancel(); close() } label: { Image(systemName: "xmark").frame(width: 44, height: 44).contentShape(Rectangle()) }
                        .buttonStyle(.plain).accessibilityLabel("关闭盘搜").accessibilityIdentifier("discover.pan.close")
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("盘搜关键词", text: $query).focused($queryFocused).submitLabel(.search).onSubmit { search() }
                    .autocorrectionDisabled().accessibilityIdentifier("discover.pan.query")
                Button("搜索") { search() }
                    .buttonStyle(LocalGlassButtonStyle(prominent: true))
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.searching)
                    .accessibilityIdentifier("discover.pan.submit")
            }.padding(.horizontal, 12).padding(.vertical, 6).localGlassInputSurface(cornerRadius: 16)
                .id("discover.pan.query.anchor")
            if model.searching {
                HStack { ProgressView(); Text("正在检索网盘资源…").font(.subheadline); Spacer(); Button("取消") { cancel() }.frame(minHeight: 44) }
            }
            if let error = model.error {
                Text(error).font(.subheadline).foregroundStyle(.red)
                Button("重试") { search() }.frame(minHeight: 44)
            }
            if let result = model.result {
                if result.partial { Text("部分来源暂时不可用或返回不完整，已收到的资源仍可查看。").font(.footnote).foregroundStyle(.secondary) }
                if !result.items.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            diskButton("", count: result.items.count)
                            ForEach(result.diskTypes, id: \.self) { type in
                                WithPerceptionTracking { diskButton(type, count: result.diskCounts[type] ?? 0) }
                            }
                        }
                    }
                    let providerCount = disk.isEmpty ? result.items.count : result.diskCounts[disk] ?? 0
                    let hidden = providerCount - items.count
                    Text("\(disk.isEmpty ? "全部网盘" : panDiskName(disk)) · 当前显示 \(items.count) 条 / 共 \(providerCount) 条" + (hidden > 0 ? " · 已隐藏 \(hidden) 条失效链接" : ""))
                        .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("discover.pan.filterSummary")
                    if showChecks {
                        Toggle("隐藏失效链接", isOn: $hideBad).font(.subheadline)
                    }
                    HStack(spacing: 8) {
                        if model.checking { ProgressView() }
                        Text(showChecks ? checkSummary(total: result.items.count) : "自动链接检测已关闭")
                            .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("discover.pan.checkSummary")
                        Spacer(minLength: 4)
                        Button(model.checking ? "停止检测" : "重新检测") {
                            if model.checking { cancel() } else { check() }
                        }.font(.subheadline).frame(minWidth: 72, minHeight: 44)
                            .accessibilityIdentifier("discover.pan.recheck")
                    }
                    if let checkError { Text(checkError).font(.footnote).foregroundStyle(.red) }
                }
                if items.isEmpty {
                    Text(result.items.isEmpty ? "没有找到资源，请调整片名或搜索范围。" : "当前筛选没有结果。")
                        .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 12)
                }
                LazyVStack(spacing: 10) {
                    ForEach(items) { item in
                        WithPerceptionTracking { resourceRow(item) }
                    }
                }
            }
        }
        .padding(16)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 22))

    }

    private func diskButton(_ type: String, count: Int) -> some View {
        Button { disk = type } label: {
            Text("\(type.isEmpty ? "全部" : panDiskName(type)) \(count)")
                .font(.subheadline.weight(disk == type ? .semibold : .regular))
                .padding(.horizontal, 14).frame(minHeight: 44)
                .background(disk == type ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06), in: Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(disk == type ? .isSelected : [])
    }

    private func resourceRow(_ item: PanSearchItem) -> some View {
        PanSearchResourceRow(item: item, status: model.checks[item.id], checking: model.checkingIDs.contains(item.id), showChecks: showChecks) {
            let hint = model.metadataHint
            let selectedTitle = hint == nil ? MediaDanmakuIdentity.title(item.title) : model.query
            openRoute?(Route { AnyView(PanShareResolveView(request: MediaPushRequest(input: item.input, title: selectedTitle, metadataHint: hint))) })
        }.equatable()
    }
    private func cancel() { operation?.cancel(); operation = nil; model.cancel(); checkError = nil }
    private func search() {
        queryFocused = false; resumeSearch = false; disk = ""
        operation?.cancel()
        if query != model.query { model.updateQuery(query) }
        let settings = PanSearchSettings.load(); checkEnabled = settings.panCheckLinks; manuallyChecked = false; updateFilter()
        operation = Task {
            await model.search { query, year in
                try await settings.configure()
                return try await PanSearchService.search(query, year: year)
            }
            guard !Task.isCancelled, settings.panCheckLinks else { return }
            await model.check()
        }
    }
    private func check(refresh: Bool = true) {
        guard pageActive, model.result != nil else { return }
        if refresh { manuallyChecked = true }
        operation?.cancel()
        checkError = nil
        operation = Task {
            do { try await PanSearchSettings.load().configure() }
            catch { if !Task.isCancelled { checkError = error.localizedDescription }; return }
            await model.check(refresh: refresh) { items, refresh in try await PanSearchService.check(items, refresh: refresh, manual: refresh) }
        }
    }
    private func checkSummary(total: Int) -> String {
        var text = model.checking ? "正在检测链接 \(model.checks.count)/\(total)" : "已检测 \(model.checks.count)/\(total)"
        for (state, label) in [(PanLinkStatus.State.ok, "有效"), (.bad, "失效"), (.locked, "需码"), (.uncertain, "无法确认"), (.unsupported, "不支持检测")] {
            let count = model.checkCounts[state] ?? 0
            if count > 0 { text += " · \(label) \(count)" }
        }
        return text
    }

}

/// A status arriving for another share must not redraw this row's text/layout.
private struct PanSearchResourceRow: View, Equatable {
    let item: PanSearchItem
    let status: PanLinkStatus?
    let checking: Bool
    let showChecks: Bool
    let action: () -> Void
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item && lhs.status == rhs.status && lhs.checking == rhs.checking && lhs.showChecks == rhs.showChecks
    }
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(spacing: 5) {
                    Image(systemName: "cloud").font(.title3)
                    Text(panDiskName(item.diskType)).font(.caption2).multilineTextAlignment(.center)
                }.foregroundStyle(.tint).frame(width: 52)
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        if showChecks, status?.state == .ok {
                            Circle().fill(.green).frame(width: 7, height: 7).accessibilityLabel("链接有效")
                        }
                        Text(item.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).multilineTextAlignment(.leading)
                    }
                    Text([item.source, item.datetime].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    if !item.password.isEmpty { Text("提取码：\(item.password)").font(.caption).foregroundStyle(.secondary) }
                    if showChecks {
                        if checking {
                            Label("检测中", systemImage: "clock").font(.caption).foregroundStyle(.secondary)
                        } else if let status = status {
                            Label(status.summary, systemImage: statusSymbol(status.state)).font(.caption).foregroundStyle(statusColor(status.state))
                        } else { Label("尚未检测", systemImage: "circle.dashed").font(.caption).foregroundStyle(.secondary) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            }.padding(14).frame(minHeight: 70).background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
                .contentShape(RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain).accessibilityIdentifier("discover.pan.item.\(item.id)")
            .contextMenu { Button("复制分享链接") { UIPasteboard.general.string = item.input } }
    }
    private func statusColor(_ state: PanLinkStatus.State) -> Color {
        switch state { case .ok: .green; case .bad: .red; case .locked: .orange; case .unsupported, .uncertain: .secondary }
    }
    private func statusSymbol(_ state: PanLinkStatus.State) -> String {
        switch state { case .ok: "checkmark.circle.fill"; case .bad: "xmark.circle.fill"; case .locked: "lock.fill"; case .unsupported: "minus.circle"; case .uncertain: "questionmark.circle" }
    }
}

private let panDisks: [(String, String)] = [("quark", "夸克"), ("aliyun", "阿里云盘"), ("baidu", "百度网盘"), ("uc", "UC 网盘"), ("tianyi", "天翼云盘"), ("123", "123 云盘"), ("115", "115 网盘"), ("pikpak", "PikPak"), ("xunlei", "迅雷"), ("mobile", "移动云盘"), ("guangya", "光鸭云盘"), ("magnet", "磁力"), ("ed2k", "电驴")]
private func panDiskName(_ id: String) -> String { panDisks.first { $0.0 == id }?.1 ?? id }

struct PanSearchSettingsView: View {
    @State private var settings = PanSearchSettings.load()
    @State private var busy = false
    @State private var message: String?
    @State private var operation: Task<Void, Never>?
    var body: some View {
        Form {
            Section("盘搜服务") {
                TextField("盘搜地址", text: $settings.panApiBase).autocorrectionDisabled().textInputAutocapitalization(.never)
                SecureField("访问令牌（可选）", text: $settings.panToken)
                Button("清除令牌") { settings.panToken = "" }
                Toggle("自动本机检测链接有效性", isOn: $settings.panCheckLinks)
                Text("支持 HTTP、HTTPS 服务地址，也可填写完整的 /api/search 地址。").font(.footnote).foregroundStyle(.secondary)
            }.listRowBackground(Color.clear)
            Section("网盘类型") {
                Text("未选择时搜索全部网盘。").font(.footnote).foregroundStyle(.secondary)
                ForEach(panDisks, id: \.0) { id, name in
                    Toggle(name, isOn: Binding(get: { settings.panCloudTypes.split(separator: ",").contains(Substring(id)) }, set: { selected in
                        var values = settings.panCloudTypes.split(separator: ",").map(String.init).filter { $0 != id }
                        if selected { values.append(id) }; settings.panCloudTypes = values.joined(separator: ",")
                    }))
                }
                Button("全部类型") { settings.panCloudTypes = "" }
            }.listRowBackground(Color.clear)
            Section("搜索范围与筛选") {
                TextField("TG 频道", text: $settings.panChannels, axis: .vertical)
                TextField("插件", text: $settings.panPlugins, axis: .vertical)
                Text("留空使用服务默认配置；单独填 0 关闭；多个名称用逗号或换行分隔。").font(.footnote).foregroundStyle(.secondary)
                TextField("包含关键词", text: $settings.panInclude, axis: .vertical)
                TextField("排除关键词", text: $settings.panExclude, axis: .vertical)
                Text("关键词用逗号或换行分隔；短语内的空格会保留。").font(.footnote).foregroundStyle(.secondary)
                LocalGlassChoicePicker(title: "来源", selection: $settings.panSource,
                                       options: [.init("all", "全部"), .init("tg", "TG"), .init("plugin", "插件")])
                LocalGlassChoicePicker(title: "结果类型", selection: $settings.panResult,
                                       options: [.init("merge", "合并链接"), .init("all", "全部"), .init("results", "原始结果")])
                TextField("并发数（1–64，留空自动）", text: $settings.panConcurrency).keyboardType(.numberPad)
                Toggle("强制刷新服务缓存", isOn: $settings.panRefresh)
                TextField("插件扩展参数（JSON 对象）", text: $settings.panExt, axis: .vertical).autocorrectionDisabled().textInputAutocapitalization(.never)
            }.listRowBackground(Color.clear)
            Section {
                Button(busy ? "正在保存…" : "保存盘搜设置") {
                    busy = true; message = nil
                    let value = settings
                    operation = Task {
                        defer { busy = false }
                        do { try await value.configure(); try Task.checkCancellation(); try value.save(); message = "已保存" }
                        catch { if !Task.isCancelled { message = error.localizedDescription } }
                    }
                }.disabled(busy)
                if let message { Text(message).font(.footnote) }
            }.listRowBackground(Color.clear)
        }
        .textFieldStyle(LocalGlassTextFieldStyle())
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .onDisappear { operation?.cancel() }
    }
}
#endif
