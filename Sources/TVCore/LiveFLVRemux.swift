import Foundation

/// Continuous HTTP FLV has neither byte ranges nor a file length. Keep one connection and cut at video
/// keyframes, then use the same in-memory FFmpeg repackager as HLS. No downloaded file survives playback.
public enum LiveFLVRemux {
    public static func open(_ url: URL, headers: [String: String]) async throws -> URL {
        try await open(url, headers: headers, configuration: HLSRemuxSession.network.configuration)
    }

    static func open(_ url: URL, headers: [String: String], configuration: URLSessionConfiguration) async throws -> URL {
        let stream = LiveFLVSession(url: url, headers: headers, configuration: configuration)
        do {
            try await stream.open()
            try Task.checkCancellation()
            RemuxStore.shared.add(stream)
            let base = try await RemuxServer.shared.base()
            try Task.checkCancellation()
            return base.appending(path: "\(stream.id)/master.m3u8")
        } catch {
            _ = RemuxStore.shared.remove(stream.id)
            stream.close()
            throw error
        }
    }
}

/// FLV tags, split at keyframes with the sequence headers repeated in every independently demuxed piece.
/// Timestamps remain on the upstream clock, keeping audio and video aligned across pieces.
struct FLVSegments {
    struct Segment { var data: Data; var duration: Double }
    static let limit = 16 << 20
    private var pending = Data()
    private var header: Data?
    private var videoHeader: Data?
    private var audioHeader: Data?
    private var current = Data()
    private var began: UInt32?

    mutating func append(_ data: Data, emit: (Segment) throws -> Void) throws {
        guard pending.count + data.count <= Self.limit else { throw TVError.unsupported("FLV tag exceeds the live buffer limit") }
        pending.append(data)
        if header == nil {
            guard pending.count >= 9 else { return }
            guard pending.prefix(4) == Data([0x46, 0x4c, 0x56, 1]) else { throw TVError.unsupported("The live link did not return FLV") }
            let offset = number(pending, 5, 4)
            guard (9...1024).contains(offset) else { throw TVError.unsupported("Invalid FLV header") }
            guard pending.count >= offset + 4 else { return }
            header = Data(pending.prefix(offset + 4))
            pending = Data(pending.dropFirst(offset + 4))
        }
        var offset = 0
        while pending.count - offset >= 11 {
            let size = number(pending, offset + 1, 3)
            guard size + 15 <= Self.limit else { throw TVError.unsupported("FLV tag exceeds the live buffer limit") }
            guard pending.count - offset >= size + 15 else { break }
            guard number(pending, offset + 11 + size, 4) == size + 11 else { throw TVError.unsupported("Invalid FLV tag length") }
            let tag = Data(pending[offset..<offset + size + 15])
            let type = tag[0], payload = Data(tag[11..<11 + size])
            let timestamp = UInt32(number(tag, 4, 3)) | UInt32(tag[7]) << 24
            offset += size + 15
            // Only audio/video tags belong to a media segment. File duration and keyframe metadata are stale
            // once a live fragment is cut and would make FFmpeg seek outside it.
            guard type == 8 || type == 9, !payload.isEmpty else { continue }
            let enhanced = type == 9 && payload[0] & 0x80 != 0
            let sequence = type == 9
                ? (enhanced ? payload[0] & 0x0f == 0 : payload.count > 1 && payload[0] & 0x0f == 7 && payload[1] == 0)
                : payload.count > 1 && payload[0] >> 4 == 10 && payload[1] == 0
            if sequence {
                if type == 9 { videoHeader = tag } else { audioHeader = tag }
                continue
            }
            let key = type == 9 && (payload[0] >> 4) & 7 == 1
                && (enhanced ? [1, 3].contains(payload[0] & 0x0f) : payload.count > 1 && payload[1] == 1)
            if key, let began, timestamp >= began, timestamp - began >= 2_000 {
                try emit(Segment(data: current, duration: Double(timestamp - began) / 1_000))
                self.began = nil
                current = Data()
            }
            if began == nil {
                guard key, let header, let videoHeader else { continue }
                current = header + videoHeader + (audioHeader ?? Data())
                began = timestamp
            }
            guard let began, timestamp >= began, timestamp - began <= 20_000,
                  current.count + tag.count <= Self.limit else {
                throw TVError.unsupported("The FLV live stream has no usable keyframe within the buffer limit")
            }
            current.append(tag)
        }
        if offset > 0 { pending = Data(pending.dropFirst(offset)) }
    }

