import Foundation
// Ported from MacCat's HttpRangeDiscSource.swift. The HTTP identity, cancellation,
// bounded LRU and seek behavior stay aligned with the maintained local player.

/// Cancellation can be shared with a blocking open/read without retaining native handles.
public final class DiscCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var handlers: [UUID: () -> Void] = [:]
    public init() {}
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    public func cancel() {
        lock.lock(); stopped = true; let callbacks = Array(handlers.values); handlers.removeAll(); lock.unlock()
        callbacks.forEach { $0() }
    }
    func observe(_ callback: @escaping () -> Void) -> UUID {
        let id = UUID(); lock.lock()
        if stopped { lock.unlock(); callback() } else { handlers[id] = callback; lock.unlock() }
        return id
    }
    func remove(_ id: UUID) { lock.lock(); handlers.removeValue(forKey: id); lock.unlock() }
    func check() throws { if isCancelled { throw DiscError.cancelled } }
}

public enum DiscError: Error, Equatable, LocalizedError, Sendable {
    case invalidRange, invalidURL, cancelled, timeout, network, http(Int), malformedRange, resourceChanged, readLimit
    case remoteDirectory, libraryUnavailable, invalidDisc, noTitles, playlistNotFound(Int), closed, activeStreams, registration(Int32)
    case menuUnavailable, menuJavaUnavailable, menuInputUnavailable, menuReadFailed, encryptedDisc
    public var errorDescription: String? {
        switch self {
        case .invalidRange: return "原盘读取范围无效。"
        case .invalidURL: return "原盘地址或请求头无效。"
        case .cancelled: return "原盘读取已取消。"
        case .timeout: return "原盘线路读取超时，请重试或切换线路。"
        case .network: return "原盘线路连接失败，请重试或切换线路。"
        case .http(412): return "原盘线路返回 HTTP 412，请切换到快传或代理线路。"
        case .http(let code) where code == 408 || code == 429 || (500...599).contains(code):
            return "原盘线路暂时无法读取（HTTP \(code)），重试后仍未恢复，请稍后重试或切换线路。"
        case .http(let code): return "原盘需要随机读取，当前线路返回 HTTP \(code)，请切换支持 Range 的线路。"
        case .malformedRange: return "原盘服务器返回了不匹配的 Content-Range 或分块内容。"
        case .resourceChanged: return "原盘文件在播放期间发生变化，请重新解析播放地址。"
        case .readLimit: return "原盘诊断已达到读取字节上限。"
        case .remoteDirectory: return "远程 BDMV 需要完整目录访问，请选择 ISO 镜像或本地 BDMV 目录。"
        case .libraryUnavailable: return "蓝光读取组件不可用，请重新编译完整的映匣程序包。"
        case .invalidDisc: return "未找到可读取的蓝光原盘，请确认包含完整 BDMV 目录。"
        case .noTitles: return "原盘中没有可播放的影片标题，或需要交互式盘面菜单。"
        case .playlistNotFound(let number): return "原盘中没有标题 \(number)，请从默认标题重新播放。"
        case .closed: return "原盘读取已关闭。"
        case .activeStreams: return "上一个原盘的读取尚未结束。"
        case .registration: return "无法注册蓝光媒体读取接口。"
        case .menuUnavailable: return "当前原盘没有可用的盘面菜单，或蓝光菜单组件不可用。"
        case .menuJavaUnavailable: return "当前 iOS 版本不支持 BD-J 菜单，请选择可直接播放的正片标题。"
        case .menuInputUnavailable: return "当前原盘菜单暂不接受此操作。"
        case .menuReadFailed: return "原盘菜单读取失败，请重试或返回正片。"
        case .encryptedDisc: return "当前 iOS 蓝光组件不支持 AACS 或 BD+ 加密原盘。"
        }
    }
}

