import Foundation
import CryptoKit

/// Fixed model manifest shared with MacCat. Models are data, never executable plugins.
public struct LocalASRModel: Codable, Equatable, Identifiable, Sendable {
    public struct File: Codable, Equatable, Sendable {
        public let name: String, url: URL, bytes: Int64, sha256: String
        public init(name: String, url: URL, bytes: Int64, sha256: String) {
            self.name = name; self.url = url; self.bytes = bytes; self.sha256 = sha256
        }
    }
    public let id: String, name: String, engine: String, modelType: String
    public let files: [File]
    public let bytes: Int64
    public init(id: String, name: String, engine: String, modelType: String, files: [File], bytes: Int64) {
        self.id = id; self.name = name; self.engine = engine; self.modelType = modelType; self.files = files; self.bytes = bytes
    }
    public static func modelID(for locale: String) -> String {
        let value = locale.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "_", with: "-").lowercased()
        if value == "zh-en" { return value }
        if value == "zh-hk" || value.hasPrefix("yue") { return "yue" }
        return value.split(separator: "-").first.map(String.init) ?? "zh"
    }
}

/// Serializes commits/removals. Network transfers use bounded files and every install publishes
/// only after size + SHA-256 checks. Interrupted staging directories are removed on first access.
public actor LocalASRModelStore {
    public enum Failure: LocalizedError {
        case missing, corrupt, busy, invalidManifest, download(Int), tooLarge
        public var errorDescription: String? {
            switch self {
            case .missing: "请先在「AI 字幕」设置中下载对应的离线语音包"
            case .corrupt: "离线语音包校验失败，请重新下载修复"
            case .busy: "语音包正在处理，请等待完成或先取消下载"
            case .invalidManifest: "离线语音包清单无效"
            case let .download(code): "语音包下载失败（HTTP \(code)），请检查网络后重试"
            case .tooLarge: "下载文件超过语音包声明的大小，已停止下载"
            }
        }
    }
    public struct Installed: Sendable {
        public let directory: URL, fingerprint: String
        public init(directory: URL, fingerprint: String) { self.directory = directory; self.fingerprint = fingerprint }
    }
    public enum Phase: Sendable { case downloading, verifying }
    public typealias Progress = @Sendable (Phase, Int64, Int64) -> Void
    private let directory: URL
    private var prepared = false
    private var jobs: [String: UUID] = [:]
    private var verified: [String: String] = [:]
    public init(directory: URL) { self.directory = directory }

    private func prepare() throws {
        guard !prepared else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        #endif
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        // A crash can occur after target -> old but before stage -> target. Recover
        // the complete previous package before pruning interrupted staging data.
        for file in files where file.lastPathComponent.hasPrefix(".replaced-") {
            if let data = try? Data(contentsOf: file.appendingPathComponent("manifest.json")),
               let model = try? JSONDecoder().decode(LocalASRModel.self, from: data),
               (try? validate(model)) != nil {
                let target = directory.appendingPathComponent(model.id, isDirectory: true)
                if !FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.moveItem(at: file, to: target)
                    continue
                }
            }
            try FileManager.default.removeItem(at: file)
        }
        for file in files where file.lastPathComponent.hasPrefix(".download-") {
            try FileManager.default.removeItem(at: file)
        }
        prepared = true
    }
    private func validate(_ model: LocalASRModel) throws {
        let safe: (String) -> Bool = { !$0.isEmpty && !$0.hasPrefix(".") && !$0.contains("/") && !$0.contains("\\") && !$0.contains("\0") }
        guard safe(model.id), !model.files.isEmpty, model.files.count <= 8,
              model.bytes > 0, model.bytes <= 512 * 1024 * 1024,
              Set(model.files.map(\.name)).count == model.files.count,
              model.files.allSatisfy({ safe($0.name) && $0.name != "manifest.json" && $0.bytes > 0 && $0.bytes <= model.bytes &&
                  $0.sha256.count == 64 && $0.sha256.allSatisfy({ $0.isHexDigit }) &&
                  ($0.url.scheme == "https" || ($0.url.scheme == "http" && $0.url.host == "127.0.0.1")) }),
              model.files.reduce(0, { $0 + $1.bytes }) == model.bytes else { throw Failure.invalidManifest }
    }
    private func fingerprint(_ model: LocalASRModel, at folder: URL) throws -> String {
        try model.files.map { file in
            let attributes: [FileAttributeKey: Any]
            do { attributes = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(file.name).path) }
            catch { throw Failure.missing }
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.size] as? NSNumber)?.int64Value == file.bytes else { throw Failure.corrupt }
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let created = (attributes[.creationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(file.sha256):\(attributes[.systemFileNumber] ?? ""):\(modified):\(created)"
        }.joined(separator: "|")
    }
    private func verify(_ model: LocalASRModel, at folder: URL, progress: Progress? = nil) throws {
        var completed: Int64 = 0
        progress?(.verifying, 0, model.bytes)
        for file in model.files {
            try Task.checkCancellation()
            let handle = try FileHandle(forReadingFrom: folder.appendingPathComponent(file.name))
            defer { try? handle.close() }
            var hash = SHA256(), size: Int64 = 0
            while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
                try Task.checkCancellation()
                size += Int64(data.count)
                guard size <= file.bytes else { throw Failure.corrupt }
                hash.update(data: data)
                progress?(.verifying, completed + size, model.bytes)
            }
            guard size == file.bytes, hash.finalize().map({ String(format: "%02x", $0) }).joined() == file.sha256 else { throw Failure.corrupt }
            completed += size
        }
    }
    public func resolve(_ model: LocalASRModel, force: Bool = false, progress: Progress? = nil) throws -> Installed {
        try prepare(); try validate(model); try Task.checkCancellation()
        let folder = directory.appendingPathComponent(model.id, isDirectory: true)
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
              let receipt = try? JSONDecoder().decode(LocalASRModel.self, from: data), receipt == model else { throw Failure.missing }
        let current = try fingerprint(model, at: folder)
        if force || verified[model.id] != current {
            try verify(model, at: folder, progress: progress)
            // Refuse a file replaced during verification, before giving the native loader a path.
            guard try fingerprint(model, at: folder) == current else { throw Failure.corrupt }
            verified[model.id] = current
        }
        return Installed(directory: folder, fingerprint: current)
    }
    public func install(_ model: LocalASRModel, progress: @escaping Progress = { _, _, _ in }) async throws {
        try prepare(); try validate(model); try Task.checkCancellation()
        guard jobs[model.id] == nil else { throw Failure.busy }
        let ticket = UUID(); jobs[model.id] = ticket
        let stage = directory.appendingPathComponent(".download-\(model.id)-\(ticket)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: stage)
            if jobs[model.id] == ticket { jobs[model.id] = nil }
        }
        do { _ = try resolve(model, force: true, progress: progress); return }
        catch is CancellationError { throw CancellationError() }
        catch { }
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        var completed: Int64 = 0
        for file in model.files {
            try Task.checkCancellation()
            let before = completed
            progress(.downloading, before, model.bytes)
            let download = LocalASRFileDownload(file: file, destination: stage.appendingPathComponent(file.name)) { received in
                progress(.downloading, before + received, model.bytes)
            }
            try await download.run()
            completed += file.bytes
            progress(.downloading, completed, model.bytes)
        }
        try Task.checkCancellation()
        try verify(model, at: stage, progress: progress)
        try JSONEncoder().encode(model).write(to: stage.appendingPathComponent("manifest.json"), options: .atomic)
        try Task.checkCancellation()
        let target = directory.appendingPathComponent(model.id, isDirectory: true)
        let old = directory.appendingPathComponent(".replaced-\(model.id)-\(ticket)", isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) { try fm.moveItem(at: target, to: old) }
        do { try fm.moveItem(at: stage, to: target) }
        catch {
            if fm.fileExists(atPath: old.path) { try? fm.moveItem(at: old, to: target) }
            throw error
        }
        try? fm.removeItem(at: old)
        verified[model.id] = try fingerprint(model, at: target)
    }
    public func remove(_ model: LocalASRModel) throws {
        try prepare(); try validate(model)
        guard jobs[model.id] == nil else { throw Failure.busy }
        verified[model.id] = nil
        let folder = directory.appendingPathComponent(model.id, isDirectory: true)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }
}