    private func number(_ data: Data, _ offset: Int, _ count: Int) -> Int {
        data[offset..<offset + count].reduce(0) { ($0 << 8) | Int($1) }
    }
}

final class LiveFLVSession: NSObject, RemuxSegmented, URLSessionDataDelegate, @unchecked Sendable {
    static let kept = 8
    static let budget = 64 << 20
    let id = UUID().uuidString.lowercased()
    private let url: URL
    private let headers: [String: String]
    private let configuration: URLSessionConfiguration
    private let startupTimeout: Duration
    private let device = RemuxSession.device()
    private let lock = NSLock()
    private var network: URLSession?
    private var ready: CheckedContinuation<Void, Error>?
    private var deadline: Task<Void, Never>?
    private var closed = false
    private var failed = false
    private var received: Int64 = 0
    private var pieces: [Piece] = []
    private var next = 0
    private var target = 1
    private var masterText = ""
    private var hdr = false
    // Accessed only by URLSession's serial delegate queue.
    private var parser = FLVSegments()
    private struct Piece {
        var index: Int
        var duration: Double
        var output: HLSRemux.Output
        var bytes: Int { output.media.values.reduce(0) { $0 + $1.count } + output.initializations.values.reduce(0) { $0 + $1.count } }
    }

    init(url: URL, headers: [String: String], configuration: URLSessionConfiguration, startupTimeout: Duration = .seconds(30)) {
        self.url = url; self.headers = headers; self.configuration = configuration
        self.startupTimeout = startupTimeout
    }
    var master: String { lock.withLock { masterText } }
    var copiesHDR: Bool { lock.withLock { hdr } }
    var transfer: (received: Int64, host: String?) { lock.withLock { (received, url.host()) } }