/// Synchronous, serialized reads for libbluray's worker-thread callbacks. Never call on the main thread.
/// URLSession response delegates validate headers before accepting any body bytes (including a full-file 200).
public final class HttpRangeDiscSource: @unchecked Sendable {
    public static let pageSize = 1024 * 1024
    public static let maxPages = 64
    // Keep small random metadata reads, but amortize HTTP/CDN latency across
    // contiguous movie data without adding parallel upstream connections.
    private static let readAheadPages = 16
    private let io = NSLock(), state = NSLock()
    private let url: URL, headers: [String: String], configuration: URLSessionConfiguration
    private let transport: DiscRangeTransport
    private let maximumDownloadedBytes: Int64?
    private let fetchQueue = DispatchQueue(label: "MacCat.disc-prefetch", qos: .userInitiated)
    private var stopped = false
    private var active: [UUID: DiscRangeRequest] = [:]
    private var pendingPages: [Int64: DiscPageRead] = [:]
    private var lastReadEnd: Int64?
    private var sequentialBytes = 0
    private var readAheadSuspended = false
    private var pages: [Int64: Data] = [:], lru: [Int64] = []
    private var fileLength: Int64?, validator: String?, validatorHeader: String?
    // Validators are scoped to a resource URI, not interchangeable across CDN targets.
    // Keep the complete final URL (including its query) private and require an explicit
    // reopen if it changes; we have no trusted cross-URI content identity from the source.
    private var resourceURL: String?
    private var received: Int64 = 0
    public var length: Int64? { io.lock(); defer { io.unlock() }; return fileLength }
    public var downloadedBytes: Int64 { state.lock(); defer { state.unlock() }; return received }
    public var cachedPages: Int { io.lock(); defer { io.unlock() }; return pages.count }

