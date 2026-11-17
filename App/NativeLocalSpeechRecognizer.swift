#if os(iOS)
import Foundation
import TVCore
import TVASR

/// Native sherpa-onnx CPU inference. No microphone, Apple Speech API, audio-session
/// changes or network request occurs here; model downloads are explicit in settings.
@MainActor enum NativeLocalSpeechRecognizer {
    enum Failure: LocalizedError {
        case unsupportedLanguage(String), invalidAudio, recognition, initialization, timedOut
        var errorDescription: String? {
            switch self {
            case let .unsupportedLanguage(language): "离线语音包不支持 \(language)，请在 AI 字幕设置中选择音频对应的语言"
            case .invalidAudio: "没有可用于本地识别的 16 kHz 单声道 PCM 音频"
            case .recognition: "离线语音识别失败，请校验语音包后重试"
            case .initialization: "离线语音包无法加载，请校验文件或重新下载"
            case .timedOut: "离线语音加载或识别超时；可重试或选择体积较小的语音包"
            }
        }
    }
    private static let worker = Worker()

    /// A real model is loaded to validate native compatibility; this is not a claim
    /// that speech has been transcribed or that the device can keep up with playback.
    static func checkAvailability(locale: String) async throws -> String {
        let model = try NativeLocalASRModels.shared.model(locale: locale)
        let installed = try await NativeLocalASRModels.shared.resolve(model)
        try await prepare(model: model, installed: installed)
        NativeLocalASRModels.shared.markLoaded(model, installed: installed)
        return "\(model.name)离线包已校验并通过原生加载；在播放器开启「AI 生成字幕」即可识别音频"
    }
    static func prepare(model: LocalASRModel, installed: LocalASRModelStore.Installed) async throws {
        _ = try await perform(model: model, installed: installed, samples: nil, position: 0)
    }
    static func transcribe(wav: Data, position: Double, duration: Double, locale: String) async throws -> [AISubtitleTimeline.Cue] {
        guard position.isFinite, position >= 0, duration.isFinite, duration > 0, duration <= 20 else { throw Failure.invalidAudio }
        let samples = try pcm(wav)
        guard abs(Double(samples.count) / 16000 - duration) <= 0.1 else { throw Failure.invalidAudio }
        let model = try NativeLocalASRModels.shared.model(locale: locale)
        let installed = try await NativeLocalASRModels.shared.resolve(model)
        let cues = try await perform(model: model, installed: installed, samples: samples, position: position)
        NativeLocalASRModels.shared.markLoaded(model, installed: installed)
        return cues
    }
    static func unload(modelID: String? = nil) { worker.unload(modelID: modelID) }
    static func unloadAndWait(modelID: String) async { await worker.unloadAndWait(modelID: modelID) }

