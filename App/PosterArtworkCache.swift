import Foundation
import ImageIO
import TVCore

final class PosterBitmap: @unchecked Sendable {
    let image: CGImage
    let resource: PosterResource
    let revision: UInt64
    init(_ image: CGImage, resource: PosterResource, revision: UInt64) {
        self.image = image; self.resource = resource; self.revision = revision
    }
}

/// A lazy cell can paint a warm image before its asynchronous task starts. NSCache
/// retains a bounded set of decoded posters and releases them under memory pressure.
private final class PosterMemory: @unchecked Sendable {
    static let shared = PosterMemory()
    private let lock = NSLock()
    private let cache = NSCache<NSString, PosterBitmap>()
    private var revision = MediaCache.shared.revision
    private init() { cache.countLimit = 288; cache.totalCostLimit = 160 * 1024 * 1024 }

    func image(for resource: PosterResource) -> PosterBitmap? {
        return lock.withLock {
            let current = MediaCache.shared.revision
            if revision != current { cache.removeAllObjects(); revision = current }
            return cache.object(forKey: resource.cacheKey as NSString)
        }
    }
    func store(_ bitmap: PosterBitmap) {
        lock.withLock {
            let current = MediaCache.shared.revision
            if revision != current { cache.removeAllObjects(); revision = current }
            guard bitmap.revision == current else { return }
            cache.setObject(bitmap, forKey: bitmap.resource.cacheKey as NSString,
                            cost: bitmap.image.bytesPerRow * bitmap.image.height)
        }
    }
}

actor PosterLoader {
    static let shared = PosterLoader()
    private struct Pending {
        let id: UUID
        var task: Task<Void, Never>?
        var waiters: [UUID: CheckedContinuation<PosterBitmap, Error>]
    }
    private var pending: [PosterResource: Pending] = [:]
    private var queued: [(resource: PosterResource, id: UUID)] = []
    private var running = 0
    private let concurrentLimit = 16
    private var revision = MediaCache.shared.revision

    /// Posters get their own session: URLSession.shared caps per-host connections,
    /// which stacked with the loader semaphore and throttled single-host artwork.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = 16
        return URLSession(configuration: configuration)
    }()

    nonisolated static func cached(_ resource: PosterResource) -> PosterBitmap? {
        PosterMemory.shared.image(for: resource)
    }

    func load(_ resource: PosterResource) async throws -> PosterBitmap {
        try Task.checkCancellation()
        let current = MediaCache.shared.revision
        if revision != current {
            for request in pending.values {
                request.task?.cancel()
                for waiter in request.waiters.values { waiter.resume(throwing: CancellationError()) }
            }
            pending.removeAll(); queued.removeAll(); revision = current
        }
        if let image = Self.cached(resource) { return image }
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            let image: PosterBitmap = try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if var request = pending[resource] {
                    request.waiters[waiter] = continuation
                    pending[resource] = request
                    // A cell that (re)appears wants its queued poster first, not last:
                    // promote a not-yet-started request to the front of the queue.
                    if request.task == nil, let index = queued.firstIndex(where: { $0.id == request.id }) {
                        let entry = queued.remove(at: index)
                        queued.insert(entry, at: 0)
                    }
                } else {
                    let id = UUID()
                    pending[resource] = Pending(id: id, task: nil, waiters: [waiter: continuation])
                    queued.insert((resource, id), at: 0)
                    startQueued()
                }
            }
            try Task.checkCancellation()
            guard image.revision == MediaCache.shared.revision else { throw CancellationError() }
            return image
        } onCancel: {
            Task { await self.cancel(resource, waiter: waiter) }
        }
    }

    private func cancel(_ resource: PosterResource, waiter: UUID) {
        guard var request = pending[resource], let continuation = request.waiters.removeValue(forKey: waiter) else { return }
        continuation.resume(throwing: CancellationError())
        // The departing waiter stops waiting, but the download itself is left
        // alive — queued or running — so it still lands in the disk and memory
        // caches for the next cell that asks. Only the cache-revision sweep in
        // load() tears requests down wholesale.
        pending[resource] = request
    }

    private func startQueued() {
        while running < concurrentLimit, !queued.isEmpty {
            let next = queued.removeFirst()
            guard var request = pending[next.resource], request.id == next.id else { continue }
            let current = revision
            running += 1
            // Neither flash I/O nor ImageIO may occupy the scheduling actor:
            // visible cells can cancel or join requests while a decode is busy.
            request.task = Task.detached(priority: .userInitiated) {
                let result: Result<PosterBitmap, Error>
                do { result = .success(try await Self.read(next.resource, revision: current)) }
                catch { result = .failure(error) }
                await self.finish(next.resource, id: next.id, result: result)
            }
            pending[next.resource] = request
        }
    }

    private func finish(_ resource: PosterResource, id: UUID, result: Result<PosterBitmap, Error>) {
        running -= 1
        defer { startQueued() }
        // Completion of a cancelled request never owns its replacement.
        guard let request = pending[resource], request.id == id else { return }
        pending[resource] = nil
        for waiter in request.waiters.values { waiter.resume(with: result) }
    }

    private nonisolated static func read(_ resource: PosterResource, revision: UInt64) async throws -> PosterBitmap {
        try Task.checkCancellation()
        let disk = MediaCache.shared
        let ticket = disk.ticket()
        let scope = PosterResource.artworkScope(resource.url)
        let cached = disk.data(for: resource.cacheKey, kind: .artwork, scope: scope)
        let data: Data
        if let cached { data = cached }
        else if resource.url.scheme?.lowercased() == "data" {
            guard let embedded = PosterResource.inlineImageData(for: resource.url) else { throw URLError(.cannotDecodeContentData) }
            data = embedded
        }
        else if let saved = try? Data(contentsOf: MusicDownloadLibrary.artworkFile(for: resource.url)) { data = saved }
        else { data = try await TMDBServiceSettings.posterData(for: resource.url, headers: resource.headers, session: PosterLoader.session) }
        try Task.checkCancellation()
        guard revision == disk.revision else { throw CancellationError() }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 720,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else {
            throw NSError(domain: "PosterLoader", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid poster image"])
        }
        try Task.checkCancellation()
        guard revision == disk.revision else { throw CancellationError() }
        if cached == nil {
            disk.store(data, for: resource.cacheKey, kind: .artwork, scope: scope, ttl: 30 * 86400, ticket: ticket)
        }
        try Task.checkCancellation()
        let bitmap = PosterBitmap(image, resource: resource, revision: revision)
        PosterMemory.shared.store(bitmap)
        return bitmap
    }
}
