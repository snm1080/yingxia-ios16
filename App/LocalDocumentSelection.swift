import Foundation

/// One picker route owns one set of provider grants until its import has finished.
enum LocalDocumentSelectionKind: String, Identifiable, Sendable {
    case pythonFiles, subscriptionFile, javaScriptFile
    case htmlFile, backupFile, subtitleFile, danmakuFile, fontFile, mediaFile
    var id: String { rawValue }
    // Files uses checkmarks and an Open button for these batch source routes.
    // Dependencies still travel together inside each Python ZIP package.
    var allowsMultipleSelection: Bool {
        switch self {
        case .pythonFiles, .javaScriptFile, .htmlFile: true
        default: false
        }
    }
    /// Match the successful HTML/music file picker: consume an app-local copy.
    var importsCopy: Bool { true }
}

struct LocalDocumentCompletionGate {
    private var completed = false
    mutating func accept() -> Bool {
        guard !completed else { return false }
        completed = true
        return true
    }
}

/// UIKit may dismiss a document picker before delivering its result to the delegate.
/// A picker session delivers its outcome after both events, regardless of their order.
struct LocalDocumentImportGate {
    private var hasSelection = false
    private var hasDismissed = false
    private var hasStarted = false

    mutating func selectionReceived() -> Bool {
        hasSelection = true
        return startIfReady()
    }

    mutating func pickerDismissed() -> Bool {
        hasDismissed = true
        return startIfReady()
    }

    private mutating func startIfReady() -> Bool {
        guard hasSelection, hasDismissed, !hasStarted else { return false }
        hasStarted = true
        return true
    }
}

struct LocalDocumentImportItem: Sendable {
    let filename: String
    let detail: String
    let succeeded: Bool
}

/// Results describe each completed file. A failed file never rolls back other imports.
struct LocalDocumentBatchReport: Sendable {
    let totalCount: Int
    fileprivate(set) var items: [LocalDocumentImportItem] = []
    fileprivate(set) var cancelled = false
    var successCount: Int { items.filter(\.succeeded).count }
    var failureCount: Int { items.count - successCount }
    var summary: String {
        var text = "已导入 \(successCount) / \(totalCount) 个文件，失败 \(failureCount) 个"
        if cancelled { text += "；已取消，未处理 \(totalCount - items.count) 个" }
        return text
    }
    var details: String {
        items.map { "\($0.succeeded ? "✓" : "✕") \($0.filename)：\($0.detail)" }.joined(separator: "\n")
    }
    var message: String { [summary, details].filter { !$0.isEmpty }.joined(separator: "\n") }
}

/// NSFileCoordinator permits cancellation from another thread while a provider is coordinating a read.
private final class LocalDocumentReadCoordinator: @unchecked Sendable {
    let value = NSFileCoordinator()
}

final class LocalDocumentSelection: @unchecked Sendable {
    let urls: [URL]
    let kind: LocalDocumentSelectionKind
    private let lock = NSLock()
    private var grants: [URL]
    private var copies: [URL]
    private var readers = 0
    private var released = false

    init(urls: [URL], kind: LocalDocumentSelectionKind, ownsImportedCopy: Bool = false) throws {
        guard !urls.isEmpty, urls.count <= (kind.allowsMultipleSelection ? 100 : 1), urls.allSatisfy(\.isFileURL) else {
            throw Self.failure("未获得有效的所选文件，请重新选择")
        }
        self.urls = urls
        self.kind = kind
        // Acquire before the picker is dismissed; models can read after the dismissal transition.
        grants = urls.filter { $0.startAccessingSecurityScopedResource() }
        // Only UIKit's copy-mode result is owned. Never remove an in-place source or folder.
        let container = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.pathComponents
        copies = ownsImportedCopy && kind.importsCopy ? urls.filter {
            let components = $0.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            return components.starts(with: container) && components.count > container.count
        } : []
    }

    func release() {
        let resources = lock.withLock { released = true; return resourcesIfUnused() }
        close(resources)
    }
    deinit { release() }

