import Foundation
import AVFoundation
import Network

/// A virtual clear MP4. AVPlayer requests byte ranges; only those samples are fetched and
/// decrypted. Neither opening an episode nor seeking requires a complete local movie.
public enum HongguoStreams {
    /// What the encrypted files' CDN wants on a retry after a 403 (Hongguo's app pages).
    static let mediaReferer = "https://novelquickapp.com/"
    public static let scheme = "tvbox-hongguo"
    public static let forwardBufferDuration: Double = 60

    public struct Statistics: Sendable {
        public let received: Int
        public let total: Int
        public let cached: Int
        public let requests: Int
        public let bufferedThrough: Double
    }

    static func register(url: URL, backups: [URL] = [], key: String, headers: [String: String], http: HTTPClient) throws -> URL {
        guard key.count == 32 else { throw HongguoMP4.Failure.invalid }
        let bytes = stride(from: 0, to: 32, by: 2).compactMap { offset -> UInt8? in
            let start = key.index(key.startIndex, offsetBy: offset)
            return UInt8(key[start..<key.index(start, offsetBy: 2)], radix: 16)
        }
        guard bytes.count == 16 else { throw HongguoMP4.Failure.invalid }
        return HongguoStreamStore.shared.add(HongguoByteStream(urls: [url] + backups, key: Data(bytes), headers: headers, http: http))
    }

    public static func asset(for url: URL) -> AVURLAsset? {
        guard HongguoStreamStore.shared.stream(url) != nil else { return nil }
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(HongguoResourceLoader.shared, queue: HongguoResourceLoader.shared.queue)
        return asset
    }

    /// The same virtual clear MP4 over streaming HTTP for FFmpeg-based players.
    public static func playbackURL(for url: URL) async throws -> URL {
        guard HongguoStreamStore.shared.stream(url) != nil, let id = url.host else { throw TVError.invalidURL }
        return try await HongguoHTTPServer.shared.address(id: id)
    }

    public static func updatePosition(for url: URL, seconds: Double) {
        guard seconds.isFinite, let stream = HongguoStreamStore.shared.stream(url) else { return }
        Task { await stream.updatePosition(seconds) }
    }

    public static func stop(_ url: URL) {
        if let id = url.host { Task { await HongguoHTTPServer.shared.stop(id: id) } }
        HongguoResourceLoader.shared.cancel(url)
        if let stream = HongguoStreamStore.shared.stream(url) { Task { await stream.clear() } }
    }

    public static func statistics(for url: URL) async -> Statistics? {
        guard let stream = HongguoStreamStore.shared.stream(url) else { return nil }
        return await stream.statistics
    }
}

