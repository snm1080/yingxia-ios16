#if os(iOS)
import Foundation
import Perception
import TVCore

/// Optional metadata/network work never blocks picture readiness or the local skip clock.
@MainActor @Perceptible final class NativeRemoteSkip {
    private(set) var segments: [RemoteEpisodeSkipSegment] = []
    private(set) var status = ""
    private(set) var notice: PlayerNotice?
    struct Action: Sendable {
        let id: UUID
        let target: Double
        let kind: String
        fileprivate let generation: UUID
    }
    @PerceptionIgnored private var pendingAction: UUID?
    @PerceptionIgnored private var panelRequested = false
    @PerceptionIgnored private var channel: Channel?
    @PerceptionIgnored private var live = false
    @PerceptionIgnored private var lookup = TMDBLookup()
    @PerceptionIgnored private var task: Task<Void, Never>?
    @PerceptionIgnored private var generation = UUID()
    @PerceptionIgnored private var input: Input?
    @PerceptionIgnored private var remote: [RemoteEpisodeSkipSegment] = []
    @PerceptionIgnored private var pass = RemoteEpisodeSkipPass()
    @PerceptionIgnored private var retryAt = Date.distantPast
    @PerceptionIgnored private var attempts = 0
    private struct Input: Equatable {
        let session: String
        let settings: EpisodeSkipSettings
        let duration: Double
        let chapters: [RemoteEpisodeSkipChapter]
    }
    /// Status text lives in the intro/outro panel only (CompactEpisodeSkipPanel
    /// shows `status`). The picture's notices are reserved for the result of an
    /// actual skip, emitted by complete() — matching, connection and fallback
    /// states never pop over the video (upstream build03 behaviour). The local
    /// segments are always merged in tick(), so a failed or unavailable remote
    /// lookup still skips with the local times and never blocks playback.
    private func setStatus(_ message: String) {
        status = message
    }

    func begin(channel: Channel, isLive: Bool) {
        stop(); self.channel = channel; live = isLive
    }
    func stop() {
        generation = UUID(); task?.cancel(); task = nil; input = nil
        remote = []; segments = []; status = ""; notice = nil; pendingAction = nil; panelRequested = false; channel = nil; lookup = TMDBLookup()
        pass = RemoteEpisodeSkipPass(); attempts = 0; retryAt = .distantPast
    }
    func requestMatch() { panelRequested = true }
    func settingsChanged() {
        generation = UUID(); task?.cancel(); task = nil; input = nil
        pendingAction = nil
        pass = RemoteEpisodeSkipPass(); lookup = TMDBLookup(); attempts = 0; retryAt = .distantPast
    }
    func tick(settings: EpisodeSkipSettings, duration: Double, chapters: [KSPlaybackChapter], sessionID: String, ready: Bool) {
        guard duration.isFinite, duration > 0, !live else { return }
        let chapters = chapters.map { RemoteEpisodeSkipChapter(time: $0.start, title: $0.title, end: $0.end) }
        let next = Input(session: sessionID, settings: settings, duration: duration.rounded(), chapters: chapters)
        if input != next {
            generation = UUID(); task?.cancel(); task = nil; input = next; lookup = TMDBLookup()
            pendingAction = nil
            remote = []; attempts = 0; retryAt = .distantPast
        }
        let local = RemoteEpisodeSkipPlan.local(settings: settings, duration: duration, chapters: chapters)
        segments = RemoteEpisodeSkipPlan.merging(local: local, remote: remote, duration: duration)
        guard settings.enabled || panelRequested else { setStatus("自动跳过已关闭"); return }
        guard !Set(local.map(\.kind)).isSuperset(of: ["opening", "ending"]) else { setStatus("已采用手动或章节片头片尾时间"); return }
        guard ready, !sessionID.isEmpty, task == nil, attempts < 2, Date() >= retryAt else { return }
        guard let context = channel?.historyContext, !TMDBMatch.skipsSource(key: context.sourceKey, api: "") else {
            setStatus(local.isEmpty ? "尚未识别作品，可手动记录片头片尾" : "已采用章节时间"); return
        }
        let active = generation
        attempts += 1
        setStatus("正在匹配片头片尾")
        task = Task { [weak self] in
            guard let self else { return }
            defer { if active == self.generation { self.task = nil } }
            do {
                guard let identity = try await self.identity(context) else {
                    guard active == self.generation, !Task.isCancelled else { return }
                    self.setStatus("作品或季集不明确，可手动记录片头片尾")
                    self.attempts = 2; return
                }
                guard active == self.generation, !Task.isCancelled else { return }
                let params: [String: JSONValue] = ["sessionId": .string(sessionID), "mediaVersion": .number(0),
                    "duration": .number(duration), "identity": .object(identity.identity), "metadata": .object(identity.metadata),
                    "preferences": .object(["openingOverride": .number(settings.introEnd), "endingOverride": .number(settings.outroLength)]),
                    "chapters": .array(chapters.map { chapter in
                        var row: [String: JSONValue] = ["time": .number(chapter.time), "title": .string(chapter.title)]
                        if let end = chapter.end { row["end"] = .number(end) }; return .object(row)
                    })]
                // The skip provider receives public IDs only; playback URLs, cookies and configured API keys stay local.
                let result = try await MobileMediaServices.call("intro.plan", params)
                guard active == self.generation, !Task.isCancelled else { return }
                let data = try JSONEncoder().encode(result.object?["segments"] ?? .array([]))
                let all = try JSONDecoder().decode([RemoteEpisodeSkipSegment].self, from: data)
                self.remote = all.filter { !["手动", "章节"].contains($0.source) }
                self.segments = RemoteEpisodeSkipPlan.merging(local: local, remote: self.remote, duration: duration)
                let message = result.object?["message"]?.string ?? ""
                self.setStatus(self.remote.isEmpty ? (message.isEmpty ? "没有匹配的远程片段，已保留本地时间" : message) : "已匹配片头片尾 · " + Array(Set(self.remote.map(\.source))).sorted().joined(separator: " / "))
                if result.object?["retryable"] == .bool(true) {
                    self.retryAt = Date().addingTimeInterval(15)
                    self.setStatus(self.attempts < 2 ? "部分在线信息暂不可用，稍后重试；已保留可用时间" : "在线匹配暂不可用，已保留可用时间")
                } else { self.attempts = 2 }
            } catch {
                guard active == self.generation, !Task.isCancelled else { return }
                self.setStatus("在线匹配暂不可用，已保留本地时间")
                self.retryAt = Date().addingTimeInterval(15)
            }
        }
    }
    func target(time: Double, duration: Double, playing: Bool, enabled: Bool) -> Double? {
        pass.target(time: time, duration: duration, playing: playing, enabled: enabled, segments: segments)
    }
    func nextAction(time: Double, duration: Double, playing: Bool, enabled: Bool) -> Action? {
        guard pendingAction == nil,
              let target = pass.target(time: time, duration: duration, playing: playing, enabled: enabled, segments: segments),
              let segment = segments.first(where: { time >= $0.start && time < $0.end && abs(min($0.end, duration - 0.05) - target) < 0.1 }) else { return nil }
        let action = Action(id: UUID(), target: target, kind: segment.kind, generation: generation)
        pendingAction = action.id
        return action
    }
    func complete(_ action: Action, succeeded: Bool) {
        guard action.generation == generation, pendingAction == action.id else { return }
        pendingAction = nil
        let name = action.kind == "ending" ? "片尾" : "片头"
        // Emit only after the actual native seek callback, never when a plan chooses a target.
        notice = PlayerNotice(message: succeeded ? "已自动跳过" + name : "自动跳过" + name + "失败，可手动重试",
                              kind: succeeded ? .success : .warning)
    }