    public init(url: URL, headers: [String: String] = [:], configuration: URLSessionConfiguration = .ephemeral, maximumDownloadedBytes: Int64? = nil) throws {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, url.user == nil, url.password == nil else { throw DiscError.invalidURL }
        if let maximumDownloadedBytes, maximumDownloadedBytes < 0 { throw DiscError.invalidRange }
        let forbidden = Set(["range", "if-range", "accept-encoding", "host", "connection", "content-length", "transfer-encoding"])
        var cleaned: [String: String] = [:]
        for (key, value) in headers {
            guard !key.isEmpty, key.utf8.allSatisfy({ $0 > 32 && $0 < 127 && !"()<>@,;:\\\"/[]?={}".utf8.contains($0) }), !value.contains(where: { "\r\n\0".contains($0) }) else { throw DiscError.invalidURL }
            if !forbidden.contains(key.lowercased()) { cleaned[key] = value }
        }
        self.url = url; self.headers = cleaned
        self.maximumDownloadedBytes = maximumDownloadedBytes
        let prepared = configuration.copy() as! URLSessionConfiguration
        prepared.httpCookieStorage = nil; prepared.httpShouldSetCookies = false
        prepared.urlCredentialStorage = nil; prepared.urlCache = nil
        prepared.requestCachePolicy = .reloadIgnoringLocalCacheData
        prepared.httpMaximumConnectionsPerHost = 1
        // A silent CDN connection must not hold a seek for thirty seconds.
        // URLSession applies this idle timeout between response data packets;
        // a productive transfer still has the existing thirty-second budget.
        let timeout = prepared.timeoutIntervalForRequest
        prepared.timeoutIntervalForRequest = timeout.isFinite && timeout > 0 ? min(timeout, 8) : 8
        prepared.timeoutIntervalForResource = 30
        self.configuration = prepared
        transport = DiscRangeTransport(configuration: prepared)
    }
    public func cancel() {
        state.lock(); stopped = true; let requests = Array(active.values); state.unlock()
        requests.forEach { $0.cancel() }
        transport.close()
    }
    private func checkCancelled() throws {
        state.lock(); let value = stopped; state.unlock(); if value { throw DiscError.cancelled }
    }
    public func read(offset: Int64, count: Int, cancellation: DiscCancellation? = nil) throws -> Data {
        guard offset >= 0, count >= 0, count <= Self.pageSize * Self.maxPages, offset <= Int64.max - Int64(count) else { throw DiscError.invalidRange }
        io.lock(); defer { io.unlock() }
        try checkCancelled()
        try cancellation?.check()
        if lastReadEnd != offset {
            // A seek abandons the old transfer, but complete validated blocks
            // already downloaded by it remain useful for backward/repeated
            // seeks. Atomically stop publication while taking those blocks;
            // the incomplete response tail is never admitted to the LRU.
            let ready = pendingPages.values.flatMap { $0.cancelAndTakeReady() }
            pendingPages.removeAll()
            sequentialBytes = 0
            try cache(ready.sorted { $0.start < $1.start })
        }
        sequentialBytes = min(Self.pageSize * 2, sequentialBytes + count)
        // Metadata probes jump around the ISO. Start speculative reads only
        // after sustained sequential access, and keep diagnostic byte caps exact.
        let streaming = maximumDownloadedBytes == nil && sequentialBytes >= Self.pageSize
        defer {
            if cancellation?.isCancelled == true {
                pendingPages.values.forEach { $0.cancel() }; pendingPages.removeAll(); lastReadEnd = nil
            }
        }
        var result = Data(); var position = offset
        while result.count < count {
            try checkCancelled()
            try cancellation?.check()
            if let length = fileLength, position >= length { break }
            let index = position / Int64(Self.pageSize)
            let bytes: Data
            if let cached = pages[index] { bytes = cached }
            else {
                var job = pageJob(index)
                let batch: (pages: [DiscRangeResponse], complete: Bool)
                do { batch = try job.value(index: index, cancellation: cancellation) }
                catch {
                    // A failed speculative read must not make an otherwise
                    // valid demand fail. Stop read-ahead and retry once.
                    let connectionFailure = (error as? DiscError) == .network || (error as? DiscError) == .timeout
                    let transientHTTP: Bool
                    if case .http(let code) = error as? DiscError {
                        transientHTTP = code == 408 || code == 429 || (500...599).contains(code)
                    } else { transientHTTP = false }
                    guard connectionFailure || transientHTTP || job.speculative && Self.canRetrySerial(error) else {
                        pendingPages.removeValue(forKey: job.index)
                        throw error
                    }
                    try checkCancelled(); try cancellation?.check()
                    if job.speculative { readAheadSuspended = true }
                    pendingPages.values.forEach { $0.cancel() }; pendingPages.removeAll()
                    if connectionFailure { transport.reconnect() }
                    // Cancellation releases client tasks before a cloud server
                    // releases its connection/rate-limit slot. Back off once.
                    let retryAt = Date().addingTimeInterval(0.35)
                    while Date() < retryAt { try checkCancelled(); try cancellation?.check(); Thread.sleep(forTimeInterval: 0.01) }
                    job = pageJob(index)
                    do { batch = try job.value(index: index, cancellation: cancellation) }
                    catch { pendingPages.removeValue(forKey: job.index); throw error }
                }
                if batch.complete { pendingPages.removeValue(forKey: job.index) }
                try checkCancelled(); try cancellation?.check()
                // A queued response must also match the identity established
                // since it was created, before any bytes enter the cache.
                try cache(batch.pages)
                guard let requested = pages[index] else { throw DiscError.malformedRange }
                bytes = requested
            }
            if streaming && !readAheadSuspended, pendingPages.isEmpty, let length = fileLength {
                // A subscription's returned proxy may already provide its own
                // concurrency; signed direct lines may forbid it. Fetch one
                // contiguous window on one connection, keeping the next window
                // in flight while the current cached pages are consumed.
                let last = (length - 1) / Int64(Self.pageSize)
                if let next = (1...Self.readAheadPages).map({ index + Int64($0) }).first(where: { $0 <= last && pages[$0] == nil }) {
                    _ = pageJob(next, speculative: true)
                }
            }
            lru.removeAll { $0 == index }; lru.append(index)
            let within = Int(position % Int64(Self.pageSize)), available = min(count - result.count, bytes.count - within)
            guard available > 0 else { break }
            result.append(bytes[within..<(within + available)]); position += Int64(available)
        }
        lastReadEnd = position
        return result
    }
    private func cache(_ responses: [DiscRangeResponse]) throws {
        for response in responses {
            guard (fileLength == nil || fileLength == response.length),
                  (resourceURL == nil || resourceURL == response.resourceURL),
                  (validator == nil || (validator == response.validator && validatorHeader == response.validatorHeader)) else {
                pendingPages.values.forEach { $0.cancel() }; pendingPages.removeAll()
                throw DiscError.resourceChanged
            }
            fileLength = response.length; validator = response.validator; validatorHeader = response.validatorHeader
            resourceURL = response.resourceURL
            // Complete pages can feed the decoder while the same validated
            // response continues. Each page owns only its own storage.
            let page = response.start / Int64(Self.pageSize)
            pages[page] = response.data
            lru.removeAll { $0 == page }; lru.append(page)
            if pages.count > Self.maxPages, let oldest = lru.first { pages.removeValue(forKey: oldest); lru.removeFirst() }
        }
    }
    private static func canRetrySerial(_ error: Error) -> Bool {
        switch error as? DiscError {
        case .network, .timeout: return true
        case .http(let status): return [403, 408, 429].contains(status) || status >= 500
        default: return false
        }
    }
    private func pageJob(_ index: Int64, speculative: Bool = false) -> DiscPageRead {
        if let job = pendingPages.values.first(where: { index >= $0.index && index - $0.index < Int64($0.pageCount) }) { return job }
        let pageCount = speculative
            ? 1 + (1..<Self.readAheadPages).prefix(while: { pages[index + Int64($0)] == nil }).count : 1
        let job = DiscPageRead(index: index, pageCount: pageCount, speculative: speculative); pendingPages[index] = job
        let length = fileLength, validator = validator, header = validatorHeader, resource = resourceURL
        fetchQueue.async { [self] in
            job.finish(Result { try fetch(index, pageCount: pageCount, length: length, validator: validator, validatorHeader: header, resourceURL: resource, cancellation: job.cancellation, progress: { job.publish($0) }) })
        }
        return job
    }
    private func fetch(_ index: Int64, pageCount: Int, length: Int64?, validator: String?, validatorHeader: String?, resourceURL: String?, cancellation: DiscCancellation, progress: @escaping (DiscRangeResponse) -> Void) throws -> DiscRangeResponse {
        try checkCancelled(); try cancellation.check()
        let start = index * Int64(Self.pageSize)
        let span = min(Int64(Self.pageSize * pageCount - 1), Int64.max - start)
        let end = min(start + span, length.map { $0 - 1 } ?? Int64.max)
        if let maximumDownloadedBytes, downloadedBytes > maximumDownloadedBytes - (end - start + 1) { throw DiscError.readLimit }
        var request = URLRequest(url: url)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let validator { request.setValue(validator, forHTTPHeaderField: "If-Range") }
        func perform(_ request: URLRequest) throws -> DiscRangeResponse {
            var request = request
            request.timeoutInterval = configuration.timeoutIntervalForRequest
            let operation = DiscRangeRequest(start: start, end: end, length: length, validator: validator, validatorHeader: validatorHeader, resourceURL: resourceURL,
                progress: pageCount > 1 ? progress : nil, received: { [self] count in
                    // Partial attempts still spend the diagnostic byte budget.
                    state.lock(); received += Int64(count); state.unlock()
                })
            let id = UUID()
            state.lock()
            if stopped { state.unlock(); throw DiscError.cancelled }
            active[id] = operation; state.unlock()
            let observation = cancellation.observe { operation.cancel() }
            defer { cancellation.remove(observation); state.lock(); active.removeValue(forKey: id); state.unlock() }
            return try operation.run(request, transport: transport, timeout: configuration.timeoutIntervalForResource)
        }
        for _ in 0..<9 {
            let response = try perform(request)
            try checkCancelled(); try cancellation.check()
            if let redirect = response.redirect { request = redirect; continue }
            return response
        }
        throw DiscError.network
    }
    deinit { cancel() }
}