/// Bounded decrypted reads with one task per HTTP request. Closing a socket or
/// stopping an episode cancels pending reads before their reply can reach a new media item.
private actor HongguoHTTPServer {
    static let shared = HongguoHTTPServer()
    private var listener: NWListener?
    private var base: URL?
    private var starting: Task<URL, Error>?
    private let token = UUID().uuidString.lowercased()
    private var active: [String: Set<UUID>] = [:]
    private var requests: [UUID: Task<Void, Never>] = [:]
    func address(id: String) async throws -> URL {
        if let base, listener?.state == .ready { return base.appendingPathComponent(id + "/video.mp4") }
        if let starting { return try await starting.value.appendingPathComponent(id + "/video.mp4") }
        let task = Task { try await self.listen() }; starting = task
        defer { starting = nil }
        let base = try await task.value
        return base.appendingPathComponent(id + "/video.mp4")
    }
    private func listen() async throws -> URL {
        listener?.cancel(); base = nil
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let server = try NWListener(using: parameters); listener = server
        server.newConnectionHandler = { [token] connection in
            connection.start(queue: .global(qos: .userInitiated))
            Self.receive(connection, data: Data(), token: token)
        }
        let once = OneShot<URL>()
        let url = try await withCheckedThrowingContinuation { continuation in
            once.set(continuation)
            server.stateUpdateHandler = { [token] state in
                switch state {
                case .ready:
                    guard let port = server.port else { return }
                    once.resume(.success(URL(string: "http://127.0.0.1:\(port.rawValue)/\(token)/")!))
                case .failed(let error): once.resume(.failure(error))
                case .cancelled: once.resume(.failure(CancellationError()))
                default: break
                }
            }
            server.start(queue: .global(qos: .userInitiated))
        }
        base = url; return url
    }
    func stop(id: String) {
        let pending = active.removeValue(forKey: id) ?? []
        for key in pending { requests.removeValue(forKey: key)?.cancel() }
    }
    private func cancel(_ key: UUID) { requests[key]?.cancel() }
    private func finished(_ key: UUID, media: String) { requests[key] = nil; active[media]?.remove(key) }
    private nonisolated static func receive(_ connection: NWConnection, data: Data, token: String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { bytes, _, complete, error in
            var buffer = data; if let bytes { buffer.append(bytes) }
            if buffer.range(of: Data("\r\n\r\n".utf8)) != nil {
                Task { await shared.serve(connection, request: buffer, token: token) }
            } else if complete || error != nil || buffer.count > 16384 { connection.cancel() }
            else { receive(connection, data: buffer, token: token) }
        }
    }
    private func serve(_ connection: NWConnection, request: Data, token: String) {
        let lines = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ")
        guard first.count >= 2, ["GET", "HEAD"].contains(String(first[0])) else { connection.cancel(); return }
        let parts = first[1].split(separator: "/")
        guard parts.count == 3, parts[0] == Substring(token), UUID(uuidString: String(parts[1])) != nil,
              parts[2] == "video.mp4", let url = URL(string: "\(HongguoStreams.scheme)://\(parts[1])/video.mp4"),
              let stream = HongguoStreamStore.shared.stream(url) else { connection.cancel(); return }
        let media = String(parts[1]), key = UUID(), head = first[0] == "HEAD"
        let range = lines.first { $0.lowercased().hasPrefix("range:") }.map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        active[media, default: []].insert(key)
        let job = Task {
            defer { connection.cancel(); self.finished(key, media: media) }
            do {
                let index = try await stream.metadata(), size = index.length
                var start = 0, end = size - 1, status = 200
                if let range {
                    guard let match = range.firstMatch(of: /^bytes=(\d*)-(\d*)$/), !match.1.isEmpty || !match.2.isEmpty else { throw TVError.invalidURL }
                    if match.1.isEmpty { start = max(0, size - (Int(match.2) ?? 0)) }
                    else { start = Int(match.1) ?? size; end = min(size - 1, Int(match.2) ?? size - 1) }
                    guard start >= 0, start < size, start <= end else { throw TVError.invalidURL }
                    status = 206
                }
                let contentRange = status == 206 ? "Content-Range: bytes \(start)-\(end)/\(size)\r\n" : ""
                try await Self.send(Data("HTTP/1.1 \(status) \(status == 206 ? "Partial Content" : "OK")\r\nContent-Type: video/mp4\r\nContent-Length: \(end-start+1)\r\nAccept-Ranges: bytes\r\n\(contentRange)Cache-Control: no-store\r\nConnection: close\r\n\r\n".utf8), connection)
                if head { return }
                try await stream.beginRequest(at: start)
                var position = start
                while position <= end {
                    try Task.checkCancellation()
                    let bytes = try await stream.read(at: position, count: min(128 << 10, end-position+1), bounded: false)
                    guard !bytes.isEmpty else { break }
                    try await Self.send(bytes, connection); position += bytes.count
                }
            } catch {
                if !Task.isCancelled { Diagnostics.shared.record(.warning, "hongguo.stream", "HTTP playback read failed: \(error.localizedDescription)") }
            }
        }
        requests[key] = job
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { _, _, complete, error in
            if complete || error != nil { Task { await self.cancel(key) } }
        }
        connection.stateUpdateHandler = { state in
            switch state { case .cancelled, .failed: Task { await self.cancel(key) }; default: break }
        }
    }
    private nonisolated static func send(_ data: Data, _ connection: NWConnection) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
}

