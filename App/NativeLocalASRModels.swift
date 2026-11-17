#if os(iOS)
import Foundation
import Perception
import TVCore

@MainActor @Perceptible final class NativeLocalASRModels {
    static let shared: NativeLocalASRModels = {
        struct Catalog: Decodable { let version: Int; let sherpaVersion: String; let models: [LocalASRModel] }
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalASR/models", isDirectory: true)
        let store = LocalASRModelStore(directory: root)
        do {
            guard let url = Bundle.main.url(forResource: "local-asr-models", withExtension: "json") else {
                throw LocalASRModelStore.Failure.invalidManifest
            }
            let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
            guard catalog.version == 1, catalog.sherpaVersion == "1.13.4", !catalog.models.isEmpty else {
                throw LocalASRModelStore.Failure.invalidManifest
            }
            return NativeLocalASRModels(models: catalog.models, store: store)
        } catch { return NativeLocalASRModels(models: [], store: store, catalogError: error.localizedDescription) }
    }()
    enum State: Equatable {
        case missing, checking, downloading(Int64, Int64), verifying(Int64, Int64)
        case downloaded, loading, ready, cancelling, removing, failed(String), unavailable(String)
        var busy: Bool {
            switch self {
            case .checking, .downloading, .verifying, .loading, .cancelling, .removing: true
            default: false
            }
        }
        var canCancel: Bool {
            switch self { case .checking, .downloading, .verifying, .loading: true; default: false }
        }
    }
    let models: [LocalASRModel]
    let catalogError: String?
    private(set) var states: [String: State] = [:]
    private(set) var notices: [String: String] = [:]
    private(set) var progressDates: [String: Date] = [:]
    private(set) var revision = UUID()
    @PerceptionIgnored private let store: LocalASRModelStore
    @PerceptionIgnored private var jobs: [String: Task<Void, Never>] = [:]
    @PerceptionIgnored private var tickets: [String: UUID] = [:]
    @PerceptionIgnored private var progressOrder: [String: Int] = [:]
    @PerceptionIgnored private var nativeFingerprints: [String: String] = [:]
    @PerceptionIgnored private var generations: [String: UUID] = [:]
    @PerceptionIgnored private var removing: Set<String> = []

