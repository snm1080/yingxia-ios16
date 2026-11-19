import Foundation
import Perception
import AVFoundation
import TVCore

/// The failure half of a `danmaku.api` diagnostics line. An HTTP refusal must be
/// matched before any NSError bridging: bridged, TVError.http(401) and
/// TVError.http(503) share one domain and an enum ordinal, so the status code -
/// the one fact that separates "fix the address" from "wait and retry" - is lost.
func danmakuFailureDetail(_ error: Error) -> String {
    if case TVError.http(let code) = error { return "http:\(code)" }
    let failure = error as NSError
    return "\(failure.domain):\(failure.code)"
}

/// The errors a load can end with when it was not answered but replaced:
/// the Swift task was cancelled, the loopback request was cancelled under
/// it, or the Node service answered that the playing media or the danmaku
/// selection had already changed - its text crosses the bridge inside
/// TVError.unsupported (a stack string, so the phrases are matched as
/// substrings). A superseded load is not a failure: wherever the automatic
/// flow would otherwise record one, it ends silently instead, exactly the
/// way a CancellationError does.
func danmakuIsSuperseded(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if let urlError = error as? URLError, urlError.code == .cancelled { return true }
    let bridged = error as NSError
    if bridged.domain == NSURLErrorDomain, bridged.code == NSURLErrorCancelled { return true }
    if case TVError.unsupported(let message) = error {
        return ["播放媒体已改变", "播放媒体或弹幕选择已改变", "弹幕操作已取消", "操作已取消",
                "This operation was aborted"].contains { message.contains($0) }
    }
    return false
}