private final class DiscPageRead: @unchecked Sendable {
    let cancellation = DiscCancellation()
    let index: Int64, pageCount: Int
    let speculative: Bool
    private let condition = NSCondition()
    private var ready: [Int64: DiscRangeResponse] = [:]
    private var completion: Result<Void, Error>?
    init(index: Int64, pageCount: Int, speculative: Bool) { self.index = index; self.pageCount = pageCount; self.speculative = speculative }
    func publish(_ page: DiscRangeResponse) {
        condition.lock(); defer { condition.unlock() }
        guard completion == nil else { return }
        ready[page.start / Int64(HttpRangeDiscSource.pageSize)] = page
        condition.broadcast()
    }
    func finish(_ value: Result<DiscRangeResponse, Error>) {
        condition.lock(); defer { condition.unlock() }
        guard completion == nil else { return }
        switch value {
        case .success(let page):
            ready[page.start / Int64(HttpRangeDiscSource.pageSize)] = page
            completion = .success(())
        case .failure(let error):
            ready.removeAll(); completion = .failure(error)
        }
        condition.broadcast()
    }
    func cancel() { finish(.failure(DiscError.cancelled)); cancellation.cancel() }
    func cancelAndTakeReady() -> [DiscRangeResponse] {
        condition.lock()
        let pages = Array(ready.values); ready.removeAll()
        completion = .failure(DiscError.cancelled)
        condition.broadcast(); condition.unlock()
        cancellation.cancel()
        return pages
    }
    func value(index: Int64, cancellation caller: DiscCancellation?) throws -> (pages: [DiscRangeResponse], complete: Bool) {
        let observation = caller?.observe { self.cancel() }
        defer { if let observation { caller?.remove(observation) } }
        condition.lock(); defer { condition.unlock() }
        while ready[index] == nil && completion == nil { condition.wait() }
        if let completion { try completion.get() }
        guard ready[index] != nil else { throw DiscError.malformedRange }
        let pages = ready.values.sorted { $0.start < $1.start }; ready.removeAll()
        return (pages, completion != nil)
    }
}