private final class HongguoStreamStore: @unchecked Sendable {
    static let shared = HongguoStreamStore()
    private let lock = NSLock()
    private var streams: [URL: HongguoByteStream] = [:]
    private var order: [URL] = []

    func add(_ stream: HongguoByteStream) -> URL {
        let url = URL(string: "\(HongguoStreams.scheme)://\(UUID().uuidString.lowercased())/video.mp4")!
        let retired: [URL] = lock.withLock {
            streams[url] = stream; order.append(url)
            var old: [URL] = []
            while order.count > 4 { let first = order.removeFirst(); streams[first] = nil; old.append(first) }
            return old
        }
        for old in retired { HongguoResourceLoader.shared.cancel(old) }
        return url
    }
    func stream(_ url: URL) -> HongguoByteStream? { lock.withLock { streams[url] } }
}

/// Validates Range before consuming the body. A server that ignores Range must not silently
/// turn a 128 KB playback request into a full-episode download.
/// The app API also lists backup links: the same file on other CDN nodes. When a node fails,
/// this and every later range moves to the next one.
actor HongguoRangeReader {
    let urls: [URL]
    let headers: [String: String]
    let http: HTTPClient
    private var usesReferer = false
    private var mirror = 0
    private var length: Int?

    init(urls: [URL], headers: [String: String], http: HTTPClient) {
        precondition(!urls.isEmpty)
        self.urls = urls; self.headers = headers; self.http = http
    }

    func read(_ range: Range<Int>) async throws -> (data: Data, length: Int) {
        while true {
            let index = mirror
            do {
                let reply = try await read(range, from: urls[index])
                // Every node must serve the same file.
                if let length, reply.length != length { throw HongguoMP4.Failure.invalid }
                length = reply.length
                return reply
            } catch {
                if error is CancellationError || Task.isCancelled { throw error }
                guard index + 1 < urls.count else { throw error }
                // Another range may already have moved on while this one waited.
                if mirror == index {
                    mirror = index + 1; usesReferer = false
                    Diagnostics.shared.record(.info, "hongguo.stream", "node \(index) failed (\(error.localizedDescription)); trying backup \(index + 1) of \(urls.count - 1)")
                }
            }
        }
    }

    private func read(_ range: Range<Int>, from url: URL) async throws -> (data: Data, length: Int) {
        guard range.lowerBound >= 0, !range.isEmpty, range.count <= 16 << 20 else { throw HongguoMP4.Failure.invalid }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let retry = usesReferer
        if retry { request.setValue(HongguoStreams.mediaReferer, forHTTPHeaderField: "Referer") }
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (bytes, response) = try await http.session.bytes(for: request)
        let task = bytes.task
        defer { task.cancel() }
        let httpResponse = response as? HTTPURLResponse
        if range.lowerBound == 0 || httpResponse?.statusCode != 206 {
            Diagnostics.shared.record(.debug, "hongguo.stream", "range host=\(response.url?.host() ?? "-") requested=\(range.lowerBound)-\(range.upperBound - 1) status=\(httpResponse?.statusCode ?? 0) referer=\(retry) contentRange=\(httpResponse?.value(forHTTPHeaderField: "Content-Range") ?? "-") contentLength=\(response.expectedContentLength)")
        }
        // App CDN nodes have different Referer policies. Match the upstream client: omit it
        // first, add the app's Referer only after 403, and reuse that choice for later ranges.
        if httpResponse?.statusCode == 403, !retry {
            task.cancel()
            try Task.checkCancellation()
            usesReferer = true
            return try await read(range, from: url)
        }
        if let status = httpResponse?.statusCode, status >= 400 {
            var detail = Data()
            for try await byte in bytes.prefix(512) { detail.append(byte) }
            Diagnostics.shared.record(.error, "hongguo.stream", "HTTP \(status) \(String(decoding: detail, as: UTF8.self))")
            throw TVError.http(status)
        }
        guard let response = response as? HTTPURLResponse, response.statusCode == 206,
              let value = response.value(forHTTPHeaderField: "Content-Range"),
              let match = value.firstMatch(of: /^bytes (\d+)-(\d+)\/(\d+)$/),
              let first = Int(match.1), let last = Int(match.2), let length = Int(match.3),
              (1...512 << 20).contains(length), first == range.lowerBound,
              last == min(range.upperBound, length) - 1, last >= first,
              response.expectedContentLength == -1 || response.expectedContentLength == Int64(last - first + 1) else {
            throw HongguoMP4.Failure.invalid
        }
        return (try await Self.body(bytes, expected: last - first + 1), length)
    }

    /// Off the actor on purpose: each step of an AsyncBytes loop in actor-isolated code hops to the
    /// generic executor and back, two task switches per byte, which kept a core busy while streaming.
    private nonisolated static func body(_ bytes: sending URLSession.AsyncBytes, expected: Int) async throws -> Data {
        var data = [UInt8](); data.reserveCapacity(expected)
        for try await byte in bytes {
            guard data.count < expected else { throw HongguoMP4.Failure.invalid }
            data.append(byte)
            if data.count & 0x3fff == 0 { try Task.checkCancellation() }
        }
        try Task.checkCancellation()
        guard data.count == expected else { throw HongguoMP4.Failure.invalid }
        return Data(data)
    }
}