@MainActor @Perceptible final class NativeMediaEnhancements {
    private(set) var comments: [Danmaku] = []
    private(set) var revision = UUID()
    /// Stable across window refreshes and live batches; only replacing/retiming a track resets its sprites.
    private(set) var sourceRevision = UUID()
    private(set) var status = ""
    private(set) var notice: PlayerNotice?
    /// The automatic flow's one on-screen word: a single capsule at the
    /// bottom of the picture, published only when a load reaches its
    /// outcome. The panel keeps reading `status` exactly as before;
    /// progress states and the panel's detailed wordings never reach
    /// the picture.
    private(set) var matchBanner: PlayerNotice?
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
    private func setStatus(_ message: String, kind: PlayerNotice.Kind = .information, onScreen: Bool = true) {
        guard status != message || notice == nil else { return }
        status = message
        if onScreen { notice = message.isEmpty ? nil : PlayerNotice(message: message, kind: kind) }
    }
    private func showMatchBanner(_ message: String, detail: String? = nil, kind: PlayerNotice.Kind = .success) {
        matchBanner = PlayerNotice(message: message, kind: kind, detail: detail)
    }
    /// The banner's two lines, split at the seam a narrow portrait frame
    /// needs: "匹配到弹幕：{剧名} ({年份})【{类型}】" on the first line and
    /// "from {来源}【{标识}】第 {集数} 集" on the second — as one line the
    /// whole string truncated long titles away. Aggregate titles arrive
    /// already decorated ("大炎双雄(2026)【短剧】from hongguo") and are split
    /// back into their parts; a plain title falls back to the raw record's
    /// year/type and then the playing context's year. Any part the match
    /// does not carry is simply left out, and a second line with nothing
    /// in it is omitted whole.
    private func matchBannerLines(title: String, year: String?, category: String?, platform: String?,
                                  sourceName: String?, sourceIdentifier: String?, episodeNumber: Int?) -> (headline: String, detail: String?) {
        var headline = "匹配到弹幕：\(title)"
        if let year, !year.isEmpty { headline += " (\(year))" }
        if let category, !category.isEmpty { headline += "【\(category)】" }
        var detail = ""
        if let platform, !platform.isEmpty { detail += "from \(platform)" }
        else if let sourceName, !sourceName.isEmpty { detail += "from \(sourceName)" }
        if let sourceIdentifier, !sourceIdentifier.isEmpty { detail += "【\(sourceIdentifier)】" }
        if let episodeNumber { detail += detail.isEmpty ? "第 \(episodeNumber) 集" : " 第 \(episodeNumber) 集" }
        return (headline, detail.isEmpty ? nil : detail)
    }
    /// The second line with the loaded count riding at its end; the count
    /// stands alone on the line when the match carried nothing else to put
    /// there, and the line stays absent for a zero count with no segments.
    private func bannerDetail(_ detail: String?, count: Int) -> String? {
        guard count > 0 else { return detail }
        return detail.map { $0 + " · 已加载 \(count) 条弹幕" } ?? "已加载 \(count) 条弹幕"
    }
    private func matchBannerLines(result: NativeDanmakuCatalogResult, episodeNumber: Int?) -> (headline: String, detail: String?) {
        var title = result.title, year: String?, category: String?, platform: String?
        let pattern = #"^(.+?)\((\d{4})\)【([^】]+)】from\s+(\S+)$"#
        if let expression = try? NSRegularExpression(pattern: pattern),
           let match = expression.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) {
            let text = title as NSString
            title = text.substring(with: match.range(at: 1)); year = text.substring(with: match.range(at: 2))
            category = text.substring(with: match.range(at: 3)); platform = text.substring(with: match.range(at: 4))
        }
        if year == nil {
            let raw = result.raw.object
            if let value = raw?["year"]?.string ?? raw?["year"]?.int.map({ String($0) }), !value.isEmpty { year = value }
            else if let start = raw?["startDate"]?.string, start.count >= 4, start.prefix(4).allSatisfy(\.isNumber) { year = String(start.prefix(4)) }
            else { year = catalog.context?.year }
        }
        if category == nil {
            let raw = result.raw.object
            category = raw?["typeDescription"]?.string ?? raw?["type"]?.string
        }
        // A custom API's id is a UUID - an internal key, not a name worth
        // printing. A short non-UUID id is a real identifier; aggregate
        // results fall back to the source's name, the way MiraPlay repeats it.
        let identifier: String?
        if UUID(uuidString: result.source.id) == nil, !result.source.id.isEmpty { identifier = result.source.id }
        else if platform != nil { identifier = result.source.name }
        else { identifier = nil }
        return matchBannerLines(title: title, year: year, category: category, platform: platform,
                                sourceName: result.source.name, sourceIdentifier: identifier, episodeNumber: episodeNumber)
    }
    /// The lines for loads that carry no catalog result (the playing source's
    /// own feed, the builtin feed, pushed comments): the playing work's name
    /// and episode, nothing else is honestly available.
    private func contextMatchBannerLines() -> (headline: String, detail: String?)? {
        guard let context = channel?.historyContext ?? catalog.context else { return nil }
        return matchBannerLines(title: context.videoName, year: context.year, category: nil, platform: nil,
                                sourceName: nil, sourceIdentifier: nil,
                                episodeNumber: CatalogDanmakuMatcher.episodeNumber(context.episodeName))
    }
    private func announceContextMatch(count: Int) {
        guard let lines = contextMatchBannerLines() else { return }
        showMatchBanner(lines.headline, detail: bannerDetail(lines.detail, count: count),
                        kind: count > 0 ? .success : .information)
    }
    func sourceLoaded(count: Int) {
        guard !catalog.selection.hasExplicitChoice else { return }
        setStatus(count > 0 ? "已加载订阅弹幕 · \(count) 条" : "订阅没有返回弹幕",
                  kind: count > 0 ? .success : .information, onScreen: false)
        announceContextMatch(count: count)
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
        setStatus(catalog.enabled ? "正在准备弹幕" : "弹幕已关闭", onScreen: false)
        let active = generation
        loading = Task { [weak self] in
            guard let self else { return }
            // Set when this flow turns out to have been replaced rather
            // than answered; the end of the task leaves it one diagnostics
            // line instead of the failure it used to be mistaken for.
            var superseded = false
            do {
                // Rapid switching used to start a full load for every
                // episode it passed through, and each abandoned fetch kept
                // the single Node session busy long after the switch -
                // crowding the landing episode's own load into a genuine
                // timeout that then read as a fetch failure. So the flow
                // first waits out a short settle window: a begin that is
                // itself replaced inside it ends here, before it has asked
                // the service for anything at all.
                try await Task.sleep(nanoseconds: 400_000_000)
                guard active == self.generation else { throw CancellationError() }
                _ = try await MobileMediaServices.call("session.set", self.sessionDefinition())
                guard active == self.generation else { throw CancellationError() }
                try await LocalMediaServiceSettings.apply()
                guard active == self.generation else { throw CancellationError() }
                self.ready = true
                guard self.catalog.enabled else { return }
                if let saved = self.rememberedFeed(), let source = self.selectedCatalogSource {
                    do { try await self.prepareRemembered(saved, source: source) }
                    catch {
                        if active != self.generation || Task.isCancelled || danmakuIsSuperseded(error) {
                            superseded = true
                        } else {
                            // The remembered feed is the one path whose failure used to
                            // leave no trace anywhere; record it before the outer catch
                            // turns it into the generic unavailable message.
                            self.noteCatalogFailure(error, source: source, step: "rememberedFeed")
                            // One transient failure on the remembered feed must not be
                            // the end of danmaku for this episode: fall back to the
                            // automatic sweep, the same way a stale per-show memory
                            // falls through in matchRememberedShow. This runs at most
                            // once - the sweep never re-enters the remembered feed.
                            self.setStatus("记住的弹幕来源加载失败，正在改走自动匹配", kind: .warning, onScreen: false)
                            await self.matchCatalogAutomatically()
                            // Keep the two halves of the story distinguishable when the
                            // sweep also comes up empty; a success speaks for itself.
                            // The banner is the sweep's own outcome and stands as-is.
                            if self.status == "没有匹配到本集弹幕，可在弹幕面板选择来源" {
                                self.setStatus("记住的来源加载失败，自动匹配也没有找到本集弹幕，可在弹幕面板选择来源", kind: .warning, onScreen: false)
                            } else if self.status.hasPrefix("弹幕获取失败") || self.status.hasPrefix("弹幕 API 未授权") {
                                self.setStatus("记住的来源加载失败；" + self.status, kind: .warning, onScreen: false)
                            }
                        }
                    }
                } else if self.descriptor != nil, LocalDanmakuPreferences.builtinEnabled() { try await self.useSource() }
                else { await self.matchCatalogAutomatically() }
            } catch {
                if active == self.generation, !Task.isCancelled, !danmakuIsSuperseded(error) {
                    self.setStatus("弹幕服务暂不可用，可在弹幕面板重试", kind: .warning, onScreen: false)
                    self.showMatchBanner("弹幕加载失败", kind: .warning)
                } else { superseded = true }
            }
            if superseded || active != self.generation || Task.isCancelled {
                Diagnostics.shared.record(.info, "danmaku.api", "step=auto outcome=superseded")
            }
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
            } catch {
                if !Task.isCancelled, !danmakuIsSuperseded(error) {
                    self.setStatus("弹幕加载失败，可在弹幕面板重试", kind: .warning, onScreen: false)
                    self.showMatchBanner("弹幕加载失败", kind: .warning)
                }
            }
        }
    }
    /// One diagnostics line per failed catalog step, so a screenshot of
    /// 设置 → 关于 → 诊断 shows which source and step failed and how.
    private func noteCatalogFailure(_ error: Error, source: NativeDanmakuCatalogSource, step: String) {
        Diagnostics.shared.record(.info, "danmaku.api", "source=\(source.name) step=\(step) failed=\(danmakuFailureDetail(error))")
    }
    private func matchCatalogAutomatically() async {
        guard catalog.enabled, !catalog.selection.hasExplicitChoice else { return }
        guard catalog.automatic else { setStatus("自动匹配弹幕已关闭", onScreen: false); return }
        guard let context = catalog.context else { setStatus("当前媒体没有可匹配的弹幕信息", onScreen: false); return }
        let active = generation
        setStatus("正在自动匹配订阅弹幕", onScreen: false)
        var failed = false
        var unauthorized = false
        // The banner lines of the first episode that matched but had no
        // comments, kept so the final banner can still name what was matched.
        var matchedLines: (headline: String, detail: String?)?
        // Set when a source matched this episode and its comment load
        // succeeded but returned zero comments: the episode exists, it
        // simply has no danmaku. That is a different fact from "no match"
        // and from a fetch failure, and the final message keeps them apart.
        var matchedEmpty = false
        // The final message is classified from evidence, not from a single
        // accumulated error flag: `answered` records that at least one
        // source completed a step - an answer of "nothing found" is still
        // an answer - and `loadFailed` that a matched episode's load step
        // (or the builtin feed's prepare) hit a real error. One source's
        // failure must not relabel every other source's successful answer.
        var answered = false
        var loadFailed = false
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
                if count > 0 { setStatus("订阅已自动推送弹幕 · \(count) 条", kind: .success, onScreen: false) }
                announceContextMatch(count: count)
                return
            } catch {
                if active != generation || Task.isCancelled || catalog.selection.hasExplicitChoice || danmakuIsSuperseded(error) { return }
                failed = true
                // The pushed comments were in hand and failed to load:
                // that is a load error, whatever the sweep finds later.
                loadFailed = true
            }
        }
        let service = NativeDanmakuCatalog(context: context)
        switch await matchRememberedShow(service: service, context: context, generation: active) {
        case .loaded: return
        case .matchedEmpty(let headline, let detail): matchedEmpty = true; answered = true; matchedLines = (headline, detail)
        case .missed: break
        }
        for source in await service.sources() {
            guard active == generation, !Task.isCancelled, catalog.enabled, !catalog.selection.hasExplicitChoice else { return }
            do {
                let results = try await service.search(context.videoName, source: source)
                answered = true
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
                        if count > 0 {
                            setStatus("已自动匹配弹幕 · \(count) 条", kind: .success, onScreen: false)
                            let lines = matchBannerLines(result: result, episodeNumber: number)
                            showMatchBanner(lines.headline, detail: bannerDetail(lines.detail, count: count))
                            return
                        }
                        // Matched and loaded, but zero comments on this
                        // source. Keep sweeping - another source may have
                        // some - and remember the fact for the final message.
                        matchedEmpty = true
                        if matchedLines == nil { matchedLines = matchBannerLines(result: result, episodeNumber: number) }
                    } catch {
                        if active != generation || Task.isCancelled || catalog.selection.hasExplicitChoice || danmakuIsSuperseded(error) { return }
                        failed = true
                        // The match was in hand; a step on the way to its
                        // comments failed for real. That keeps the final
                        // message in fetch-failure territory even if other
                        // sources answered cleanly with nothing.
                        loadFailed = true
                        noteCatalogFailure(error, source: source, step: "prepare")
                        if case TVError.http(let code) = error, code == 401 || code == 403 { unauthorized = true }
                    }
                }
            } catch {
                if active != generation || Task.isCancelled || catalog.selection.hasExplicitChoice || danmakuIsSuperseded(error) { return }
                failed = true
                noteCatalogFailure(error, source: source, step: "search")
                if case TVError.http(let code) = error, code == 401 || code == 403 { unauthorized = true }
            }
        }
        guard active == generation, !Task.isCancelled, catalog.enabled, !catalog.selection.hasExplicitChoice else { return }
        // A self-hosted API that gates on a token in its address path answers
        // every step with 401; calling that a generic fetch failure sends the
        // viewer hunting in the wrong place, so name the actual problem.
        // Below that, "fetch failed" is reserved for the cases where it is
        // literally true: a matched episode whose load step errored, or
        // every source erroring without a single successful answer. A
        // source that answered "nothing found" settles the outcome as a
        // miss, and a matched episode with zero comments is its own answer.
        // The panel keeps the detailed wording below; the picture gets one
        // banner: the failure word, the matched line, or the miss word.
        if unauthorized {
            setStatus("弹幕 API 未授权（401）：请检查 API 地址是否带 token", kind: .warning, onScreen: false)
            showMatchBanner("弹幕加载失败", kind: .warning)
        } else if loadFailed || (failed && !answered) {
            setStatus("弹幕获取失败，可在弹幕面板重试", kind: .warning, onScreen: false)
            showMatchBanner("弹幕加载失败", kind: .warning)
        } else if matchedEmpty {
            setStatus("本集没有弹幕，可在弹幕面板选择来源", kind: .information, onScreen: false)
            if let matchedLines { showMatchBanner(matchedLines.headline, detail: matchedLines.detail, kind: .information) }
        } else {
            setStatus("没有匹配到本集弹幕，可在弹幕面板选择来源", kind: .information, onScreen: false)
            showMatchBanner("没有匹配到本集弹幕", kind: .information)
        }
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
            let count = try await prepare(parameters, manual: true, source: result.source)
            // A hand-picked load shares the picture with the automatic flow,
            // so its outcome takes the same single banner.
            let lines = matchBannerLines(result: result, episodeNumber: CatalogDanmakuMatcher.episodeNumber(episode.title))
            showMatchBanner(lines.headline, detail: bannerDetail(lines.detail, count: count),
                            kind: count > 0 ? .success : .information)
        } catch {
            if scope == generation, catalog.selection.ticket == ticket {
                catalog.selection = previous
                pendingCatalogSelection = nil
            }
            if !danmakuIsSuperseded(error) { showMatchBanner("弹幕加载失败", kind: .warning) }
            throw error
        }
    }
    private func prepareRemembered(_ url: String, source: NativeDanmakuCatalogSource) async throws {
        let ticket = catalog.selection.ticket, scope = generation
        guard ready, catalog.enabled, !Task.isCancelled, !catalog.selection.hasExplicitChoice,
              NativeDanmakuCatalog.isEnabled(source) else { throw CancellationError() }
        let count: Int
        if let address = URL(string: url), address.host == "api.dandanplay.net" {
            let values = try await CatalogDanmakuClient().comments(CatalogDanmakuEpisode(id: address.lastPathComponent, title: "已选择分集"))
            guard scope == generation, catalog.selection.ticket == ticket, ready, catalog.enabled,
                  !Task.isCancelled, NativeDanmakuCatalog.isEnabled(source) else { throw CancellationError() }
            let normalized: JSONValue = .array(values.map { value -> JSONValue in .object(["time": .number(value.time), "mode": .number(Double(value.mode.rawValue)), "color": .number(Double(value.color)), "text": .string(value.text)]) })
            count = try await prepare(["text": .string(String(data: try JSONEncoder().encode(normalized), encoding: .utf8)!)], manual: true, source: source)
        } else {
            count = try await prepare(["url": .string(url)], manual: true, source: source)
        }
        // The remembered feed is a match like any other: name it in the banner
        // from the record's title and the source it came from.
        if let context = channel?.historyContext ?? catalog.context {
            let identifier: String? = UUID(uuidString: source.id) == nil && !source.id.isEmpty ? source.id : nil
            let lines = matchBannerLines(title: rememberedTitle ?? context.videoName, year: context.year, category: nil,
                                         platform: nil, sourceName: source.name, sourceIdentifier: identifier,
                                         episodeNumber: CatalogDanmakuMatcher.episodeNumber(context.episodeName))
            showMatchBanner(lines.headline, detail: bannerDetail(lines.detail, count: count),
                            kind: count > 0 ? .success : .information)
        }
    }
    /// The anime title stored with the remembered feed, for the match banner.
    @PerceptionIgnored private var rememberedTitle: String?
    private func rememberedFeed() -> String? {
        guard let channel else { return nil }
        let key = "danmaku.manual." + (channel.historyContext?.id ?? channel.id) + "|" + (channel.historyContext?.episodeID ?? channel.id)
        guard let data = UserDefaults.standard.data(forKey: key), let record = try? JSONDecoder().decode([String: String].self, from: data),
              let address = record["api"], !address.isEmpty, let episode = record["episode"], let server = try? CatalogDanmakuClient(address: address).server else { return nil }
        rememberedTitle = record["title"]
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
        matchBanner = nil; rememberedTitle = nil
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
                setStatus("正在加载订阅弹幕", onScreen: false)
                await catalog.nativeSourceReload?()
                return
            }
            let count = try await prepare(["url": .string(feed), "headers": .object(descriptor.headers.mapValues(JSONValue.string))], manual: false)
            announceContextMatch(count: count)
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
    private enum RememberedShowOutcome { case loaded, matchedEmpty(headline: String, detail: String?), missed }
    /// The remembered pairing for this show, tried before the full source sweep:
    /// search only the remembered source, take the remembered anime, and match
    /// this episode by number. Any miss falls through to the normal matching.
    /// A pairing that matches and loads but returns zero comments reports
    /// `.matchedEmpty` instead of a plain miss, so the caller's final message
    /// can say the episode has no danmaku rather than that nothing matched.
    private func matchRememberedShow(service: NativeDanmakuCatalog, context: PlaybackHistoryContext, generation active: UUID) async -> RememberedShowOutcome {
        guard let memory = showMemory(for: context) else { return .missed }
        guard let source = await service.sources().first(where: { $0.id == memory.sourceID }),
              NativeDanmakuCatalog.isEnabled(source) else { return .missed }
        func current() -> Bool { active == generation && !Task.isCancelled && catalog.enabled && !catalog.selection.hasExplicitChoice }
        do {
            let results = try await service.search(context.videoName, source: source)
            guard current() else { return .missed }
            let remembered = results.first { result in
                (!memory.animeID.isEmpty && result.animeID == memory.animeID) ||
                CatalogDanmakuMatcher.normalized(result.title) == CatalogDanmakuMatcher.normalized(memory.animeTitle)
            }
            guard let result = remembered, let number = CatalogDanmakuMatcher.episodeNumber(context.episodeName) else { return .missed }
            let episodes = try await service.episodes(result)
            guard current() else { return .missed }
            let matched = episodes.filter { CatalogDanmakuMatcher.episodeNumber($0.title) == number }
            guard matched.count == 1, let episode = matched.first else { return .missed }
            let parameters = try await service.prepareParameters(episode, result: result)
            guard current() else { return .missed }
            catalog.sourceSelected()
            let count = try await prepare(parameters, manual: false, source: source)
            guard current() else { return .missed }
            if count > 0 {
                setStatus("已按上次来源匹配弹幕 · \(count) 条", kind: .success, onScreen: false)
                let lines = matchBannerLines(result: result, episodeNumber: number)
                showMatchBanner(lines.headline, detail: bannerDetail(lines.detail, count: count))
                return .loaded
            }
            let lines = matchBannerLines(result: result, episodeNumber: number)
            return .matchedEmpty(headline: lines.headline, detail: lines.detail)
        } catch {
            // A superseded attempt is not a failure of the memory: fall
            // through as a plain miss without the failure line, and let
            // the caller's own guards stop the sweep.
            if danmakuIsSuperseded(error) { return .missed }
            // A stale memory must never block the normal matching below, but the
            // failure itself is worth one diagnostics line before falling through.
            noteCatalogFailure(error, source: source, step: "remembered")
        }
        return .missed
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
            // Progress never reaches the picture any more. The outcome of a
            // catalogued load is announced by its caller as the one banner;
            // only the direct paths that carry no match to name (a typed
            // address, an imported file) keep their closing toast below.
            let legacyScreen = manual && source == nil
            setStatus(manual ? "正在加载所选弹幕" : "正在加载订阅弹幕", onScreen: false)
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
                      kind: count > 0 ? .success : .information, onScreen: legacyScreen)
            await tick()
            guard current() else { throw CancellationError() }
            return count
        } catch {
            if !committed, active == generation, catalog.selection.ticket == ticket {
                if manual { catalog.selection.select(.cleared) }
                else { catalog.selection = previousSelection }
                selectedCatalogSource = nil; usesBuiltinSource = false; pendingCatalogSelection = nil
                if !danmakuIsSuperseded(error) { setStatus("弹幕加载失败，可在弹幕面板重试", kind: .warning, onScreen: manual && source == nil) }
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