private struct DiscRangeResponse {
    let data: Data, length: Int64, validator: String?, validatorHeader: String?
    var resourceURL: String? = nil
    var redirect: URLRequest? = nil
    var start: Int64 = 0
}

/// A disc keeps its HTTP connection pool across uncached pages. Per-task routing
/// prevents a late response from a cancelled read reaching its replacement.
private final class DiscRangeTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let configuration: URLSessionConfiguration
    private var session: URLSession?
    private var operations: [ObjectIdentifier: DiscRangeRequest] = [:]
    private var closed = false
    init(configuration: URLSessionConfiguration) { self.configuration = configuration; super.init() }
    func task(_ request: URLRequest, operation: DiscRangeRequest) throws -> URLSessionDataTask {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { throw DiscError.cancelled }
        if session == nil { session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil) }
        let task = session!.dataTask(with: request)
        operations[ObjectIdentifier(task)] = operation
        return task
    }
    func forget(_ task: URLSessionTask) {
        lock.lock(); operations.removeValue(forKey: ObjectIdentifier(task)); lock.unlock()
    }
    private func operation(_ task: URLSessionTask) -> DiscRangeRequest? {
        lock.lock(); defer { lock.unlock() }; return operations[ObjectIdentifier(task)]
    }
    func reconnect() {
        // Called only after the serialized request has failed. A fresh pool
        // avoids reusing its stalled HTTP/2 connection; object identity keeps
        // late callbacks separate when the new session reuses task numbers.
        lock.lock(); let old = session; session = nil; operations.removeAll(); lock.unlock()
        old?.invalidateAndCancel()
    }
    func close() {
        lock.lock(); closed = true; let current = session; session = nil; operations.removeAll(); lock.unlock()
        current?.invalidateAndCancel()
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let operation = operation(dataTask) else { completionHandler(.cancel); return }
        operation.urlSession(session, dataTask: dataTask, didReceive: response, completionHandler: completionHandler)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        operation(dataTask)?.urlSession(session, dataTask: dataTask, didReceive: data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let operation = operation(task); forget(task)
        operation?.urlSession(session, task: task, didCompleteWithError: error)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let operation = operation(task) else { completionHandler(nil); return }
        operation.urlSession(session, task: task, willPerformHTTPRedirection: response,
                             newRequest: request, completionHandler: completionHandler)
    }
}