actor HongguoByteStream {
    static let chunkSize = 128 << 10
    static let cacheLimit = 16 << 20
    private let reader: HongguoRangeReader
    private let key: Data
    private var indexTask: Task<HongguoStreamIndex, Error>?
    private var index: HongguoStreamIndex?
    private var prefix = Data()
    private struct Chunk { let range: Range<Int>; let data: Data; let time: ClosedRange<Double>? }
    private var cache: [Chunk] = []
    private var position: Double = 0
    private var lastDeliveredOffset: Int?
    private var received = 0
    private var requests = 0

    init(urls: [URL], key: Data, headers: [String: String], http: HTTPClient) {
        reader = HongguoRangeReader(urls: urls, headers: headers, http: http)
        self.key = key
    }

    var statistics: HongguoStreams.Statistics {
        .init(received: received, total: index?.length ?? 0, cached: cache.reduce(0) { $0 + $1.data.count }, requests: requests,
              bufferedThrough: cache.compactMap { $0.time?.upperBound }.max() ?? 0)
    }

    func metadata() async throws -> HongguoStreamIndex {
        if let index { return index }
        if let indexTask { return try await indexTask.value }
        let task = Task { try await self.loadIndex() }
        indexTask = task
        defer { indexTask = nil }
        let value = try await task.value
        index = value
        Diagnostics.shared.record(.info, "hongguo.stream", "index bytes=\(received) total=\(value.length) duration=\(Int(value.duration))s")
        return value
    }

    private func remote(_ range: Range<Int>) async throws -> (data: Data, length: Int) {
        let reply = try await reader.read(range)
        received += reply.data.count; requests += 1
        return reply
    }

    private func loadIndex() async throws -> HongguoStreamIndex {
        let first = try await remote(0..<16384)
        prefix = first.data
        let length = first.length
        Diagnostics.shared.record(.debug, "hongguo.stream", "prefix bytes=\(prefix.count) total=\(length) signature=\(prefix.prefix(16).map { String(format: "%02x", $0) }.joined())")
        var at = 0, count = 0, movie: (Data, Int)?, media: [Range<Int>] = []
        while at < length {
            try Task.checkCancellation()
            count += 1
            guard count <= 128, at <= length - 8 else { throw HongguoMP4.Failure.invalid }
            let upper = min(at + 16, length)
            let header: Data
            if upper <= prefix.count { header = Data(prefix[at..<upper]) }
            else { header = try await remote(at..<upper).data }
            var size = try HongguoMP4.integer(header, 0), headerSize = 8
            if size == 1 { size = try HongguoMP4.integer(header, 8, 8); headerSize = 16 }
            if size == 0 { size = length - at }
            guard size >= headerSize, size <= length - at else { throw HongguoMP4.Failure.invalid }
            let type = String(decoding: header[4..<8], as: UTF8.self)
            Diagnostics.shared.record(.debug, "hongguo.stream", "box type=\(type) at=\(at) size=\(size)")
            if type == "moof" { throw HongguoMP4.Failure.invalid }
            if type == "moov" {
                guard movie == nil, size <= 16 << 20 else { throw HongguoMP4.Failure.invalid }
                let data = at + size <= prefix.count ? Data(prefix[at..<at + size]) : try await remote(at..<at + size).data
                movie = (data, at)
            }
            if type == "mdat" { media.append(at + headerSize..<at + size) }
            at += size
        }
        guard let movie, !media.isEmpty else { throw HongguoMP4.Failure.invalid }
        Diagnostics.shared.record(.debug, "hongguo.stream", "parse index movie=\(movie.0.count) mediaRanges=\(media.count)")
        return try HongguoStreamIndex(movie: movie.0, at: movie.1, length: length, media: media)
    }

    func updatePosition(_ seconds: Double) {
        position = max(0, seconds)
        prune()
    }

    /// AVKit seeks may request the destination before currentTime changes. A discontinuous new
    /// request can move the window; continuing an existing read cannot push it forward forever.
    func beginRequest(at offset: Int) async throws {
        let index = try await metadata()
        if let time = index.samples(in: offset..<offset + 1).first?.time,
           offset != lastDeliveredOffset,
           abs(time - position) > HongguoStreams.forwardBufferDuration {
            Diagnostics.shared.record(.debug, "hongguo.stream", "seek window from=\(Int(position)) to=\(Int(time))s")
            position = time
            prune()
        }
    }

    func read(at offset: Int, count: Int, bounded: Bool = true) async throws -> Data {
        let index = try await metadata()
        guard offset >= 0, offset < index.length, count > 0 else { throw HongguoMP4.Failure.invalid }
        let end = min(index.length, offset + min(count, Self.chunkSize))
        // Metadata is available regardless of the playhead, including a moov at the file's end.
        if offset >= index.movieRange.lowerBound, offset < index.movieRange.upperBound {
            return Data(index.movie[offset - index.movieRange.lowerBound..<min(end, index.movieRange.upperBound) - index.movieRange.lowerBound])
        }
        var requested = offset..<end
        if offset < index.movieRange.lowerBound { requested = offset..<min(end, index.movieRange.lowerBound) }
        let covered = index.samples(in: requested)
        if bounded, let time = covered.map(\.time).min() {
            while time > position + HongguoStreams.forwardBufferDuration {
                try await Task.sleep(for: .milliseconds(200))
            }
        }
        try Task.checkCancellation()
        // A chunk is widened to whole samples, so the player's next read usually starts inside it. Serve
        // what the chunk holds and let the next read start at its end, rather than fetching the overlap again.
        if let i = cache.firstIndex(where: { $0.range.contains(requested.lowerBound) }) {
            let chunk = cache.remove(at: i); cache.append(chunk)
            let end = min(requested.upperBound, chunk.range.upperBound)
            lastDeliveredOffset = end
            return Data(chunk.data[requested.lowerBound - chunk.range.lowerBound..<end - chunk.range.lowerBound])
        }
        let expanded = index.expanded(requested)
        let encrypted: Data
        if expanded.upperBound <= prefix.count { encrypted = Data(prefix[expanded]) }
        else {
            let reply = try await remote(expanded)
            guard reply.length == index.length else { throw HongguoMP4.Failure.invalid }
            encrypted = reply.data
        }
        let decrypted = try index.decrypt(encrypted, at: expanded.lowerBound, key: key)
        let times = index.samples(in: expanded)
        let time = times.map(\.time).min().flatMap { low in times.map(\.endTime).max().map { low...$0 } }
        cache.append(Chunk(range: expanded, data: decrypted, time: time))
        lastDeliveredOffset = requested.upperBound
        prune()
        return Data(decrypted[requested.lowerBound - expanded.lowerBound..<requested.upperBound - expanded.lowerBound])
    }

    private func prune() {
        cache.removeAll { chunk in
            guard let time = chunk.time else { return false }
            return time.upperBound < position - 5 || time.lowerBound > position + HongguoStreams.forwardBufferDuration + 5
        }
        var total = cache.reduce(0) { $0 + $1.data.count }
        while total > Self.cacheLimit, !cache.isEmpty { total -= cache.removeFirst().data.count }
    }

    func clear() {
        indexTask?.cancel(); indexTask = nil
        cache.removeAll(); position = 0; lastDeliveredOffset = nil
    }
}