    func open() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                queue.qualityOfService = .userInitiated
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                var request = URLRequest(url: url, timeoutInterval: 20)
                headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
                request.setValue(nil, forHTTPHeaderField: "Range")
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                let task = session.dataTask(with: request)
                let cancelled = lock.withLock {
                    guard !closed else { return true }
                    ready = continuation; network = session
                    deadline = Task { [weak self, startupTimeout] in
                        do { try await Task.sleep(for: startupTimeout) } catch { return }
                        self?.expireStartup()
                    }
                    return false
                }
                if cancelled { session.invalidateAndCancel(); continuation.resume(throwing: CancellationError()) }
                else { task.resume() }
            }
        } onCancel: { self.close() }
    }

    func close() {
        let (session, waiting) = lock.withLock {
            closed = true
            deadline?.cancel(); deadline = nil
            defer { network = nil; ready = nil; pieces = []; masterText = "" }
            return (network, ready)
        }
        session?.invalidateAndCancel()
        waiting?.resume(throwing: CancellationError())
    }

    private func fail(_ error: Error) {
        let (session, waiting) = lock.withLock {
            failed = true
            deadline?.cancel(); deadline = nil
            defer { network = nil; ready = nil }
            return (network, ready)
        }
        session?.invalidateAndCancel()
        waiting?.resume(throwing: error)
        if !lock.withLock({ closed }) { Diagnostics.shared.failure("remux", "live FLV host=\(url.host() ?? "-")", error) }
    }

    private func expireStartup() {
        let (session, waiting) = lock.withLock { () -> (URLSession?, CheckedContinuation<Void, Error>?) in
            guard ready != nil, !closed, !failed else { return (nil, nil) }
            failed = true
            defer { network = nil; ready = nil; deadline = nil }
            return (network, ready)
        }
        session?.invalidateAndCancel()
        waiting?.resume(throwing: URLError(.timedOut))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { completionHandler(.cancel); fail(TVError.http(status)); return }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !lock.withLock({ closed || failed }) else { return }
        lock.withLock { received += Int64(data.count) }
        do {
            try parser.append(data) { segment in
                let output = try HLSRemux.repackage(segment.data, device: device, cancelled: { self.lock.withLock { self.closed || self.failed } })
                guard output.format == "flv", !(output.media[0]?.isEmpty ?? true) else { throw TVError.unsupported("FLV has no playable video") }
                let waiting = try lock.withLock { () throws -> CheckedContinuation<Void, Error>? in
                    guard !closed, !failed else { throw CancellationError() }
                    if let first = pieces.first {
                        guard first.output.initializations == output.initializations else {
                            throw TVError.unsupported("The live stream changed its audio or video format; reopen the room")
                        }
                    }
                    let piece = Piece(index: next, duration: segment.duration, output: output)
                    pieces.append(piece); next += 1
                    target = max(target, Int(segment.duration.rounded(.up)))
                    while pieces.count > Self.kept || pieces.reduce(0, { $0 + $1.bytes }) > Self.budget { pieces.removeFirst() }
                    if masterText.isEmpty { describe(output, seconds: segment.duration) }
                    guard pieces.count >= 3 else { return nil }
                    defer { ready = nil; deadline?.cancel(); deadline = nil }
                    return ready
                }
                waiting?.resume()
            }
        } catch { fail(error) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !lock.withLock({ closed || failed }) else { return }
        fail(error ?? TVError.unsupported("The FLV live stream ended"))
    }

    /// Called while holding the lock, once. The decoder configurations are checked on every subsequent piece.
    private func describe(_ output: HLSRemux.Output, seconds: Double) {
        hdr = output.transfer == 16 || output.transfer == 18
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7"]
        if output.audio != nil { lines.append("#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"Audio\",DEFAULT=YES,AUTOSELECT=YES,URI=\"1.m3u8\"") }
        var attributes = ["BANDWIDTH=\(max(128_000, Int(Double(output.bytes) * 8 / seconds * 1.5)))", "RESOLUTION=\(output.width)x\(output.height)"]
        if hdr { attributes.append("VIDEO-RANGE=\(output.transfer == 16 ? "PQ" : "HLG")") }
        if output.audio != nil { attributes.append("AUDIO=\"audio\"") }
        lines += ["#EXT-X-STREAM-INF:" + attributes.joined(separator: ","), "0.m3u8"]
        masterText = lines.joined(separator: "\n") + "\n"
        Diagnostics.shared.record(.info, "remux", "live FLV host=\(url.host() ?? "-") picture=\(output.picture) audio=\(output.audio ?? "-") size=\(output.width)x\(output.height)")
    }

    func playlist(_ track: Int) async -> String? {
        lock.withLock {
            guard !closed, !failed, let first = pieces.first, first.output.media[track] != nil else { return nil }
            var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:\(target)", "#EXT-X-MEDIA-SEQUENCE:\(first.index)", "#EXT-X-MAP:URI=\"\(track)-0.mp4\""]
            for piece in pieces {
                lines += [String(format: "#EXTINF:%.6f,", piece.duration), "\(track)-\(piece.index).m4s"]
            }
            return lines.joined(separator: "\n") + "\n"
        }
    }
    func initialization(track: Int, index: Int) async throws -> Data {
        try lock.withLock {
            guard !closed, let data = pieces.first?.output.initializations[track] else { throw CancellationError() }
            return data
        }
    }
    func segment(track: Int, index: Int) async throws -> Data {
        try lock.withLock {
            guard !closed, let data = pieces.first(where: { $0.index == index })?.output.media[track] else {
                throw TVError.unsupported("The live segment is no longer buffered")
            }
            return data
        }
    }
}