    private func identity(_ context: PlaybackHistoryContext) async throws -> (identity: [String: JSONValue], metadata: [String: JSONValue])? {
        let lookup = self.lookup
        let key = TMDBMatchStore.key(source: context.sourceKey, video: context.videoID)
        if !(await lookup.prepare(key: key)) {
            let video = Video(id: context.videoID, name: context.videoName, year: context.year,
                episodes: [Episode(id: context.episodeID, name: context.episodeName, address: "", flag: context.episodeFlag)])
            // Omit SourceRef: this is an identity lookup, not a submission of a source/URL association.
            await lookup.run(key: key, request: TMDBMatch.Request(video: video))
        }
        try Task.checkCancellation()
        if lookup.phase == .failed { throw TVError.unsupported("作品信息暂不可用") }
        guard let details = lookup.details, details.id > 0, lookup.phase == .matched,
              !LocalDetailEpisodeNumbers.isExtra(context.episodeName) else { return nil }
        var result: [String: JSONValue] = ["tmdbId": .number(Double(details.id)), "mediaType": .string(details.mediaType.rawValue)]
        if details.mediaType == .tv {
            let explicit = LocalDetailEpisodeNumbers.numbers(context.episodeName)
            let inferred = LocalDetailEpisodeNumbers.numbers(context.episodeFlag + " " + context.videoName)
            let seasons = details.seasons.filter { $0.number > 0 }
            let selected = lookup.chosen ? details.season?.number : nil
            let season = selected ?? explicit.season ?? inferred.season ?? (seasons.count == 1 && seasons[0].number == 1 ? 1 : nil)
            guard let season, season > 0, explicit.season == nil || explicit.season == season,
                  let known = seasons.first(where: { $0.number == season }), let rawEpisode = explicit.episode else { return nil }
            var episode = rawEpisode + lookup.offset
            if lookup.numbering == .absolute {
                let previous = seasons.filter { $0.number < season }
                guard previous.count == season - 1, previous.allSatisfy({ $0.episodeCount > 0 }) else { return nil }
                episode -= previous.reduce(0) { $0 + $1.episodeCount }
            }
            guard episode > 0, known.episodeCount == 0 || episode <= known.episodeCount else { return nil }
            result["season"] = .number(Double(season)); result["episode"] = .number(Double(episode))
        }
        var metadata: [String: JSONValue] = [:]
        if let trailer = details.trailer, trailer.site == "IMDb", trailer.key.range(of: #"^tt\d+$"#, options: .regularExpression) != nil {
            metadata["imdbId"] = .string(trailer.key)
        }
        return (result, metadata)
    }
}
#endif