    private static func perform(model: LocalASRModel, installed: LocalASRModelStore.Installed,
                                samples: [Float]?, position: Double) async throws -> [AISubtitleTimeline.Cue] {
        let token = try Cancellation()
        let revision = NativeLocalASRModels.shared.revision
        // Register before the first suspension so model deletion can cancel work
        // that is queued but has not entered the native inference thread yet.
        let pending = worker.register(modelID: model.id, token: token)
        defer { worker.unregister(pending) }
        let timeout = Task.detached(priority: .utility) {
            do { try await Task.sleep(for: .seconds(60)); token.cancel(timeout: true) }
            catch { }
        }
        defer { timeout.cancel() }
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            let answer = try await worker.run(model: model, installed: installed, samples: samples, position: position, token: token)
            try Task.checkCancellation()
            guard revision == NativeLocalASRModels.shared.revision else { throw CancellationError() }
            return answer
        }, onCancel: { token.cancel() })
    }
    private static func pcm(_ wav: Data) throws -> [Float] {
        guard wav.count > 44, wav.count <= 44 + 20 * 16000 * 2,
              wav.prefix(4) == Data("RIFF".utf8), wav[8..<16] == Data("WAVEfmt ".utf8),
              wav[36..<40] == Data("data".utf8), wav.count % 2 == 0 else { throw Failure.invalidAudio }
        func little(_ offset: Int, _ count: Int) -> UInt32 {
            (0..<count).reduce(0) { $0 | UInt32(wav[offset + $1]) << (8 * $1) }
        }
        guard little(4, 4) == wav.count - 8, little(16, 4) == 16, little(20, 2) == 1,
              little(22, 2) == 1, little(24, 4) == 16000, little(28, 4) == 32000,
              little(32, 2) == 2, little(34, 2) == 16, little(40, 4) == wav.count - 44 else { throw Failure.invalidAudio }
        return stride(from: 44, to: wav.count, by: 2).map {
            Float(Int16(bitPattern: UInt16(wav[$0]) | UInt16(wav[$0 + 1]) << 8)) / 32768
        }
    }

    private final class Cancellation: @unchecked Sendable {
        let pointer: OpaquePointer
        private let lock = NSLock()
        private var timedOut = false
        private var completion: CheckedContinuation<[AISubtitleTimeline.Cue], Error>?
        private var answer: Result<[AISubtitleTimeline.Cue], Error>?
        init() throws {
            guard let pointer = tvasr_cancellation_create() else { throw Failure.initialization }
            self.pointer = pointer
        }
        deinit { tvasr_cancellation_destroy(pointer) }
        func cancel(timeout: Bool = false) {
            lock.lock(); timedOut = timedOut || timeout; lock.unlock()
            tvasr_cancellation_cancel(pointer)
            finish(.failure(timeout ? Failure.timedOut : CancellationError()))
        }
        // Native session construction does not expose an interruption API. End
        // the caller's wait immediately; the queue retains this token and owns
        // the eventual native pointer until it can safely destroy it.
        func bind(_ completion: CheckedContinuation<[AISubtitleTimeline.Cue], Error>) {
            lock.lock()
            if let answer { lock.unlock(); completion.resume(with: answer) }
            else { self.completion = completion; lock.unlock() }
        }
        func finish(_ answer: Result<[AISubtitleTimeline.Cue], Error>) {
            lock.lock()
            guard self.answer == nil else { lock.unlock(); return }
            self.answer = answer
            let completion = self.completion; self.completion = nil
            lock.unlock()
            completion?.resume(with: answer)
        }
        func check() throws {
            if tvasr_cancellation_is_cancelled(pointer) != 0 {
                lock.lock(); let timeout = timedOut; lock.unlock()
                if timeout { throw Failure.timedOut }
                throw CancellationError()
            }
        }
    }
    /// One CPU model in memory, one inference at a time. Queued obsolete operations
    /// check their cancellation before loading a model. Model deletion cancels first,
    /// then releases the native recognizer on this same queue.
    private final class Worker: @unchecked Sendable {
        private let queue = DispatchQueue(label: "yingxia.local-asr", qos: .utility)
        private let lock = NSLock()
        private var pending: [UUID: (String, Cancellation)] = [:]
        private var recognizer: OpaquePointer?
        private var loaded = "", modelID = ""
        func register(modelID: String, token: Cancellation) -> UUID {
            let id = UUID(); lock.lock(); pending[id] = (modelID, token); lock.unlock()
            return id
        }
        func unregister(_ id: UUID) { lock.lock(); pending[id] = nil; lock.unlock() }
        func unload(modelID: String?) {
            lock.lock(); let cancelled = pending.values.filter { modelID == nil || $0.0 == modelID }.map { $0.1 }; lock.unlock()
            cancelled.forEach { $0.cancel() }
            queue.async { [self] in
                if modelID == nil || modelID == self.modelID { release() }
            }
        }
        func unloadAndWait(modelID: String) async {
            unload(modelID: modelID)
            await withCheckedContinuation { continuation in
                queue.async { continuation.resume() }
            }
        }
        private func release() {
            if let recognizer { tvasr_destroy(recognizer) }
            recognizer = nil; loaded = ""; modelID = ""
        }
        func run(model: LocalASRModel, installed: LocalASRModelStore.Installed, samples: [Float]?, position: Double,
                 token: Cancellation) async throws -> [AISubtitleTimeline.Cue] {
            try await withCheckedThrowingContinuation { continuation in
                token.bind(continuation)
                queue.async { [self] in
                    do {
                        try token.check()
                        let key = model.id + installed.fingerprint
                        if loaded != key {
                            release()
                            recognizer = try create(model: model, directory: installed.directory, token: token)
                            loaded = key; modelID = model.id
                        }
                        try token.check()
                        guard let samples else { token.finish(.success([])); return }
                        var result: OpaquePointer?, error: UnsafeMutablePointer<CChar>?
                        let code = samples.withUnsafeBufferPointer {
                            tvasr_transcribe(recognizer, $0.baseAddress, Int32($0.count), token.pointer, &result, &error)
                        }
                        defer { if let result { tvasr_result_destroy(result) }; if let error { tvasr_error_destroy(error) } }
                        try token.check()
                        guard code == 0, let result else { throw Failure.recognition }
                        var cues: [AISubtitleTimeline.Cue] = []
                        let count = tvasr_result_count(result)
                        guard count >= 0, count <= 1024 else { throw Failure.recognition }
                        for index in 0..<count {
                            let text = String(cString: tvasr_result_text(result, index))
                            let start = tvasr_result_start(result, index), end = tvasr_result_end(result, index)
                            let tokens = tvasr_result_token_count(result, index)
                            guard tokens >= 0, tokens <= 2048 else { continue }
                            let words = (0..<tokens).map { String(cString: tvasr_result_token(result, index, $0)) }
                            let timestamps = (0..<tokens).map { tvasr_result_timestamp(result, index, $0) }
                            cues += LocalSpeechSubtitles.tokenCues(transcript: text, tokens: words, timestamps: timestamps,
                                base: start, end: end, position: position)
                        }
                        try token.check(); token.finish(.success(cues))
                    } catch {
                        // A cancelled VAD/model run may have partially updated internal state.
                        release(); token.finish(.failure(error))
                    }
                }
            }
        }
        private func create(model: LocalASRModel, directory: URL, token: Cancellation) throws -> OpaquePointer {
            var strings: [UnsafeMutablePointer<CChar>] = []
            defer { strings.forEach { free($0) } }
            func string(_ value: String) -> UnsafePointer<CChar>? {
                guard let pointer = strdup(value) else { return nil }
                strings.append(pointer); return UnsafePointer(pointer)
            }
            func path(_ name: String?) -> UnsafePointer<CChar>? {
                name.flatMap { string(directory.appendingPathComponent($0).path) }
            }
            let names = model.files.map(\.name)
            var config = TVASRConfiguration()
            config.engine = string(model.engine); config.model_type = string(model.modelType)
            config.tokens = path("tokens.txt")
            config.encoder = path(names.first { $0.hasPrefix("encoder") })
            config.decoder = path(names.first { $0.hasPrefix("decoder") })
            config.joiner = path(names.first { $0.hasPrefix("joiner") })
            config.model = path(names.first { $0 == "model.int8.onnx" })
            config.vad = path(names.first { $0 == "silero_vad.onnx" })
            var error: UnsafeMutablePointer<CChar>?
            let pointer = tvasr_create(&config, token.pointer, &error)
            defer { if let error { tvasr_error_destroy(error) } }
            if let pointer {
                do { try token.check(); return pointer }
                catch { tvasr_destroy(pointer); throw error }
            }
            try token.check(); throw Failure.initialization
        }
    }
}
#endif