private final class DiscRangeRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let condition = NSCondition()
    private let start: Int64, end: Int64, previousLength: Int64?
    private let previousValidator: String?, previousValidatorHeader: String?
    private let previousResourceURL: String?
    private let progress: ((DiscRangeResponse) -> Void)?
    private let received: ((Int) -> Void)?
    private var task: URLSessionDataTask?, done = false, failure: DiscError?
    private var bytes = Data(), expected = 0, length: Int64 = 0, validator: String?, validatorHeader: String?
    private var receivedBytes = 0, publishedBytes = 0
    private var redirect: URLRequest?
    private var resourceURL: String?
    init(start: Int64, end: Int64, length: Int64?, validator: String?, validatorHeader: String?, resourceURL: String?, progress: ((DiscRangeResponse) -> Void)? = nil, received: ((Int) -> Void)? = nil) {
        self.start = start; self.end = end; previousLength = length
        previousValidator = validator; previousValidatorHeader = validatorHeader
        previousResourceURL = resourceURL
        self.progress = progress
        self.received = received
    }
    func cancel() {
        condition.lock(); failure = .cancelled; done = true; let current = task; condition.broadcast(); condition.unlock()
        current?.cancel()
    }
    func run(_ request: URLRequest, transport: DiscRangeTransport, timeout: TimeInterval) throws -> DiscRangeResponse {
        condition.lock()
        defer {
            condition.unlock()
            if let task { transport.forget(task); task.cancel() }
        }
        if !done { task = try transport.task(request, operation: self); task?.resume() }
        let deadline = Date().addingTimeInterval(timeout + 1)
        while !done {
            if !condition.wait(until: deadline) { failure = .timeout; done = true }
        }
        if let failure { throw failure }
        if let redirect { return DiscRangeResponse(data: Data(), length: 0, validator: nil, validatorHeader: nil, redirect: redirect) }
        guard receivedBytes == expected, expected > 0, let resourceURL else { throw DiscError.malformedRange }
        return DiscRangeResponse(data: bytes, length: length, validator: validator, validatorHeader: validatorHeader, resourceURL: resourceURL, start: start + Int64(publishedBytes))
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        condition.lock(); defer { condition.unlock() }
        guard !done else { completionHandler(.cancel); return }
        do {
            guard let response = response as? HTTPURLResponse else { throw DiscError.network }
            guard response.statusCode == 206 else { throw DiscError.http(response.statusCode) }
            guard let finalURL = response.url?.absoluteString else { throw DiscError.malformedRange }
            if let previousResourceURL, previousResourceURL != finalURL { throw DiscError.resourceChanged }
            resourceURL = finalURL
            let encoding = response.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
            guard encoding == nil || encoding == "identity" else { throw DiscError.malformedRange }
            let range = response.value(forHTTPHeaderField: "Content-Range") ?? ""
            let parts = range.split(whereSeparator: { " -/".contains($0) })
            guard parts.count == 4, parts[0] == "bytes", let from = Int64(parts[1]), let to = Int64(parts[2]), let total = Int64(parts[3]), total > 0,
                  from == start, to == min(end, total - 1), to >= from, to - from <= end - start else { throw DiscError.malformedRange }
            if let previousLength, previousLength != total { throw DiscError.resourceChanged }
            length = total; expected = Int(to - from + 1)
            if let value = response.value(forHTTPHeaderField: "Content-Length"), Int(value) != expected { throw DiscError.malformedRange }
            if let etag = response.value(forHTTPHeaderField: "ETag"), !etag.hasPrefix("W/") { validator = etag; validatorHeader = "ETag" }
            else { validator = response.value(forHTTPHeaderField: "Last-Modified"); validatorHeader = validator == nil ? nil : "Last-Modified" }
            if let previousValidator, previousValidator != validator || previousValidatorHeader != validatorHeader { throw DiscError.resourceChanged }
            completionHandler(.allow)
        } catch {
            failure = error as? DiscError ?? .network; done = true; condition.broadcast(); completionHandler(.cancel)
        }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        condition.lock(); defer { condition.unlock() }
        guard !done else { return }
        guard expected > 0, data.count <= expected - receivedBytes else {
            failure = .malformedRange; done = true; condition.broadcast(); dataTask.cancel(); return
        }
        bytes.append(data); receivedBytes += data.count
        if let progress {
            let pageSize = HttpRangeDiscSource.pageSize
            // Leave the final page (including a short EOF page) unpublished
            // until the task completes with the exact Content-Range length.
            while bytes.count >= pageSize, publishedBytes + pageSize < expected {
                let split = bytes.startIndex + pageSize
                let page = bytes.subdata(in: bytes.startIndex..<split)
                bytes = bytes.subdata(in: split..<bytes.endIndex)
                let offset = start + Int64(publishedBytes); publishedBytes += pageSize
                progress(DiscRangeResponse(data: page, length: length, validator: validator,
                    validatorHeader: validatorHeader, resourceURL: resourceURL, start: offset))
            }
        }
        // Publish complete blocks before exposing their bytes to observers.
        // A seek can immediately harvest a completed block once the downloaded
        // count advances, instead of racing the gap before job.publish.
        received?(data.count)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        condition.lock(); defer { condition.unlock() }
        guard !done else { return }
        if let error { failure = (error as NSError).code == NSURLErrorTimedOut ? .timeout : .network }
        done = true; condition.broadcast()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        condition.lock(); defer { condition.unlock() }
        guard !done, let old = response.url, let new = request.url,
              ["http", "https"].contains(new.scheme ?? ""), new.user == nil, new.password == nil,
              !(old.scheme == "https" && new.scheme != "https") else {
            failure = .network; done = true; condition.broadcast(); completionHandler(nil); return
        }
        var next = URLRequest(url: new)
        let sameOrigin = old.scheme?.lowercased() == new.scheme?.lowercased() && old.host?.lowercased() == new.host?.lowercased()
            && (old.port ?? (old.scheme == "https" ? 443 : 80)) == (new.port ?? (new.scheme == "https" ? 443 : 80))
        // New origins receive only byte-range mechanics, never arbitrary source credentials.
        if sameOrigin { next.allHTTPHeaderFields = task.currentRequest?.allHTTPHeaderFields }
        next.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        next.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let previousValidator { next.setValue(previousValidator, forHTTPHeaderField: "If-Range") }
        // CFNetwork can restore original headers even after clearing newRequest.
        // Refuse its automatic redirect and issue a fresh task from the outer reader.
        redirect = next; done = true; condition.broadcast(); completionHandler(nil)
    }
}
