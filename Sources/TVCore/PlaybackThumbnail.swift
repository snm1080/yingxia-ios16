import Foundation
import CoreGraphics
import TVMedia

/// An independent, bounded decoder for the scrubber. Pass the final playback URL so local Range/cache
/// endpoints remain in use. This reader never borrows the playing decoder or changes its seek position.
public final class PlaybackThumbnailReader: @unchecked Sendable {
    private static let worker = DispatchQueue(label: "yingxia.scrub-preview", qos: .utility)
    private let url: URL
    private let headers: String
    private let lock = NSLock()
    private var active: Request?
    private var pending: Request?
    private var working = false
    private var closed = false
    private var cache: [Int64: CGImage] = [:]
    private var recent: [Int64] = []

    public init(url: URL, headers: [String: String] = [:]) {
        if ["127.0.0.1", "localhost", "::1", "[::1]"].contains(url.host?.lowercased() ?? ""),
           (url.path.hasPrefix("/media-cache/") || url.path.hasPrefix("/playback/") || url.path.hasPrefix("/hls/") || url.path.hasPrefix("/dash-cache/")),
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            var query = components.queryItems ?? []
            query.removeAll { $0.name == "cacheOnly" }
            query.append(URLQueryItem(name: "cacheOnly", value: "1"))
            components.queryItems = query
            self.url = components.url ?? url
        } else {
            self.url = url
        }
        self.headers = headers.sorted { $0.key.lowercased() < $1.key.lowercased() }.compactMap { name, value in
            guard !name.isEmpty, !name.contains(":"), !name.contains(where: { $0.isWhitespace || $0.isNewline }),
                  !value.contains("\r"), !value.contains("\n") else { return nil }
            return "\(name): \(value)\r\n"
        }.joined()
    }

    deinit { cancel() }

    /// Quarter-second cache entries keep repeated scrub events cheap. A newer request cancels both the
    /// active read and the one pending request, so rapid dragging cannot accumulate network/decode tasks.
    public func image(at seconds: Double) async -> CGImage? {
        guard seconds.isFinite, seconds >= 0, seconds <= 1e9 else { return nil }
        let request = Request(key: Int64((seconds * 4).rounded()))
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                request.install(continuation)
                submit(request)
            }
        } onCancel: { request.cancel() }
    }

    /// Permanently closes this media's reader and promptly resumes any waiting callers with nil.
    public func cancel() {
        lock.withLock {
            closed = true
            active?.cancel(); pending?.cancel(); pending = nil
            cache.removeAll(); recent.removeAll()
        }
    }

    private func submit(_ request: Request) {
        lock.withLock {
            guard !closed, !request.isCancelled else { request.cancel(); return }
            active?.cancel(); pending?.cancel(); pending = nil
            if let image = cache[request.key] {
                recent.removeAll { $0 == request.key }; recent.append(request.key)
                request.finish(image)
                return
            }
            pending = request
            guard !working else { return }
            working = true
            Self.worker.async { [self] in drain() }
        }
    }

    private func drain() {
        while let request = lock.withLock({ () -> Request? in
            guard let next = pending else { working = false; active = nil; return nil }
            pending = nil; active = next
            return next
        }) {
            let image = request.isCancelled ? nil : decode(request)
            lock.withLock {
                if !closed, !request.isCancelled, let image {
                    cache[request.key] = image
                    recent.removeAll { $0 == request.key }; recent.append(request.key)
                    while recent.count > 24 { cache.removeValue(forKey: recent.removeFirst()) }
                }
                request.finish(request.isCancelled || closed ? nil : image)
                if active === request { active = nil }
            }
        }
    }

    private func decode(_ request: Request) -> CGImage? {
        var thumbnail = TVMThumbnail()
        defer { tvm_thumbnail_free(&thumbnail) }
        let address = url.isFileURL ? url.path : url.absoluteString
        let status = address.withCString { address in
            headers.withCString { headers in
                tvm_thumbnail(address, headers, Double(request.key) / 4, 640, 640,
                    Unmanaged.passUnretained(request).toOpaque(), thumbnailInterrupted, &thumbnail)
            }
        }
        guard status == 0, !request.isCancelled, let pixels = thumbnail.pixels,
              thumbnail.width > 0, thumbnail.height > 0, thumbnail.stride >= thumbnail.width * 4 else { return nil }
        let data = Data(bytes: pixels, count: Int(thumbnail.stride) * Int(thumbnail.height))
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: Int(thumbnail.width), height: Int(thumbnail.height), bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: Int(thumbnail.stride), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    fileprivate final class Request: @unchecked Sendable {
        let key: Int64
        private let lock = NSLock()
        private var cancelled = false
        private var finished = false
        private var continuation: CheckedContinuation<CGImage?, Never>?
        init(key: Int64) { self.key = key }
        var isCancelled: Bool { lock.withLock { cancelled } }

        func install(_ continuation: CheckedContinuation<CGImage?, Never>) {
            let immediate = lock.withLock {
                if finished { return true }
                self.continuation = continuation
                return false
            }
            if immediate { continuation.resume(returning: nil) }
        }

        func finish(_ image: CGImage?) {
            let continuation = lock.withLock { () -> CheckedContinuation<CGImage?, Never>? in
                guard !finished else { return nil }
                finished = true
                defer { self.continuation = nil }
                return self.continuation
            }
            continuation?.resume(returning: image)
        }

        func cancel() {
            let continuation = lock.withLock { () -> CheckedContinuation<CGImage?, Never>? in
                cancelled = true
                guard !finished else { return nil }
                finished = true
                defer { self.continuation = nil }
                return self.continuation
            }
            continuation?.resume(returning: nil)
        }
    }
}

private func thumbnailInterrupted(_ context: UnsafeMutableRawPointer?) -> Int32 {
    guard let context else { return 1 }
    return Unmanaged<PlaybackThumbnailReader.Request>.fromOpaque(context).takeUnretainedValue().isCancelled ? 1 : 0
}