/// URLSession writes directly to disk. Delegate callbacks are serialized; cancellation only
/// signals the task, so cleanup cannot race a callback still moving its temporary download.
private final class LocalASRFileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let file: LocalASRModel.File, destination: URL
    let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var session: URLSession?, task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<Void, Error>?
    private var cancelled = false
    private var transferError: Error?
    private var lastProgress = Date.distantPast
    init(file: LocalASRModel.File, destination: URL, progress: @escaping @Sendable (Int64) -> Void) {
        self.file = file; self.destination = destination; self.progress = progress
    }
    func run() async throws {
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 1800
                let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                let task = session.downloadTask(with: file.url)
                self.continuation = continuation; self.session = session; self.task = task
                lock.unlock()
                task.resume()
            }
            try Task.checkCancellation()
        }, onCancel: { self.cancel() })
    }
    private func cancel() {
        lock.lock(); cancelled = true; let task = self.task; lock.unlock()
        task?.cancel()
    }
    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        let continuation = self.continuation, session = self.session
        let cancelled = self.cancelled
        self.continuation = nil; self.session = nil; task = nil
        lock.unlock()
        continuation?.resume(with: cancelled ? .failure(CancellationError()) : result)
        session?.finishTasksAndInvalidate()
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > file.bytes {
            transferError = LocalASRModelStore.Failure.tooLarge; downloadTask.cancel(); return
        }
        if Date().timeIntervalSince(lastProgress) >= 0.15 || totalBytesWritten == file.bytes {
            lastProgress = Date(); progress(totalBytesWritten)
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            if let transferError { throw transferError }
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw LocalASRModelStore.Failure.download(status) }
            let bytes = (try FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.int64Value
            guard bytes == file.bytes else { throw LocalASRModelStore.Failure.corrupt }
            try FileManager.default.moveItem(at: location, to: destination)
        } catch { transferError = error }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let failure = transferError ?? error { finish(.failure(failure)) }
        else { finish(.success(())) }
    }
}
