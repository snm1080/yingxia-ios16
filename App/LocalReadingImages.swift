import Foundation
import ImageIO
import TVCore

/// One reader's image requests. Its bounded memory cache includes per-page headers in the
/// identity; closing the reader cancels outstanding requests and leaves no image files behind.
actor LocalReadingImages {
    private struct Request {
        let id: UUID
        let task: Task<Data, Error>
    }
    private let session: URLSession
    private var pending: [ReadingMedia.Image: Request] = [:]
    private var cache: [ReadingMedia.Image: Data] = [:]
    private var order: [ReadingMedia.Image] = []
    private var bytes = 0
    private var closed = false
    private let limit = 32 << 20

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration)
    }

    func data(_ image: ReadingMedia.Image) async throws -> Data {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        if let data = cache[image] {
            order.removeAll { $0 == image }; order.append(image)
            return data
        }
        if let request = pending[image] { return try await result(request, image: image) }
        guard let url = URL(string: image.url), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw URLError(.unsupportedURL)
        }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        for (field, value) in image.headers { request.setValue(value, forHTTPHeaderField: field) }
        let session = session
        let task = Task {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard (200..<300).contains(http.statusCode) else { throw ImageError.http(http.statusCode) }
            guard !data.isEmpty else { throw ImageError.empty }
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetCount(source) > 0,
                  CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 16,
                    kCGImageSourceShouldCacheImmediately: true,
                  ] as CFDictionary) != nil else { throw ImageError.invalidImage }
            return data
        }
        let pendingRequest = Request(id: UUID(), task: task)
        pending[image] = pendingRequest
        return try await result(pendingRequest, image: image)
    }

    private func result(_ request: Request, image: ReadingMedia.Image) async throws -> Data {
        let data: Data
        do { data = try await request.task.value }
        catch {
            if pending[image]?.id == request.id { pending[image] = nil }
            if closed || Task.isCancelled { throw CancellationError() }
            throw error
        }
        guard !closed else { throw CancellationError() }
        // Cache a shared success even when the first page's waiter was cancelled. Otherwise
        // revisiting a page immediately sends a second request and shows another placeholder.
        if pending[image]?.id == request.id {
            pending[image] = nil
            retain(data, for: image)
        }
        try Task.checkCancellation()
        return data
    }

    private func retain(_ data: Data, for image: ReadingMedia.Image) {
        if data.count <= limit {
            while bytes + data.count > limit || order.count >= 24 {
                guard !order.isEmpty else { break }
                let oldest = order.removeFirst()
                bytes -= cache.removeValue(forKey: oldest)?.count ?? 0
            }
            cache[image] = data; order.append(image); bytes += data.count
        }
    }

    func close() {
        closed = true
        for request in pending.values { request.task.cancel() }
        pending.removeAll(); cache.removeAll(); order.removeAll(); bytes = 0
        session.invalidateAndCancel()
    }

    private enum ImageError: LocalizedError {
        case http(Int), empty, invalidImage
        var errorDescription: String? {
            switch self {
            case .http(let code): "图片请求失败（HTTP \(code)），请重试。"
            case .empty: "图片内容为空，请重试。"
            case .invalidImage: "源返回的内容不是有效图片，请重试。"
            }
        }
    }
}
