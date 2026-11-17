#if os(iOS)
import Foundation
import Perception
import TVCore

/// Explicit per-playback controls, matching MacCat's generation and translation switches.
/// Results use an independent overlay; importing/selecting a manual subtitle never gets overwritten.
@MainActor @Perceptible final class NativeAISubtitles {
    private(set) var generate = false
    private(set) var translate = false
    private(set) var busy = false
    private(set) var status = "AI 字幕已关闭"
    private(set) var lines: [String] = []
    @PerceptionIgnored private weak var session: PlaybackSession?
    @PerceptionIgnored private var work: Task<Void, Never>?
    @PerceptionIgnored private var epoch = UUID()
    @PerceptionIgnored private var scope: AISubtitleScope?
    @PerceptionIgnored private var previousPosition: Double?
    @PerceptionIgnored private var previousTime = Date()
    @PerceptionIgnored private var generated: [AISubtitleTimeline.Cue] = []
    @PerceptionIgnored private var translated: [AISubtitleTimeline.Cue] = []
    @PerceptionIgnored private var translations: [String: String] = [:]
    @PerceptionIgnored private var sourceID = ""
    @PerceptionIgnored private var nativeSourceText = ""
    @PerceptionIgnored private var nativeCue: AISubtitleTimeline.Cue?
    @PerceptionIgnored private var sampledUntil = -1.0
    @PerceptionIgnored private var retryAfter = Date.distantPast
    @PerceptionIgnored private var translating = false
    @PerceptionIgnored private var recognitionSettings: AISubtitleRecognitionSettings?
    private(set) var generationError: String?