    private func beginRead() throws {
        try lock.withLock {
            guard !released else { throw Self.failure("文件选择已结束，请重新选择文件") }
            readers += 1
        }
    }
    private func endRead() {
        let resources = lock.withLock { readers -= 1; return resourcesIfUnused() }
        close(resources)
    }
    /// Call with the lock held; an in-flight provider read keeps the lease even if its owner leaves.
    private func resourcesIfUnused() -> (grants: [URL], copies: [URL]) {
        guard released, readers == 0 else { return ([], []) }
        let resources = (grants, copies)
        grants.removeAll(); copies.removeAll()
        return resources
    }
    private func close(_ resources: (grants: [URL], copies: [URL])) {
        resources.grants.forEach { $0.stopAccessingSecurityScopedResource() }
        for url in resources.copies {
            // A provider that returned a directory for a file route must not cause recursive deletion.
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Sequential imports keep all provider grants/copies alive until the batch finishes.
    /// Validation and import errors belong to one file; cancellation stops later work.
    @MainActor func importDocuments(
        progress: (Int, Int, String) -> Void = { _, _, _ in },
        importDocument: (Int, URL) async throws -> String
    ) async -> LocalDocumentBatchReport {
        defer { release() }
        var report = LocalDocumentBatchReport(totalCount: urls.count)
        for (index, url) in urls.enumerated() {
            if Task.isCancelled { report.cancelled = true; break }
            let filename = url.lastPathComponent
            progress(index + 1, urls.count, filename)
            await Task.yield()
            do {
                try await validateKind(at: index)
                let detail = try await importDocument(index, url)
                // The operation has persisted this file, even if cancellation arrived at its end.
                report.items.append(.init(filename: filename, detail: detail, succeeded: true))
            } catch {
                if error is CancellationError || Task.isCancelled { report.cancelled = true; break }
                report.items.append(.init(filename: filename, detail: error.localizedDescription, succeeded: false))
            }
        }
        return report
    }

    /// A broad file UTI keeps provider documents selectable; directories are never imports.
    /// The indexed form validates one batch item so another invalid item cannot abort it.
    func validateKind(at index: Int? = nil) async throws {
        let selected: [URL]
        if let index {
            guard urls.indices.contains(index) else { throw Self.failure("所选文件无效") }
            selected = [urls[index]]
        } else { selected = urls }
        try Task.checkCancellation()
        try beginRead()
        let coordinator = LocalDocumentReadCoordinator()
        let task = Task.detached(priority: .userInitiated) { [self] in
            defer { endRead() }
            for url in selected {
                try Task.checkCancellation()
                var coordinationError: NSError?
                var result: Result<Void, Error>?
                coordinator.value.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinated in
                    result = Result {
                        let values = try coordinated.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                        guard values.isDirectory != true, values.isRegularFile == true else {
                            throw Self.failure("请选择文件，不支持导入文件夹；多文件来源请压缩为 ZIP 后导入")
                        }
                    }
                }
                if let coordinationError { throw coordinationError }
                guard let result else { throw Self.failure("文件提供方未返回文件，请重试") }
                try result.get()
            }
        }
        try await withTaskCancellationHandler {
            do { try await task.value; try Task.checkCancellation() }
            catch { try Task.checkCancellation(); throw error }
        } onCancel: { task.cancel(); coordinator.value.cancel() }
    }

    /// Coordinate with Files/iCloud on a background executor, and read at most the script limit.
    func readData(at index: Int = 0, maxBytes: Int) async throws -> Data {
        guard urls.indices.contains(index), maxBytes > 0, maxBytes < Int.max else { throw Self.failure("所选文件无效") }
        try Task.checkCancellation()
        try beginRead()
        let url = urls[index]
        let coordinator = LocalDocumentReadCoordinator()
        let task = Task.detached(priority: .userInitiated) { [self] in
            defer { endRead() }
            try Task.checkCancellation()
            var coordinationError: NSError?
            var result: Result<Data, Error>?
            coordinator.value.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinated in
                result = Result {
                    let values = try coordinated.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey])
                    guard values.isDirectory != true, values.isRegularFile == true else { throw Self.failure("请选择文件，不能选择文件夹") }
                    guard values.fileSize.map({ $0 <= maxBytes }) ?? true else { throw Self.failure("所选文件过大") }
                    guard let stream = InputStream(url: coordinated) else { throw Self.failure("无法读取所选文件") }
                    stream.open()
                    defer { stream.close() }
                    var data = Data(), buffer = [UInt8](repeating: 0, count: min(64 * 1024, maxBytes + 1))
                    while true {
                        try Task.checkCancellation()
                        let count = stream.read(&buffer, maxLength: min(buffer.count, maxBytes - data.count + 1))
                        guard count >= 0 else { throw stream.streamError ?? Self.failure("读取所选文件失败") }
                        if count == 0 { return data }
                        data.append(contentsOf: buffer.prefix(count))
                        guard data.count <= maxBytes else { throw Self.failure("所选文件过大") }
                    }
                }
            }
            if let coordinationError { throw coordinationError }
            guard let result else { throw Self.failure("文件提供方未返回文件，请重试") }
            return try result.get()
        }
        return try await withTaskCancellationHandler {
            do {
                let data = try await task.value
                try Task.checkCancellation()
                return data
            } catch { try Task.checkCancellation(); throw error }
        } onCancel: { task.cancel(); coordinator.value.cancel() }
    }

    /// Large media imports stream into an app-owned file on a background executor. The temporary
    /// file is removed on read failure/cancellation, and the original provider item is unchanged.
    func copyFile(to directory: URL, at index: Int = 0, maxBytes: Int = Int.max - 1) async throws -> URL {
        guard urls.indices.contains(index), directory.isFileURL, maxBytes > 0, maxBytes < Int.max else {
            throw Self.failure("所选文件无效")
        }
        try Task.checkCancellation()
        try beginRead()
        let url = urls[index]
        let coordinator = LocalDocumentReadCoordinator()
        let task = Task.detached(priority: .userInitiated) { [self] in
            defer { endRead() }
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = directory.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            let partial = directory.appendingPathComponent(".import-" + UUID().uuidString)
            var finished = false
            defer {
                try? FileManager.default.removeItem(at: partial)
                if !finished { try? FileManager.default.removeItem(at: target) }
            }
            var coordinationError: NSError?
            var result: Result<Void, Error>?
            coordinator.value.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinated in
                result = Result {
                    try Task.checkCancellation()
                    let values = try coordinated.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey])
                    guard values.isDirectory != true, values.isRegularFile == true else { throw Self.failure("请选择文件，不能选择文件夹") }
                    guard values.fileSize.map({ $0 <= maxBytes }) ?? true else { throw Self.failure("所选文件过大") }
                    guard let input = InputStream(url: coordinated), let output = OutputStream(url: partial, append: false) else {
                        throw Self.failure("无法复制所选文件")
                    }
                    input.open(); output.open()
                    defer { input.close(); output.close() }
                    var buffer = [UInt8](repeating: 0, count: 64 * 1024), total = 0
                    while true {
                        try Task.checkCancellation()
                        let count = input.read(&buffer, maxLength: min(buffer.count, maxBytes - total + 1))
                        guard count >= 0 else { throw input.streamError ?? Self.failure("读取所选文件失败") }
                        if count == 0 { break }
                        guard count <= maxBytes - total else { throw Self.failure("所选文件过大") }
                        try buffer.withUnsafeBufferPointer { bytes in
                            guard let base = bytes.baseAddress else { return }
                            var offset = 0
                            while offset < count {
                                try Task.checkCancellation()
                                let written = output.write(base.advanced(by: offset), maxLength: count - offset)
                                guard written > 0 else { throw output.streamError ?? Self.failure("保存文件失败，请检查可用空间") }
                                offset += written
                            }
                        }
                        total += count
                    }
                }
            }
            if let coordinationError { throw coordinationError }
            guard let result else { throw Self.failure("文件提供方未返回文件，请重试") }
            try result.get()
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: partial, to: target)
            try Task.checkCancellation()
            finished = true
            return target
        }
        return try await withTaskCancellationHandler {
            do {
                let target = try await task.value
                if Task.isCancelled { try? FileManager.default.removeItem(at: target); throw CancellationError() }
                return target
            } catch { try Task.checkCancellation(); throw error }
        } onCancel: { task.cancel(); coordinator.value.cancel() }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "LocalDocumentSelection", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

