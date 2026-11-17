import Foundation

/// A bounded optional transport probe. Reject ignored ranges in the response
/// callback: AsyncBytes may defer returning headers until the body fills a buffer.
final class MediaPrefixProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private typealias Prefix = (bytes: Data, length: Int)
    private enum Purpose { case finiteFile, hls }
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Prefix?, Never>?
    private var connection: URLSession?
    private var finished = false
    private var bytes = Data()
    private var length = 0
    private var required = 16
    private var purpose = Purpose.finiteFile

    static func read(_ url: URL, headers: [String: String], session: URLSession? = nil) async -> (bytes: Data, length: Int)? {
        await request(url, headers: headers, session: session, purpose: .finiteFile)
    }

    /// Some playlist dispatchers ignore Range or omit their media type. Only a
    /// complete EXTM3U first line identifies HLS; a declared MIME alone does not.
    static func isHls(_ url: URL, headers: [String: String]) async -> Bool {
        guard let result = await request(url, headers: headers, session: nil, purpose: .hls) else { return false }
        return hlsHeader(result.bytes) == true
    }

    private static func request(_ url: URL, headers: [String: String], session: URLSession?, purpose: Purpose) async -> Prefix? {
        let probe = MediaPrefixProbe()
        probe.purpose = purpose
        let configuration = session?.configuration ?? URLSessionConfiguration.ephemeral
        let timeout: TimeInterval = purpose == .hls ? 2 : 6
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = purpose == .hls ? 3 : 8
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        var request = URLRequest(url: url, timeoutInterval: timeout)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.setValue("bytes=0-15", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let connection = URLSession(configuration: configuration, delegate: probe, delegateQueue: nil)
                let task = connection.dataTask(with: request)
                let cancelled = probe.lock.withLock {
                    if probe.finished { return true }
                    probe.continuation = continuation; probe.connection = connection
                    return false
                }
                if cancelled { connection.invalidateAndCancel(); continuation.resume(returning: nil) }
                else { task.resume() }
            }
        } onCancel: { probe.finish(nil) }
    }

    private func finish(_ result: Prefix?) {
        let state = lock.withLock { () -> (CheckedContinuation<Prefix?, Never>?, URLSession?) in
            guard !finished else { return (nil, nil) }
            finished = true
            let state = (continuation, connection)
            continuation = nil; connection = nil
            return state
        }
        state.1?.invalidateAndCancel()
        state.0?.resume(returning: result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel); finish(nil); return
        }
        if purpose == .hls {
            if http.statusCode == 206 {
                guard let range = http.value(forHTTPHeaderField: "Content-Range")?.firstMatch(of: /^bytes 0-(\d+)\/(\d+|\*)$/),
                      let last = Int(range.1), last < Int.max,
                      range.2 == "*" || Int(range.2).map({ $0 > last }) == true else {
                    completionHandler(.cancel); finish(nil); return
                }
            } else if http.statusCode != 200 {
                completionHandler(.cancel); finish(nil); return
            }
            lock.withLock { required = 64 }
            completionHandler(.allow); return
        }
        guard http.statusCode == 206,
              let range = http.value(forHTTPHeaderField: "Content-Range")?.firstMatch(of: /^bytes 0-(\d+)\/(\d+)$/),
              let last = Int(range.1), let length = Int(range.2), last >= 0, length > last else {
            completionHandler(.cancel); finish(nil); return
        }
        lock.withLock { self.length = length; required = min(16, last + 1) }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let result = lock.withLock { () -> (finish: Bool, prefix: Prefix?) in
            guard !finished else { return (false, nil) }
            bytes.append(data.prefix(max(0, required - bytes.count)))
            if purpose == .hls {
                if let hls = Self.hlsHeader(bytes) { return (true, hls ? (bytes, length) : nil) }
                return (bytes.count == required, nil)
            }
            return bytes.count == required ? (true, (bytes, length)) : (false, nil)
        }
        if result.finish { finish(result.prefix) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { finish(nil) }

    /// Nil means a split header may still become valid within the byte limit.
    private static func hlsHeader(_ data: Data) -> Bool? {
        let bytes = [UInt8](data)
        var index = 0
        let bom: [UInt8] = [0xef, 0xbb, 0xbf]
        if bytes.first == bom[0] {
            for offset in 0..<min(bytes.count, bom.count) where bytes[offset] != bom[offset] { return false }
            guard bytes.count >= bom.count else { return nil }
            index = bom.count
        }
        while index < bytes.count, [UInt8(9), 10, 13, 32].contains(bytes[index]) { index += 1 }
        let magic = Array("#EXTM3U".utf8)
        for offset in 0..<magic.count {
            guard index + offset < bytes.count else { return nil }
            guard bytes[index + offset] == magic[offset] else { return false }
        }
        guard index + magic.count < bytes.count else { return nil }
        return bytes[index + magic.count] == 10 || bytes[index + magic.count] == 13
    }
}