/// AVFoundation request objects stay on one serial queue. The async workers handle only byte
/// ranges and re-enter that queue to respond, so cancelled requests never receive late data.
private final class HongguoResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let shared = HongguoResourceLoader()
    let queue = DispatchQueue(label: "tvbox.hongguo.loader")
    private struct Pending {
        let url: URL
        let request: AVAssetResourceLoadingRequest
        let task: Task<Void, Never>
    }
    private var pending: [ObjectIdentifier: Pending] = [:]

    func resourceLoader(_ loader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = request.request.url, let stream = HongguoStreamStore.shared.stream(url) else { return false }
        let id = ObjectIdentifier(request)
        let offset = request.dataRequest.map { max($0.requestedOffset, $0.currentOffset) }
        let length = request.dataRequest?.requestedLength ?? 0
        let toEnd = request.dataRequest?.requestsAllDataToEndOfResource ?? false
        Diagnostics.shared.record(.debug, "hongguo.stream", "request offset=\(offset ?? -1) length=\(length) toEnd=\(toEnd) info=\(request.contentInformationRequest != nil)")
        let task = Task { [weak self] in
            do {
                let metadata = try await stream.metadata()
                guard let self else { return }
                let active = self.queue.sync {
                    guard let request = self.pending[id]?.request else { return false }
                    request.contentInformationRequest?.contentType = AVFileType.mp4.rawValue
                    request.contentInformationRequest?.contentLength = Int64(metadata.length)
                    request.contentInformationRequest?.isByteRangeAccessSupported = true
                    return true
                }
                guard active else { return }
                if let offset {
                    guard offset >= 0, offset <= Int64(metadata.length), length >= 0 else { throw HongguoMP4.Failure.invalid }
                    var at = Int(offset)
                    let end = toEnd ? metadata.length : min(metadata.length, at + length)
                    try await stream.beginRequest(at: at)
                    while at < end {
                        try Task.checkCancellation()
                        let bytes = try await stream.read(at: at, count: end - at)
                        let delivered = self.queue.sync {
                            guard let request = self.pending[id]?.request, !request.isCancelled else { return false }
                            request.dataRequest?.respond(with: bytes)
                            return true
                        }
                        guard delivered else { return }
                        at += bytes.count
                    }
                }
                self.finish(id, error: nil)
            } catch {
                // A seek or a closed player cancels the request (URLError -999 too): not a failure.
                Diagnostics.shared.failure("hongguo.stream", "request failed offset=\(offset ?? -1)", error)
                self?.finish(id, error: error is CancellationError ? error : TVError.unsupported(L10n.text("This Hongguo video could not be prepared for playback. Please try again.")))
            }
        }
        pending[id] = Pending(url: url, request: request, task: task)
        return true
    }

    private func finish(_ id: ObjectIdentifier, error: Error?) {
        queue.async {
            guard let value = self.pending.removeValue(forKey: id), !value.request.isCancelled else { return }
            if let error { value.request.finishLoading(with: error) } else { value.request.finishLoading() }
        }
    }
    func resourceLoader(_ loader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        pending.removeValue(forKey: ObjectIdentifier(request))?.task.cancel()
    }
    func cancel(_ url: URL) {
        queue.async {
            for id in self.pending.keys.filter({ self.pending[$0]?.url == url }) {
                guard let value = self.pending.removeValue(forKey: id) else { continue }
                value.task.cancel()
                if !value.request.isCancelled { value.request.finishLoading(with: CancellationError()) }
            }
        }
    }
}