    init(session: PlaybackSession) { self.session = session }
    private var currentSettings: AISubtitleRecognitionSettings {
        let store = UserDefaults.standard
        return AISubtitleRecognitionSettings(onlineEnabled: store.bool(forKey: "aiSubtitle.enabled"),
            mode: store.string(forKey: "aiSubtitle.transcriptionProtocol") ?? "transcription",
            locale: store.string(forKey: "aiSubtitle.localASRLocale") ?? "zh-CN",
            serviceIdentity: ["endpoint", "protocol", "model", "apiKey", "targetLanguage", "transcriptionEndpoint",
                "transcriptionModel", "transcriptionApiKey", "transcriptionUseTranslation"].map {
                    String(describing: store.object(forKey: "aiSubtitle." + $0) ?? "")
                } + [NativeLocalASRModels.shared.revision.uuidString])
    }
    func configure(generate nextGenerate: Bool? = nil, translate nextTranslate: Bool? = nil) {
        guard let session else { return }
        let settings = currentSettings
        let request = settings.request(currentGenerate: generate, currentTranslate: translate,
                                       generate: nextGenerate, translate: nextTranslate)
        guard !request.denied else {
            status = "请先在「AI 字幕」设置中启用在线服务；离线语音生成可单独使用"; return
        }
        // Disabling a control must remain possible while media is loading or
        // after a provider was disabled in settings.
        if (nextGenerate == true && !generate) || (nextTranslate == true && !translate) {
            guard !session.isLive, session.hasTimeline, session.currentPlaybackURL != nil else {
                status = "当前媒体尚未就绪，或不支持定位音频；直播暂不支持 AI 字幕"; return
            }
        }
        let wantedGenerate = request.generate, wantedTranslate = request.translate
        let changedSettings = recognitionSettings != settings
        generate = wantedGenerate; translate = wantedTranslate; generationError = nil
        recognitionSettings = settings
        invalidate(clearGenerated: !generate || changedSettings)
        status = generate || translate ? "等待字幕" : "AI 字幕已关闭"
        tick()
    }
    func stop() {
        generate = false; translate = false; invalidate(clearGenerated: true)
        NativeLocalSpeechRecognizer.unload()
        scope = nil; previousPosition = nil; recognitionSettings = nil; generationError = nil; status = "AI 字幕已关闭"
    }
    private func invalidate(clearGenerated: Bool) {
        epoch = UUID(); work?.cancel(); work = nil; busy = false; translating = false
        translated = []; translations = [:]; sourceID = ""; nativeSourceText = ""; nativeCue = nil
        lines = []; retryAfter = .distantPast
        if clearGenerated { generated = []; sampledUntil = -1 }
    }
    private func identity(_ session: PlaybackSession) -> AISubtitleScope {
        AISubtitleScope(sessionID: session.mediaEnhancements.sessionID, mediaID: session.engine.mediaID ?? "",
            timeline: session.mediaEnhancements.timelineVersion,
            audioID: session.engine.tracks.first { $0.kind == .audio && $0.selected }?.id ?? "no")
    }
    private func check(_ ticket: UUID, _ captured: AISubtitleScope) throws {
        try Task.checkCancellation()
        guard ticket == epoch, let session, captured == identity(session),
              generate || translate, recognitionSettings == currentSettings else { throw CancellationError() }
    }
    /// Called at the actual KS clock. Seeks, decoder/media changes, and audio selection cancel in-flight work.
    func tick() {
        guard generate || translate, let session else { return }
        let settings = currentSettings
        if recognitionSettings != settings {
            recognitionSettings = settings; generationError = nil
            generate = generate && settings.canGenerate; translate = translate && settings.canTranslate
            invalidate(clearGenerated: true)
            status = generate || translate ? "设置已更新，等待字幕" : "AI 字幕已关闭"
        }
        guard generate || translate else { return }
        let now = session.position, date = Date(), current = identity(session)
        guard now.isFinite, now >= 0, !current.sessionID.isEmpty, !current.mediaID.isEmpty else { return }
        let seek = previousPosition.map { !AISubtitleTimeline.isContinuous(previous: $0, current: now,
            elapsed: date.timeIntervalSince(previousTime), speed: Double(session.engine.speed)) } ?? false
        previousPosition = now; previousTime = date
        if scope != current || seek { invalidate(clearGenerated: true); scope = current }
        let selected = (session.externalSubtitles.document?.id ?? (session.engine.subtitleSelection ?? "auto"))
            + "|\(session.externalSubtitles.timing.delay)|\(session.externalSubtitles.timing.scale)"
        if sourceID != selected {
            epoch = UUID(); work?.cancel(); work = nil; busy = false; translating = false
            translated = []; translations = [:]; nativeSourceText = ""; nativeCue = nil; sourceID = selected
        }
        if !generate && session.externalSubtitles.document == nil {
            let text = session.subtitles.lines.joined(separator: "\n")
            if text != nativeSourceText {
                if translating { epoch = UUID(); work?.cancel(); work = nil; busy = false; translating = false }
                if let old = nativeCue { translated.removeAll { $0.start == old.start && $0.end == old.end } }
                nativeSourceText = text
                nativeCue = text.isEmpty ? nil : .init(start: now, end: now + 30, text: text)
            }
        }
        let original = generated.filter { $0.start <= now && $0.end > now }.map(\.text)
        let translation = translated.filter { $0.start <= now && $0.end > now }.map(\.text)
        lines = (generate ? original : []) + (translate ? translation : [])
        generated.removeAll { $0.end < now - 90 }; translated.removeAll { $0.end < now - 90 }
        guard !busy, date >= retryAfter, session.engine.isReady, !session.engine.seeking, !session.loading else { return }
        guard !session.paused || (generated.isEmpty && translate && !session.subtitles.lines.isEmpty) else { return }
        let ticket = epoch
        if generate && now + 6 >= sampledUntil && current.audioID != "no", let url = session.currentAudioSamplingURL {
            let length = min(settings.isLocal ? 12 : 20, max(0, session.duration - now))
            guard length >= 0.5 else { return }
            let headers = session.currentAudioSamplingHeaders
            // Track IDs are the actual stream indices of the input being sampled,
            // including a companion audio file with more than one language.
            let stream = Int32(current.audioID) ?? -1
            launch(ticket, current, stopGenerationOnFailure: settings.isLocal) {
                if settings.isLocal {
                    self.status = "正在加载离线语音包"
                    _ = try await NativeLocalSpeechRecognizer.checkAvailability(locale: settings.locale)
                } else { try await LocalMediaServiceSettings.apply() }
                try self.check(ticket, current)
                self.status = "正在采集音频"
                let sample = try await NativeSubtitleAudio.sample(url: url, headers: headers, stream: stream, position: now, duration: length)
                try self.check(ticket, current)
                let cues: [AISubtitleTimeline.Cue]
                if settings.isLocal {
                    self.status = "正在本地识别语音"
                    cues = try await NativeLocalSpeechRecognizer.transcribe(wav: sample.wav, position: sample.position,
                        duration: sample.duration, locale: settings.locale)
                } else {
                    self.status = "正在识别语音"
                    var params = session.mediaEnhancements.serviceParams
                    params["position"] = .number(sample.position); params["duration"] = .number(sample.duration)
                    params["audio"] = .string(sample.wav.base64EncodedString())
                    let result = try await MobileMediaServices.call("ai.transcribe", params)
                    cues = try AISubtitleTimeline.decode(JSONEncoder().encode(result), position: sample.position, duration: sample.duration)
                }
                try self.check(ticket, current)
                self.generated = AISubtitleTimeline.replacingWindow(self.generated, with: cues,
                    position: sample.position, duration: sample.duration)
                // Translation follows generated speech whenever generation is
                // enabled, even with a manual primary subtitle selected. Clear
                // the same sampled window so matching timestamps cannot retain
                // the previous text's translation after re-recognition.
                self.translated = AISubtitleTimeline.replacingWindow(self.translated, with: [],
                    position: sample.position, duration: sample.duration)
                self.sampledUntil = sample.position + sample.duration
                self.status = cues.isEmpty ? "当前片段没有识别到语音" : "字幕已就绪"
            }
        } else if translate, let cue = nextTranslation(session, at: now) {
            let key = translationKey(cue)
            if let value = translations[key] {
                translated.append(.init(start: cue.start, end: cue.end, text: value)); return
            }
            launch(ticket, current, translating: true) {
                self.status = "正在翻译"
                try await LocalMediaServiceSettings.apply(); try self.check(ticket, current)
                var params = session.mediaEnhancements.serviceParams; params["text"] = .string(cue.text)
                let result = try await MobileMediaServices.call("ai.translate", params)
                try self.check(ticket, current)
                guard let text = result.object?["text"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                    throw TVError.unsupported("AI 没有返回有效字幕文本")
                }
                self.translations[key] = text
                self.translated.append(.init(start: cue.start, end: cue.end, text: text))
                if self.translations.count > 256 { self.translations = [key: text] }
                self.status = "字幕已就绪"
            }
        } else if !generate && translated.isEmpty { status = "等待主字幕；图片字幕可使用 AI 生成" }
    }
    private func translationKey(_ cue: AISubtitleTimeline.Cue) -> String { "\(cue.start)|\(cue.end)|\(cue.text)" }
    private func nextTranslation(_ session: PlaybackSession, at now: Double) -> AISubtitleTimeline.Cue? {
        var candidates: [AISubtitleTimeline.Cue] = []
        if !generate, let document = session.externalSubtitles.document {
            let timing = session.externalSubtitles.timing
            candidates = document.cues.filter { Double($0.end) / 1_000_000 * timing.scale + timing.delay >= now }
                .prefix(12).map { .init(start: max(0, Double($0.start) / 1_000_000 * timing.scale + timing.delay),
                    end: Double($0.end) / 1_000_000 * timing.scale + timing.delay, text: $0.text) }
        } else if !generate, let nativeCue {
            // Native text arrives at its actual decoded cue boundary. A text change clears the previous result.
            candidates = [nativeCue]
        }
        return AISubtitleRecognitionSettings.translationCandidates(generate: generate, generated: generated,
            primary: candidates, position: now).first { candidate in
            !translated.contains { $0.start == candidate.start && $0.end == candidate.end }
        }
    }
    private func launch(_ ticket: UUID, _ captured: AISubtitleScope, translating: Bool = false,
                        stopGenerationOnFailure: Bool = false, _ action: @escaping @MainActor () async throws -> Void) {
        busy = true; self.translating = translating
        work = Task { [weak self] in
            guard let self else { return }
            defer { if ticket == self.epoch { self.busy = false; self.work = nil; self.translating = false } }
            do { try self.check(ticket, captured); try await action() }
            catch {
                guard ticket == self.epoch else { return }
                if !(error is CancellationError) {
                    self.status = error.localizedDescription; self.retryAfter = Date().addingTimeInterval(10)
                    if stopGenerationOnFailure {
                        self.generationError = error.localizedDescription
                        self.generate = false; self.generated = []; self.sampledUntil = -1; self.lines = []
                        // The remaining translation control now follows the
                        // primary subtitle. Drop every result and identity tied
                        // to generated speech, while preserving this error and
                        // retry deadline for the next tick.
                        self.translated = []; self.translations = [:]
                        self.sourceID = ""; self.nativeSourceText = ""; self.nativeCue = nil
                    }
                }
            }
        }
    }
}
#endif
