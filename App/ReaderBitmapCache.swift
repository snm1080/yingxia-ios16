import Foundation
import ImageIO

struct ReaderBitmapKey: Hashable, Sendable {
    let chapter: Int
    let page: Int
    let url: String
    let pixelWidth: Int

    init(chapter: Int, page: Int, url: String, pixelWidth: CGFloat) {
        self.chapter = chapter
        self.page = page
        self.url = url
        // Small safe-area/layout changes must not start another decode of the same page.
        let width = pixelWidth.isFinite ? min(4096, max(1, pixelWidth)) : 1
        self.pixelWidth = Int(ceil(width / 128)) * 128
    }
}

/// One open reader's ready-to-display images. UIKit/SwiftUI can obtain a prefetched bitmap
/// synchronously, without showing an empty frame while encoded data is decoded again.
@MainActor final class ReaderBitmapCache {
    private struct Request {
        let id: UUID
        let task: Task<CGImage, Error>
    }
    private let limit: Int
    private let decoder = ReaderBitmapDecoder()
    private var values: [ReaderBitmapKey: CGImage] = [:]
    private var order: [ReaderBitmapKey] = []
    private var requests: [ReaderBitmapKey: Request] = [:]
    private var bytes = 0
    private var closed = false

    init(limit: Int = 48 << 20) {
        self.limit = limit
    }

    func cached(_ key: ReaderBitmapKey) -> CGImage? {
        guard !closed, let image = values[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return image
    }

    func image(_ key: ReaderBitmapKey, load: @escaping @MainActor @Sendable () async throws -> Data) async throws -> CGImage {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        if let image = cached(key) { return image }
        let request: Request
        if let pending = requests[key] { request = pending }
        else {
            let decoder = decoder
            let task = Task {
                let data = try await load()
                try Task.checkCancellation()
                let image = await decoder.image(data, width: CGFloat(key.pixelWidth))
                try Task.checkCancellation()
                guard let image else { throw DecodeFailure.invalidImage }
                return image
            }
            request = Request(id: UUID(), task: task)
            requests[key] = request
        }
        let image: CGImage
        do { image = try await request.task.value }
        catch {
            if requests[key]?.id == request.id { requests[key] = nil }
            if closed || Task.isCancelled { throw CancellationError() }
            throw error
        }
        guard !closed else { throw CancellationError() }
        if requests[key]?.id == request.id {
            requests[key] = nil
            retain(image, for: key)
        }
        try Task.checkCancellation()
        return image
    }

    private func retain(_ image: CGImage, for key: ReaderBitmapKey) {
        let cost = image.bytesPerRow * image.height
        guard cost <= limit else { return }
        while bytes + cost > limit || order.count >= 12 {
            guard !order.isEmpty else { break }
            let oldest = order.removeFirst()
            if let evicted = values.removeValue(forKey: oldest) { bytes -= evicted.bytesPerRow * evicted.height }
        }
        values[key] = image
        order.append(key)
        bytes += cost
    }

    func close() {
        closed = true
        for request in requests.values { request.task.cancel() }
        requests.removeAll()
        values.removeAll()
        order.removeAll()
        bytes = 0
    }

    private enum DecodeFailure: LocalizedError {
        case invalidImage
        var errorDescription: String? { "这一页无法显示，请重试。" }
    }
}

/// Decodes one page at a time away from the main actor. Long webtoon strips retain their
/// complete height, with a pixel budget so prefetching cannot allocate several giant bitmaps.
private actor ReaderBitmapDecoder {
    func image(_ data: Data, width: CGFloat) -> CGImage? {
        guard !Task.isCancelled,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        guard let pixelWidth = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let pixelHeight = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              pixelWidth > 0, pixelHeight > 0 else { return nil }
        let size = CGSize(width: pixelWidth, height: pixelHeight)
        let maximum = max(pixelWidth, pixelHeight) * ReaderBitmapSizing.decodeWidth(image: size, requested: width) / pixelWidth
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, min(maximum, 16000)),
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }
}

enum ReaderBitmapSizing {
    static func decodeWidth(image: CGSize, requested: CGFloat) -> CGFloat {
        guard image.width > 0, image.height > 0 else { return requested }
        let factor = min(1, requested / image.width, sqrt(6_000_000 / (image.width * image.height)))
        return max(1, image.width * factor)
    }
}