    init(models: [LocalASRModel], store: LocalASRModelStore, catalogError: String? = nil) {
        self.models = models; self.store = store; self.catalogError = catalogError
    }
    func model(locale: String) throws -> LocalASRModel {
        guard let model = models.first(where: { $0.id == LocalASRModel.modelID(for: locale) }) else {
            throw NativeLocalSpeechRecognizer.Failure.unsupportedLanguage(locale)
        }
        return model
    }
    func state(_ model: LocalASRModel) -> State { states[model.id] ?? .missing }
    func resolve(_ model: LocalASRModel, force: Bool = false,
                 progress: LocalASRModelStore.Progress? = nil) async throws -> LocalASRModelStore.Installed {
        guard !removing.contains(model.id) else { throw LocalASRModelStore.Failure.missing }
        let generation = generations[model.id]
        let installed = try await store.resolve(model, force: force, progress: progress)
        try Task.checkCancellation()
        guard generation == generations[model.id], !removing.contains(model.id) else { throw CancellationError() }
        return installed
    }
    func markLoaded(_ model: LocalASRModel, installed: LocalASRModelStore.Installed) {
        guard !removing.contains(model.id) else { return }
        nativeFingerprints[model.id] = installed.fingerprint
        if jobs[model.id] == nil { states[model.id] = .ready }
    }
    func refresh() async {
        // All checks are owned by this singleton. Cancelling a disappearing
        // page does not strand .checking, replace a download ticket, or rehash
        // every installed package each time the page renders.
        let checks = models.compactMap { model -> Task<Void, Never>? in
            guard jobs[model.id] == nil, states[model.id] == nil else { return nil }
            return begin(model, state: .checking) { ticket in
                let installed = try await self.resolve(model, progress: self.progress(model, ticket: ticket))
                return self.nativeFingerprints[model.id] == installed.fingerprint ? .ready : .downloaded
            }
        }
        for check in checks { await check.value }
    }
    func download(_ model: LocalASRModel) {
        guard jobs[model.id] == nil else { return }
        _ = begin(model, state: .downloading(0, model.bytes)) { ticket in
            try await self.store.install(model, progress: self.progress(model, ticket: ticket))
            try Task.checkCancellation()
            self.changed(model)
            return try await self.prepare(model)
        }
    }
    func verify(_ model: LocalASRModel) {
        guard jobs[model.id] == nil else { return }
        _ = begin(model, state: .verifying(0, model.bytes)) { ticket in
            _ = try await self.resolve(model, force: true, progress: self.progress(model, ticket: ticket))
            return try await self.prepare(model)
        }
    }
    func cancel(_ model: LocalASRModel) {
        guard let job = jobs[model.id], state(model).canCancel else { return }
        states[model.id] = .cancelling
        job.cancel()
    }
    func remove(_ model: LocalASRModel) {
        guard jobs[model.id] == nil else { return }
        removing.insert(model.id); changed(model)
        _ = begin(model, state: .removing) { _ in
            defer { self.removing.remove(model.id) }
            await NativeLocalSpeechRecognizer.unloadAndWait(modelID: model.id)
            try await self.store.remove(model)
            return .missing
        }
    }
    private func changed(_ model: LocalASRModel) {
        generations[model.id] = UUID(); revision = UUID(); nativeFingerprints[model.id] = nil
        NativeLocalSpeechRecognizer.unload(modelID: model.id)
    }
    private func prepare(_ model: LocalASRModel) async throws -> State {
        try Task.checkCancellation()
        let installed = try await resolve(model)
        states[model.id] = .loading
        do {
            try await NativeLocalSpeechRecognizer.prepare(model: model, installed: installed)
            try Task.checkCancellation()
            nativeFingerprints[model.id] = installed.fingerprint
            return .ready
        } catch is CancellationError { throw CancellationError() }
        catch {
            // A later native load failure invalidates the earlier success for
            // these same files. Cancelling a subsequent retry must not restore
            // .ready from that obsolete fingerprint.
            nativeFingerprints[model.id] = nil
            return .unavailable(error.localizedDescription)
        }
    }
    @discardableResult private func begin(_ model: LocalASRModel, state: State,
        action: @escaping @MainActor (UUID) async throws -> State) -> Task<Void, Never> {
        let ticket = UUID(); tickets[model.id] = ticket; progressOrder[model.id] = 0
        states[model.id] = state; notices[model.id] = nil; progressDates[model.id] = Date()
        let job = Task {
            defer {
                if tickets[model.id] == ticket {
                    tickets[model.id] = nil; jobs[model.id] = nil; progressOrder[model.id] = nil
                }
            }
            do { states[model.id] = try await action(ticket) }
            catch is CancellationError {
                // Any staging writes have stopped before the operation throws.
                // Inspect committed files from a fresh, uncancelled task.
                let store = store
                let installed = await Task.detached { try? await store.resolve(model) }.value
                if let installed {
                    states[model.id] = nativeFingerprints[model.id] == installed.fingerprint ? .ready : .downloaded
                    notices[model.id] = "操作已取消，已下载的完整语音包已保留。"
                } else {
                    states[model.id] = .missing
                    notices[model.id] = "操作已取消，临时下载文件已清理。"
                }
            } catch LocalASRModelStore.Failure.missing { states[model.id] = .missing }
            catch { states[model.id] = .failed(error.localizedDescription) }
        }
        jobs[model.id] = job
        return job
    }
    private func progress(_ model: LocalASRModel, ticket: UUID) -> LocalASRModelStore.Progress {
        let order = ProgressOrder()
        return { [weak self] phase, received, total in
            let sequence = order.next()
            Task { @MainActor in
                guard let self, self.tickets[model.id] == ticket,
                      sequence > (self.progressOrder[model.id] ?? 0) else { return }
                // In-flight delegate callbacks cannot replace cancelling,
                // loading, or a completed availability result.
                switch self.state(model) { case .checking, .downloading, .verifying: break; default: return }
                self.progressOrder[model.id] = sequence
                if phase == .downloading {
                    if self.states[model.id] != .downloading(received, total) { self.progressDates[model.id] = Date() }
                    self.states[model.id] = .downloading(received, total)
                } else { self.states[model.id] = .verifying(received, total) }
            }
        }
    }
    private final class ProgressOrder: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    }
}
#endif
