import Foundation
import Perception
import AVFoundation
import TVCore

@MainActor @Perceptible final class NativeMediaEnhancements {
    private(set) var comments: [Danmaku] = []
    private(set) var revision = UUID()
    /// Stable across window refreshes and live batches; only replacing/retiming a track resets its sprites.
    private(set) var sourceRevision = UUID()
    private(set) var status = ""
    private(set) var notice: PlayerNotice?
    private(set) var isLive = false
    private(set) var sessionID = ""
    private(set) var timelineVersion = 0
    var mediaVersion: Int { 0 }
    var serviceReady: Bool { ready }
    var hasSelectedTrack: Bool {
        if catalog.selection.origin == .manual && !nativeManual { return false }
        return catalog.selection.origin == .cleared || indexed || isLive || (!comments.isEmpty && catalog.selection.origin != .manual) || nativeManual
    }
    @PerceptionIgnored private let catalog: CatalogDanmakuModel
    @PerceptionIgnored private weak var player: AVPlayer?
    #if os(iOS)
    @PerceptionIgnored private weak var engine: KSPlaybackEngine?
    func begin(channel: Channel, sessionID: String, engine: KSPlaybackEngine) {
        begin(channel: channel, sessionID: sessionID, player: nil)
        self.engine = engine
    }
    #endif
    @PerceptionIgnored private var channel: Channel?
    @PerceptionIgnored private var descriptor: MediaDanmakuDescriptor?
    @PerceptionIgnored private var loading: Task<Void, Never>?
    @PerceptionIgnored private var ready = false
    @PerceptionIgnored private var liveEnabled = true
    @PerceptionIgnored private var indexed = false
    @PerceptionIgnored private var nativeManual = false
    @PerceptionIgnored private var usesBuiltinSource = false
    @PerceptionIgnored private var selectedCatalogSource: NativeDanmakuCatalogSource?
    @PerceptionIgnored private var pendingCatalogSelection: (source: NativeDanmakuCatalogSource, previous: DanmakuTrackSelection)?
    @PerceptionIgnored private var builtinEnabled = LocalDanmakuPreferences.builtinEnabled()
    @PerceptionIgnored private var busy = false
    @PerceptionIgnored private var lastWindow = -1000.0
    @PerceptionIgnored private var lastPosition = -1.0
    @PerceptionIgnored private var lastOffset = 0.0
    @PerceptionIgnored private var lastTimelineRevision = -1
    @PerceptionIgnored private var lastSampleWall = 0.0
    @PerceptionIgnored private var liveSequence = 0
    @PerceptionIgnored private var rawLiveComments: [Danmaku] = []
    @PerceptionIgnored private var generation = UUID()
    init(catalog: CatalogDanmakuModel) {
        self.catalog = catalog
        catalog.nativeImport = { [weak self] url in try await self?.importFile(url) }
        catalog.nativeAutomatic = { [weak self] in self?.settingsChanged() }
    }
    private func setStatus(_ message: String, kind: PlayerNotice.Kind = .information) {
        guard status != message || notice == nil else { return }
        status = message
        notice = message.isEmpty ? nil : PlayerNotice(message: message, kind: kind)
    }
    func sourceLoaded(count: Int) {
        guard !catalog.selection.hasExplicitChoice else { return }
        setStatus(count > 0 ? "已加载订阅弹幕 · \(count) 条" : "订阅没有返回弹幕",
                  kind: count > 0 ? .success : .information)
    }
    var serviceParams: [String: JSONValue] {
        ["sessionId": .string(sessionID), "mediaVersion": .number(0), "timelineVersion": .number(Double(timelineVersion))]
    }
    func begin(channel: Channel, sessionID: String, player: AVPlayer?) {
        stop(); self.channel = channel; self.sessionID = sessionID; self.player = player
        CatPawDanmaku.beginPlayback(channel.historyContext, sessionID: sessionID, requestJSON: channel.playback?.requestJSON)
        catalog.beginMedia(channel.historyContext.map { $0.id + "|" + $0.episodeName } ?? channel.id, context: channel.historyContext)
        descriptor = MediaDanmakuRegistry.descriptor(for: channel.url)
        // Preserve the canonical source answer across remux/proxy URL copies,
        // process-local registry eviction and a restored playback descriptor.
        if descriptor == nil, let json = channel.playback?.resultJSON,
           let result = try? JSONDecoder().decode([String: JSONValue].self, from: Data(json.utf8)) {
            let request = channel.playback?.requestJSON.flatMap { try? JSONDecoder().decode([String: JSONValue].self, from: Data($0.utf8)) }
            let origin = channel.historyContext?.origin ?? channel.url
            let base = request?["siteAPI"]?.string.flatMap { URL(string: $0, relativeTo: origin)?.absoluteURL } ?? origin
            descriptor = MediaDanmakuDescriptor(result: result,
                baseURL: base.absoluteString, headers: channel.headers)
            if let descriptor { MediaDanmakuRegistry.register(descriptor, for: channel.url) }
        }
        setStatus(catalog.enabled ? "正在准备弹幕" : "弹幕已关闭")
        let active = generation
        loading = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await MobileMediaServices.call("session.set", self.sessionDefinition())
                guard active == self.generation else { return }
                try await LocalMediaServiceSettings.apply()
                guard active == self.generation else { return }
                self.ready = true
                guard self.catalog.enabled else { return }
                if let saved = self.rememberedFeed(), let source = self.selectedCatalogSource {
                    try await self.prepareRemembered(saved, source: source)
                } else if self.descriptor != nil, LocalDanmakuPreferences.builtinEnabled() { try await self.useSource() }
                else { await self.matchCatalogAutomatically() }
            } catch { if active == self.generation, !Task.isCancelled { self.setStatus("弹幕服务暂不可用，可在弹幕面板重试", kind: .warning) } }
        }
    }
    private func settingsChanged() {
        let nextBuiltin = LocalDanmakuPreferences.builtinEnabled()
        let builtinChanged = nextBuiltin != builtinEnabled
        builtinEnabled = nextBuiltin
        // Cancelling a pending replacement restores the selection of the still
        // displayed track. Its committed source must remain the one we validate.
        if let pending = pendingCatalogSelection {
            catalog.selection = pending.previous
            pendingCatalogSelection = nil
        }
        let selectedSourceDisabled = selectedCatalogSource.map { !NativeDanmakuCatalog.isEnabled($0) } ?? false
        guard ready else { return }
        generation = UUID(); busy = false
        loading?.cancel(); loading = nil
        if !catalog.selection.hasExplicitChoice { catalog.selection = DanmakuTrackSelection() }
        if !catalog.enabled {
            setStatus("弹幕已关闭")
            if isLive { let params = serviceParams; Task { _ = try? await MobileMediaServices.call("live.stop", params) }; liveEnabled = false }
            return
        }
        guard !catalog.selection.hasExplicitChoice || (usesBuiltinSource && builtinChanged) || selectedSourceDisabled else { return }
        selectedCatalogSource = nil
        comments = []; rawLiveComments = []; revision = UUID(); sourceRevision = UUID(); indexed = false; nativeManual = false
        if isLive { let params = serviceParams; Task { _ = try? await MobileMediaServices.call("live.stop", params) }; isLive = false }
        catalog.clear(keepingContext: true)
        catalog.selection = DanmakuTrackSelection()
        catalog.beginMedia(channel?.id ?? "", context: channel?.historyContext)
        loading = Task { [weak self] in
            guard let self else { return }
            do {
                if nextBuiltin {
                    await self.catalog.nativeSourceReload?()
                }
                if nextBuiltin, self.descriptor != nil { try await self.useSource() }
                else { await self.matchCatalogAutomatically() }
            } catch { if !Task.isCancelled { self.setStatus("弹幕加载失败，可在弹幕面板重试", kind: .warning) } }
        }
    }
    /// One diagnostics line per failed catalog step, so a screenshot of
    /// 设置 → 关于 → 诊断 shows which source and step failed and how.
    private func noteCatalogFailure(_ error: Error, source: NativeDanmakuCatalogSource, step: String) {
        let failure = error as NSError
        Diagnostics.shared.record(.info, "danmaku.api", "source=\(source.name) step=\(step) failed=\(failure.domain):\(failure.code)")
    }
    private func matchCatalogAutomatically() async {
        guard catalog.enabled, !catalog.selection.hasExplicitChoice else { return }
        guard catalog.automatic else { setStatus("自动匹配弹幕已关闭"); return }
        guard let context = catalog.context else { setStatus("当前媒体没有可匹配的弹幕信息"); return }
        let active = generation
        setStatus("正在自动匹配订阅弹幕")
        var failed = false
        var unauthorized = false
        if LocalDanmakuPreferences.builtinEnabled(), let pushed = await CatPawDanmaku.comments(for: context), !pushed.comments.isEmpty {
            guard active == generation, !Task.isCancelled, catalog.enabled, !catalog.selection.hasExplicitChoice else { return }
            let normalized: JSONValue = .array(pushed.comments.map { comment in
                .object(["time": .number(comment.time), "mode": .number(Double(comment.mode.rawValue)),
                         "color": .number(Double(comment.color)), "text": .string(comment.text)])
            })
            do {
                let text = String(data: try JSONEncoder().encode(normalized), encoding: .utf8)!
                catalog.sourceSelected(); usesBuiltinSource = true
                let count = try await prepare(["text": .string(text)], manual: false)
                guard active == generation, !Task.isCancelled, catalog.enabled, !catalog.selection.hasExplicitChoice else { return }
                if count > 0 { setStatus("订阅已自动推送弹幕 · \(count) 条", kind: .success) }
                return
            } catch {
                if active != generation || Task.isCancelled || catalog.selection.hasExplicitChoice { return }
                failed = true
            }
        }
        let service = NativeDanmakuCatalog(context: context)
        if await matchRememberedShow(service: service, context: context, generation: active) { return }
        for source in await service.sources() {
            guard active == generation, !Task.isCancelled, catalog.enabled, !catalog.selection.hasExplicitChoice else { return }
            do {
                let results = try await service.search(context.videoName, source: source)
                guard active == generation, !Task.isCancelled, catalog.enabled, !catalog.selection.hasExplicitChoice else { return }
                let matches = NativeDanmakuCatalogResult.automaticCandidates(in: results, context: context)
                for result in matches {
                    do {
                        let episodes = try await service.episodes(result)
                        guard active == generation, !Task.isCancelled, catalog.enabled, !catalog.selection.hasExplicitChoice else { return }
                        guard let number = CatalogDanmakuMatcher.episodeNumber(context.episodeName) else { continue }
                        let matched = episodes.filter { CatalogDanmakuMatcher.episodeNumber($0.title) == number }
                        guard matched.count == 1, let episode = matched.first else { continue }
                        let parameters = try await service.prepareParameters(episode, result: result)
                        guard active == generation, !Task.isCancelled, catalog.enabled, !catalog.selection.hasExplicitChoice else { return }
                        catalog.sourceSelected()
                        let count = try await prepare(parameters, manual: false, source: source)
                        guard active == generation, !Task.isCancelled, catalog.enabled, !catalog.selection.hasExplicitChoice else { return }
                        if count > 0 { setStatus("已自动匹配弹幕 · \(count) 条", kind: .success); return }
                    } catch {
                        if active != generation || Task.isCancelled || catalog.selection.hasExplicitChoice { return }
                        failed = true
                        noteCatalogFailure(error, source: source, step: "prepare")
                        if case TVError.http(let code) = error, code == 401 || code == 403 { unauthorized = true }
                    }
                }
            } catch {
                if active != generation || Task.isCancelled || catalog.selection.hasExplicitChoice { return }
                failed = true
                noteCatalogFailure(error, source: source, step: "search")
                if case TVError.http(let code) = error, code == 401 || code == 403 { unauthorized = true }
            }
        }
        guard active == generation, !Task.isCancelled, catalog.enabled, !catalog.selection.hasExplicitChoice else { return }
        // A self-hosted API that gates on a token in its address path answers
        // every step with 401; calling that a generic fetch failure sends the
        // viewer hunting in the wrong place, so name the actual problem.
        setStatus(unauthorized ? "弹幕 API 未授权（401）：请检查 API 地址是否带 token" :
                  failed ? "弹幕获取失败，可在弹幕面板重试" : "没有匹配到本集弹幕，可在弹幕面板选择来源",
                  kind: failed ? .warning : .information)
    }
    func prepareCatalog(_ episode: NativeDanmakuCatalogEpisode, result: NativeDanmakuCatalogResult) async throws {
        let scope = generation, previous = catalog.selection
        guard ready, catalog.enabled, !Task.isCancelled, NativeDanmakuCatalog.isEnabled(result.source) else { throw CancellationError() }
        catalog.selection.select(.manual)
        let ticket = catalog.selection.ticket
        // The reservation belongs to this source before the first request. A source
        // disabled during either lookup or preparation must invalidate this choice.
        pendingCatalogSelection = (result.source, previous)
        do {
            let parameters = try await NativeDanmakuCatalog(context: catalog.context).prepareParameters(episode, result: result)
            guard scope == generation, catalog.selection.ticket == ticket, ready, catalog.enabled,
                  !Task.isCancelled, NativeDanmakuCatalog.isEnabled(result.source) else { throw CancellationError() }
            try await prepare(parameters, manual: true, source: result.source)
        } catch {
            if scope == generation, catalog.selection.ticket == ticket {
                catalog.selection = previous
                pendingCatalogSelection = nil
            }
            throw error
        }
    }
    private func prepareRemembered(_ url: String, source: NativeDanmakuCatalogSource) async throws {
        let ticket = catalog.selection.ticket, scope = generation
        guard ready, catalog.enabled, !Task.isCancelled, !catalog.selection.hasExplicitChoice,
              NativeDanmakuCatalog.isEnabled(source) else { throw CancellationError() }
        if let address = URL(string: url), address.host == "api.dandanplay.net" {
            let values = try await CatalogDanmakuClient().comments(CatalogDanmakuEpisode(id: address.lastPathComponent, title: "已选择分集"))
            guard scope == generation, catalog.selection.ticket == ticket, ready, catalog.enabled,
                  !Task.isCancelled, NativeDanmakuCatalog.isEnabled(source) else { throw CancellationError() }
            let normalized: JSONValue = .array(values.map { value -> JSONValue in .object(["time": .number(value.time), "mode": .number(Double(value.mode.rawValue)), "color": .number(Double(value.color)), "text": .string(value.text)]) })
            try await prepare(["text": .string(String(data: try JSONEncoder().encode(normalized), encoding: .utf8)!)], manual: true, source: source)
        } else {
            try await prepare(["url": .string(url)], manual: true, source: source)
        }
    }
    private func rememberedFeed() -> String? {
        guard let channel else { return nil }
        let key = "danmaku.manual." + (channel.historyContext?.id ?? channel.id) + "|" + (channel.historyContext?.episodeID ?? channel.id)
        guard let data = UserDefaults.standard.data(forKey: key), let record = try? JSONDecoder().decode([String: String].self, from: data),
              let address = record["api"], !address.isEmpty, let episode = record["episode"], let server = try? CatalogDanmakuClient(address: address).server else { return nil }
        // Restore only a currently configured custom API. Runtime aggregate addresses
        // expire with their bundle's port and must be obtained again by source matching.
        guard record["builtin"] != "1", let api = NativeDanmakuAPIStore.enabled().first(where: {
            $0.url == address && (record["sourceID"] == nil || record["sourceID"] == $0.id)
        }) else { return nil }
        selectedCatalogSource = NativeDanmakuCatalogSource(id: api.id, name: api.name, address: api.url)
        return server.appendingPathComponent("api/v2/comment/" + episode).absoluteString + "?format=xml&withRelated=true"
    }
    private func sessionDefinition() -> [String: JSONValue] {
        guard let channel else { return [:] }
        var request: [String: JSONValue] = ["title": .string(channel.historyContext?.videoName ?? channel.name), "episodeName": .string(channel.historyContext?.episodeName ?? channel.name), "url": .string(channel.url.absoluteString), "direct": .string(channel.url.absoluteString)]
        if let context = channel.historyContext {
            request["sourceId"] = .string(context.origin.absoluteString); request["siteKey"] = .string(context.sourceKey)
            request["vodId"] = .string(context.videoID); request["flag"] = .string(context.episodeFlag); request["id"] = .string(context.episodeID)
        } else { request["direct"] = .string(channel.url.absoluteString); request["id"] = .string(channel.id) }
        let quality: JSONValue = .object(["url": .string(channel.url.absoluteString), "originalUrl": .string(channel.url.absoluteString), "headers": .object(channel.headers.mapValues(JSONValue.string))])
        return ["id": .string(sessionID), "mediaVersion": .number(0), "timelineVersion": .number(Double(timelineVersion)), "request": .object(request), "qualities": .array([quality]), "isLive": .bool(descriptor?.live != nil)]
    }
    func stop() {
        let previous = sessionID
        CatPawDanmaku.endPlayback(sessionID: previous)
        generation = UUID(); loading?.cancel(); loading = nil; ready = false; indexed = false
        comments = []; revision = UUID(); sourceRevision = UUID(); isLive = false; nativeManual = false; descriptor = nil; busy = false
        usesBuiltinSource = false; selectedCatalogSource = nil; pendingCatalogSelection = nil; builtinEnabled = LocalDanmakuPreferences.builtinEnabled()
        lastWindow = -1000; lastPosition = -1; timelineVersion = 0
        lastTimelineRevision = -1; lastSampleWall = 0; liveSequence = 0; rawLiveComments = []; status = ""; notice = nil
        sessionID = ""; player = nil; channel = nil
        #if os(iOS)
        engine = nil
        #endif
        if !previous.isEmpty { Task { _ = try? await MobileMediaServices.call("session.stop", ["sessionId": .string(previous)]) } }
    }
    func clear() {
        generation = UUID(); busy = false
        loading?.cancel(); loading = nil
        selectedCatalogSource = nil
        pendingCatalogSelection = nil
        if let channel {
            let key = "danmaku.manual." + (channel.historyContext?.id ?? channel.id) + "|" + (channel.historyContext?.episodeID ?? channel.id)
            UserDefaults.standard.removeObject(forKey: key)
        }
        catalog.clear(keepingContext: true); comments = []; rawLiveComments = []; revision = UUID(); sourceRevision = UUID(); indexed = false; nativeManual = false; isLive = false
        setStatus("已清除本集弹幕")
        let params = serviceParams
        Task { _ = try? await MobileMediaServices.call("live.stop", params) }
    }
    func useSource() async throws {
        guard let descriptor, ready, catalog.enabled, LocalDanmakuPreferences.builtinEnabled() else { return }
        guard !catalog.selection.hasExplicitChoice else { return }
        let active = generation
        nativeManual = false; usesBuiltinSource = true; selectedCatalogSource = nil; catalog.sourceSelected()
        let ticket = catalog.selection.ticket
        if let live = descriptor.live {
            var params = serviceParams; params["descriptor"] = live; params["baseURL"] = .string(descriptor.baseURL); params["enabled"] = .bool(catalog.enabled)
            _ = try await MobileMediaServices.call("live.start", params)
            guard active == generation, catalog.selection.ticket == ticket else { throw CancellationError() }
            sourceRevision = UUID()
            liveSequence = 0
            rawLiveComments = []; comments = []; revision = UUID()
            liveEnabled = catalog.enabled; isLive = true; indexed = false; setStatus("正在连接实时弹幕")
        } else if let feed = descriptor.feed {
            // Bilibili protobuf stays on the established native segmented loader.
            if DanmakuSource.bilibiliCID(feed) != nil {
                if let channel { DanmakuSource.register(channel.url, feed: feed, duration: nil) }
                setStatus("正在加载订阅弹幕")
                await catalog.nativeSourceReload?()
                return
            }
            try await prepare(["url": .string(feed), "headers": .object(descriptor.headers.mapValues(JSONValue.string))], manual: false)
        }
    }
    func prepareFeed(_ address: String, headers: [String: String] = [:]) async throws {
        try await prepare(["url": .string(address), "headers": .object(headers.mapValues(JSONValue.string))], manual: true)
    }
    func restoreSource() async throws { catalog.selection = DanmakuTrackSelection(); catalog.beginMedia(channel?.id ?? ""); try await useSource() }
    func remember(result: NativeDanmakuCatalogResult, episode: NativeDanmakuCatalogEpisode) {
        guard let channel else { return }
        let key = "danmaku.manual." + (channel.historyContext?.id ?? channel.id) + "|" + (channel.historyContext?.episodeID ?? channel.id)
        if let data = try? JSONEncoder().encode(["api": result.source.address ?? "", "episode": episode.id,
            "title": result.title, "sourceID": result.source.id, "builtin": result.source.isBuiltin ? "1" : "0"]) {
            UserDefaults.standard.set(data, forKey: key)
        }
        // The per-episode record above cannot help the next episode. Remember the
        // choice per show as well - which source and which anime served it - so
        // automatic matching tries that pairing first, the way WebHTV's
        // danmaku_source_for_<name> memory prefers a remembered source.
        let showKey = "danmaku.show." + (channel.historyContext?.id ?? channel.id)
        if let data = try? JSONEncoder().encode(["sourceID": result.source.id,
            "animeTitle": result.title, "animeID": result.animeID ?? ""]) {
            UserDefaults.standard.set(data, forKey: showKey)
        }
    }
    private struct ShowDanmakuMemory { let sourceID: String, animeTitle: String, animeID: String }
    private func showMemory(for context: PlaybackHistoryContext?) -> ShowDanmakuMemory? {
        guard let context else { return nil }
        guard let data = UserDefaults.standard.data(forKey: "danmaku.show." + context.id),
              let record = try? JSONDecoder().decode([String: String].self, from: data),
              let sourceID = record["sourceID"], !sourceID.isEmpty,
              let title = record["animeTitle"], !title.isEmpty else { return nil }
        return ShowDanmakuMemory(sourceID: sourceID, animeTitle: title, animeID: record["animeID"] ?? "")
    }
    /// The remembered pairing for this show, tried before the full source sweep:
    /// search only the remembered source, take the remembered anime, and match
    /// this episode by number. Any miss falls through to the normal matching.
    private func matchRememberedShow(service: NativeDanmakuCatalog, context: PlaybackHistoryContext, generation active: UUID) async -> Bool {
        guard let memory = showMemory(for: context) else { return false }
        guard let source = await service.sources().first(where: { $0.id == memory.sourceID }),
              NativeDanmakuCatalog.isEnabled(source) else { return false }
        func current() -> Bool { active == generation && !Task.isCancelled && catalog.enabled && !catalog.selection.hasExplicitChoice }
        do {
            let results = try await service.search(context.videoName, source: source)
            guard current() else { return false }
            let remembered = results.first { result in
                (!memory.animeID.isEmpty && result.animeID == memory.animeID) ||
                CatalogDanmakuMatcher.normalized(result.title) == CatalogDanmakuMatcher.normalized(memory.animeTitle)
            }
            guard let result = remembered, let number = CatalogDanmakuMatcher.episodeNumber(context.episodeName) else { return false }
            let episodes = try await service.episodes(result)
            guard current() else { return false }
            let matched = episodes.filter { CatalogDanmakuMatcher.episodeNumber($0.title) == number }
            guard matched.count == 1, let episode = matched.first else { return false }
            let parameters = try await service.prepareParameters(episode, result: result)
            guard current() else { return false }
            catalog.sourceSelected()
            let count = try await prepare(parameters, manual: false, source: source)
            guard current() else { return false }
            if count > 0 { setStatus("已按上次来源匹配弹幕 · \(count) 条", kind: .success); return true }
        } catch {
            // A stale memory must never block the normal matching below, but the
            // failure itself is worth one diagnostics line before falling through.
            noteCatalogFailure(error, source: source, step: "remembered")
        }
        return false
    }

    func importFile(_ url: URL) async throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 32 * 1024 * 1024 else { throw TVError.unsupported("弹幕文件超过 32 MB") }
        try await importData(Data(contentsOf: url))
    }
    func importData(_ data: Data) async throws {
        guard data.count <= 32 * 1024 * 1024 else { throw TVError.unsupported("弹幕文件超过 32 MB") }
        try await prepare(["data": .string(data.base64EncodedString())], manual: true)
    }
    @discardableResult private func prepare(_ input: [String: JSONValue], manual: Bool, source: NativeDanmakuCatalogSource? = nil) async throws -> Int {
        guard ready else { throw TVError.unsupported("播放器尚未准备完成") }
        let previousSelection = catalog.selection
        if manual { catalog.selection.select(.manual) }
        let ticket = catalog.selection.ticket, active = generation
        let builtin = source?.isBuiltin ?? (!manual && usesBuiltinSource)
        func current() -> Bool {
            active == generation && ready && catalog.enabled && !Task.isCancelled &&
            catalog.selection.accepts(ticket, origin: manual ? .manual : .source) &&
            (source.map { NativeDanmakuCatalog.isEnabled($0) } ?? (!builtin || LocalDanmakuPreferences.builtinEnabled()))
        }
        var committed = false
        var params = serviceParams; params.merge(input) { _, new in new }
        do {
            guard current() else { throw CancellationError() }
            // The service replaces its single document during danmaku.prepare.
            // From this point an old index cannot safely be restored under its old
            // identity. Retire that native track before starting the replacement.
            var emptySelection = previousSelection
            if manual { emptySelection.select(.cleared) }
            if let source { pendingCatalogSelection = (source, emptySelection) }
            else { pendingCatalogSelection = nil }
            selectedCatalogSource = nil; usesBuiltinSource = false
            comments = []; rawLiveComments = []; indexed = false; nativeManual = false
            revision = UUID(); sourceRevision = UUID()
            setStatus(manual ? "正在加载所选弹幕" : "正在加载订阅弹幕")
            _ = try await MobileMediaServices.call("live.stop", params)
            guard current() else { throw CancellationError() }
            isLive = false
            let prepared = try await MobileMediaServices.call("danmaku.prepare", params)
            guard current() else { throw CancellationError() }
            // Commit the track and its source together before fetching the first window.
            // Later callbacks may validate the transaction, but never restore its identity.
            selectedCatalogSource = source; usesBuiltinSource = builtin; pendingCatalogSelection = nil
            nativeManual = manual; indexed = true; isLive = false; lastWindow = -1000; comments = []; rawLiveComments = []; revision = UUID(); sourceRevision = UUID()
            committed = true
            let count = prepared.object?["count"]?.int ?? 0
            setStatus(count > 0 ? (manual ? "已选择弹幕" : "已加载订阅弹幕") + " · \(count) 条" : "所选来源没有返回弹幕",
                      kind: count > 0 ? .success : .information)
            await tick()
            guard current() else { throw CancellationError() }
            return count
        } catch {
            if !committed, active == generation, catalog.selection.ticket == ticket {
                if manual { catalog.selection.select(.cleared) }
                else { catalog.selection = previousSelection }
                selectedCatalogSource = nil; usesBuiltinSource = false; pendingCatalogSelection = nil
                if !(error is CancellationError) { setStatus("弹幕加载失败，可在弹幕面板重试", kind: .warning) }
            }
            throw error
        }
    }
    func tick() async {
        guard ready, !busy, catalog.enabled else { return }
        #if os(iOS)
        let position = engine?.displayPosition ?? player?.currentTime().seconds ?? .nan
        let timeline = engine?.timelineRevision
        let seeking = engine?.seeking == true
        let speed = Double(engine?.speed ?? player?.rate ?? 1)
        #else
        let position = player?.currentTime().seconds ?? .nan
        let timeline: Int? = nil
        let seeking = false
        let speed = Double(player?.rate ?? 1)
        #endif
        let active = generation, ticket = catalog.selection.ticket
        busy = true; defer { if active == generation { busy = false } }
        guard position.isFinite, !seeking else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = lastSampleWall > 0 ? max(0, now - lastSampleWall) : 0
        do {
            let timelineChanged = timeline.map { lastTimelineRevision >= 0 && $0 != lastTimelineRevision } ?? false
            let clockJump = timeline == nil && lastPosition >= 0 &&
                (position < lastPosition - 1 || position > lastPosition + max(5, (elapsed + 1) * max(1, speed)))
            if timelineChanged || clockJump {
                timelineVersion += 1
                lastWindow = -1000
                _ = try await MobileMediaServices.call("session.set", sessionDefinition())
                guard active == generation, catalog.selection.ticket == ticket else { return }
                #if os(iOS)
                guard engine?.timelineRevision == timeline, engine?.seeking != true else { return }
                #endif
            }
            if let timeline { lastTimelineRevision = timeline }
            lastPosition = position; lastSampleWall = now
            if catalog.selection.origin == .cleared {
                comments = []; rawLiveComments = []; indexed = false
                if isLive {
                    _ = try await MobileMediaServices.call("live.stop", serviceParams)
                    guard active == generation, catalog.selection.ticket == ticket else { return }
                    isLive = false
                }
                return
            }
            if catalog.selection.origin == .manual && !nativeManual { comments = []; rawLiveComments = []; return }
            if isLive {
                let offset = catalog.offset
                if offset != lastOffset {
                    comments = rawLiveComments.map {
                        Danmaku(time: max(0, $0.time + offset), position: $0.position, color: $0.color,
                                scale: $0.scale, text: $0.text, effect: $0.effect)
                    }
                    lastOffset = offset; revision = UUID(); sourceRevision = UUID()
                }
                if catalog.enabled != liveEnabled, let live = descriptor?.live {
                    var input = serviceParams; input["descriptor"] = live; input["baseURL"] = .string(descriptor?.baseURL ?? ""); input["enabled"] = .bool(catalog.enabled)
                    _ = try await MobileMediaServices.call("live.start", input)
                    guard active == generation, catalog.selection.ticket == ticket else { return }
                    liveEnabled = catalog.enabled
                }
                let result = try await MobileMediaServices.call("live.poll", serviceParams)
                guard active == generation, catalog.selection.ticket == ticket else { return }
                if !catalog.enabled { return }
                for event in result.object?["events"]?.array ?? [] {
                    let value = event.object?["value"]?.object ?? [:]
                    guard value["sessionId"]?.string == sessionID, value["mediaVersion"]?.int ?? 0 == mediaVersion else { continue }
                    if event.object?["type"]?.string == "live-danmaku" {
                        if let sequence = value["sequence"]?.int {
                            guard sequence > liveSequence else { continue }
                            liveSequence = sequence
                        }
                        let incoming = (value["comments"]?.array ?? []).compactMap { item -> Danmaku? in
                            // live.poll drains its events. Preserve them in the offset snapshot
                            // used by the existing batch; a setting changed during await is
                            // applied to all comments exactly once on the following tick.
                            guard let value = NativeDanmakuDecoder.comment(item, time: max(0, position)) else { return nil }
                            return Danmaku(time: max(0, position), position: value.position,
                                           color: value.color, scale: value.scale, text: value.text, effect: value.effect)
                        }
                        guard !incoming.isEmpty else { continue }
                        rawLiveComments.append(contentsOf: incoming)
                        // Keep the arrival media timestamp. Retiming a previously clamped zero
                        // would lose its original time and move it into the future on a roundtrip.
                        rawLiveComments.removeAll { $0.time < position - 20 }
                        if rawLiveComments.count > 1500 { rawLiveComments.removeFirst(rawLiveComments.count - 1500) }
                        comments = rawLiveComments.map {
                            Danmaku(time: max(0, $0.time + offset), position: $0.position, color: $0.color,
                                    scale: $0.scale, text: $0.text, effect: $0.effect)
                        }
                        revision = UUID()
                    } else if event.object?["type"]?.string == "live-danmaku-state" {
                        switch value["phase"]?.string {
                        case "connecting": setStatus("正在连接实时弹幕")
                        case "reconnecting": setStatus("实时弹幕连接中断，正在重连", kind: .warning)
                        case "live": setStatus("实时弹幕已连接", kind: .success)
                        case "disabled": setStatus("实时弹幕已关闭")
                        case "error": setStatus("实时弹幕连接失败，可在弹幕面板重试", kind: .warning)
                        default: break
                        }
                    }
                }
            } else if indexed && (abs(position - lastWindow) > 15 || catalog.offset != lastOffset) {
                let offset = catalog.offset
                var params = serviceParams; params["position"] = .number(max(0, position - offset)); params["duration"] = .number(90)
                let result = try await MobileMediaServices.call("danmaku.window", params)
                guard active == generation, catalog.selection.ticket == ticket, catalog.offset == offset else { return }
                #if os(iOS)
                guard engine?.timelineRevision == timeline, engine?.seeking != true else { return }
                #endif
                let incoming = (result.object?["items"]?.array ?? []).compactMap { NativeDanmakuDecoder.comment($0) }.map {
                    Danmaku(time: max(0, $0.time + offset), position: $0.position, color: $0.color, scale: $0.scale, text: $0.text, effect: $0.effect)
                }
                let retimed = lastOffset != offset
                if incoming != comments || retimed {
                    comments = incoming; revision = UUID()
                    if retimed { sourceRevision = UUID() }
                }
                lastWindow = position; lastOffset = offset
            }
        } catch {
            if active == generation, catalog.selection.ticket == ticket, !Task.isCancelled {
                setStatus(isLive ? "实时弹幕暂不可用，正在等待连接恢复" : "弹幕窗口加载失败，将重试", kind: .warning)
            }
        }
    }
}
