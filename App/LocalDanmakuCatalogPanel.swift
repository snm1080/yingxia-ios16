import SwiftUI
import Perception
import TVCore

#if !os(tvOS)
struct LocalDanmakuCatalogPanel: View {
    let enhancements: NativeMediaEnhancements
    let model: CatalogDanmakuModel
    let importFile: () -> Void
    var importing = false
    var importError: String? = nil
    var openConfiguration: (() -> Void)? = nil
    @State private var sources: [NativeDanmakuCatalogSource] = []
    @State private var keyword = ""
    @State private var results: [NativeDanmakuCatalogResult] = []
    @State private var chosen: NativeDanmakuCatalogResult?
    @State private var episodes: [NativeDanmakuCatalogEpisode] = []
    @State private var status = ""
    @State private var busy = false
    @State private var work: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var episodeQuery = ""
    @State private var page = 0
    @State private var configurationAvailable = false
    private var filteredEpisodes: [NativeDanmakuCatalogEpisode] {
        let query = episodeQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return episodes.enumerated().filter {
            query.isEmpty || $0.element.title.localizedCaseInsensitiveContains(query) || String($0.offset + 1) == query
        }.map(\.element)
    }
    private var pageCount: Int { max(1, (filteredEpisodes.count + 39) / 40) }
    private var visibleEpisodes: [NativeDanmakuCatalogEpisode] { Array(filteredEpisodes.dropFirst(min(page, pageCount - 1) * 40).prefix(40)) }
    private var enabledSources: [NativeDanmakuCatalogSource] { sources.filter(\.enabled) }
    var body: some View {
        WithPerceptionTracking {
            panelContent
                .task(id: enhancements.sessionID) { beginMedia() }
                .task(id: enhancements.sessionID) { await checkConfiguration() }
                .onDisappear { cancel() }
                .onReceive(NotificationCenter.default.publisher(for: LocalDanmakuPreferences.changed)) { _ in reloadSourcePreferences() }
                .appOnChange(of: episodeQuery) { _, _ in page = 0 }
        }
    }
    private var panelContent: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 12) {
                sourceControls
                searchControls
                if busy { ProgressView() }
                if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
                if let importError { Text(importError).font(.caption).foregroundStyle(.orange) }
                if importing { ProgressView("正在导入弹幕…") }
                resultContent
                importControls
            }
        }
    }
    private var sourceControls: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("启用来源").font(.subheadline.weight(.semibold))
                    Spacer()
                    Button { refreshSources() } label: { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44) }
                        .buttonStyle(.plain).localGlassInputSurface()
                        .accessibilityLabel("刷新弹幕来源").disabled(busy)
                    if configurationAvailable, let openConfiguration {
                        Button(action: openConfiguration) { Image(systemName: "globe").frame(width: 44, height: 44) }
                            .buttonStyle(.plain).localGlassInputSurface()
                            .accessibilityLabel("配置弹幕来源").accessibilityIdentifier("player.danmaku.configuration")
                    }
                }
                ForEach(sources) { source in
                    Button { setSourceEnabled(!source.enabled, for: source) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: source.enabled ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(source.enabled ? Color.accentColor : Color.secondary)
                            Text(source.name).foregroundStyle(.primary).multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).localGlassInputSurface()
                    .accessibilityLabel(source.name).accessibilityValue(source.enabled ? "已启用" : "已停用")
                    .accessibilityAddTraits(source.enabled ? .isSelected : [])
                    .accessibilityIdentifier("player.danmaku.source." + source.id)
                }
                if !sources.isEmpty && enabledSources.isEmpty {
                    Text("选择至少一个来源以搜索弹幕。").font(.caption).foregroundStyle(.secondary)
                }
                if sources.isEmpty && !busy { Text("没有可用弹幕来源，可在弹幕设置中添加 API。").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
    private var searchControls: some View {
        WithPerceptionTracking {
            HStack {
                TextField("影片名称", text: $keyword).textFieldStyle(LocalGlassTextFieldStyle()).onSubmit { search() }
                Button("搜索") { search() }.disabled(busy || keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || enabledSources.isEmpty)
                if busy { Button("取消") { cancel(); status = "已取消" } }
            }
        }
    }
    @ViewBuilder private var resultContent: some View {
        if let chosen { episodeContent(chosen) }
        else {
            ForEach(results) { result in
                Button(result.title + " · " + result.source.name) { choose(result) }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).disabled(busy)
            }
        }
    }
    private func episodeContent(_ chosen: NativeDanmakuCatalogResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button("返回搜索结果") { cancel(); self.chosen = nil; episodes = [] }
            Text(chosen.title).font(.headline)
            TextField("筛选弹幕集数", text: $episodeQuery).textFieldStyle(LocalGlassTextFieldStyle())
            episodePages
            ForEach(visibleEpisodes) { episode in
                Button(episode.title) { load(episode, result: chosen) }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).disabled(busy)
            }
            if filteredEpisodes.isEmpty { Text("没有匹配的集数").font(.caption).foregroundStyle(.secondary) }
        }
    }
    private var episodePages: some View {
        HStack {
            Text("\(filteredEpisodes.count) 集").font(.caption).foregroundStyle(.secondary)
            Spacer()
            if pageCount > 1 {
                Button("上一页") { page -= 1 }.disabled(page <= 0)
                Text("\(min(page, pageCount - 1) + 1) / \(pageCount)").font(.caption.monospacedDigit())
                Button("下一页") { page += 1 }.disabled(page >= pageCount - 1)
            }
        }
    }
    private var importControls: some View {
        HStack {
            Button(action: importFile) { Text("导入弹幕文件").frame(minHeight: 44).contentShape(Rectangle()) }
                .disabled(busy || importing).accessibilityIdentifier("player.danmaku.import")
            Button { run { try await enhancements.restoreSource() } } label: {
                Text("恢复来源弹幕").frame(minHeight: 44).contentShape(Rectangle())
            }.disabled(busy || importing)
            Button(role: .destructive) { cancel(); enhancements.clear() } label: {
                Text("清除").frame(minHeight: 44).contentShape(Rectangle())
            }.disabled(importing)
        }.buttonStyle(.plain)
    }
    private func beginMedia() {
        cancel(); clearResults(); sources = []; keyword = model.context?.videoName ?? ""; refreshSources()
    }
    private func checkConfiguration() async {
        let website = await NativeDanmakuCatalog(context: model.context).configurationWebsite()
        guard !Task.isCancelled else { return }
        configurationAvailable = website != nil
    }
    private func cancel() { generation = UUID(); work?.cancel(); work = nil; busy = false }
    private func clearResults() { results = []; chosen = nil; episodes = []; episodeQuery = ""; page = 0 }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        let active = UUID(); generation = active; busy = true; status = ""
        work = Task {
            defer { if generation == active { busy = false; work = nil } }
            do { try await action() }
            catch { if generation == active && !Task.isCancelled { status = error.localizedDescription } }
        }
    }
    private func refreshSources() {
        clearResults()
        run {
            let values = await NativeDanmakuCatalog(context: model.context).sources(includeDisabled: true)
            try Task.checkCancellation()
            sources = values
        }
    }
    private func reloadSourcePreferences() {
        cancel(); clearResults(); status = ""
        let builtin = sources.filter(\.isBuiltin).map { source in
            var source = source; source.enabled = LocalDanmakuPreferences.builtinEnabled(); return source
        }
        sources = builtin + NativeDanmakuAPIStore.load().map {
            NativeDanmakuCatalogSource(id: $0.id, name: $0.name, address: $0.url, enabled: $0.enabled)
        }
    }
    private func setSourceEnabled(_ enabled: Bool, for source: NativeDanmakuCatalogSource) {
        do {
            try NativeDanmakuCatalog.setEnabled(enabled, source: source)
            reloadSourcePreferences()
        } catch { status = error.localizedDescription }
    }
    private func search() {
        let selected = enabledSources
        guard !selected.isEmpty else { status = "请先启用弹幕来源"; return }
        chosen = nil; episodes = []
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        run {
            let catalog = NativeDanmakuCatalog(context: model.context)
            let answers = await withTaskGroup(of: (Int, [NativeDanmakuCatalogResult], String?).self) { group in
                for (index, source) in selected.enumerated() {
                    group.addTask {
                        do { return (index, try await catalog.search(query, source: source), nil) }
                        catch { return (index, [], source.name + "：" + error.localizedDescription) }
                    }
                }
                var answers: [(Int, [NativeDanmakuCatalogResult], String?)] = []
                for await answer in group { answers.append(answer) }
                return answers.sorted { $0.0 < $1.0 }
            }
            try Task.checkCancellation(); results = answers.flatMap { $0.1 }
            status = results.isEmpty ? "没有找到弹幕" : "找到 \(results.count) 个结果"
            let errors = answers.compactMap { $0.2 }
            if !errors.isEmpty { status += "；" + errors.joined(separator: "；") }
        }
    }
    private func choose(_ result: NativeDanmakuCatalogResult) {
        run {
            let values = try await NativeDanmakuCatalog(context: model.context).episodes(result)
            try Task.checkCancellation(); episodes = values; chosen = result; page = 0; episodeQuery = ""
        }
    }
    private func load(_ episode: NativeDanmakuCatalogEpisode, result: NativeDanmakuCatalogResult) {
        run {
            try await enhancements.prepareCatalog(episode, result: result)
            try Task.checkCancellation()
            enhancements.remember(result: result, episode: episode)
            status = "已加载 " + episode.title
        }
    }
}
#endif
