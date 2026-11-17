import Foundation

/// Only the playing work requests title artwork. Catalog cards keep using their source covers.
/// Source-specific choices take precedence; automatic answers share one cancellable title request.
public actor PlaybackTitleArtwork {
    public static let shared = PlaybackTitleArtwork()

    public struct Request: Hashable, Sendable {
        public let matchKey: String
        public let identity: String
        fileprivate let titleKey: String
        fileprivate let match: TMDBMatch.Request
        fileprivate let allowed: Bool

        public init(video: Video, origin: URL, sourceKey: String, siteKey: String, siteName: String, siteAPI: String) {
            matchKey = TMDBMatchStore.key(source: PosterPresentation.matchSourceIdentity(origin: origin, sourceKey: sourceKey), video: video.id)
            match = TMDBMatch.Request(video: video, source: TMDBMatch.SourceRef(key: siteKey, name: siteName))
            allowed = TMDBMatch.enabled && !video.isFolder && !TMDBMatch.skipsSource(key: siteKey, api: siteAPI) &&
                !TMDBMatch.labeledNotOnTMDB(match)
            // Keep remakes, media types and seasons distinct while sharing equivalent release names.
            let seasons = Set(([match.title, match.remarks] + match.episodes).compactMap(TMDBTitleMatching.season)).sorted()
            let parts = [TMDBServiceSettings.identity, match.language, TMDBTitleMatching.key(match.title),
                         match.year ?? "", TMDBTitleMatching.mediaType(match)?.rawValue ?? "", seasons.map(String.init).joined(separator: ",")]
            titleKey = parts.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
            identity = matchKey + "|" + titleKey
        }
    }

    private struct Resolution: Sendable {
        let logo: URL?
        let answer: TMDBMatch.Answer?
        static let empty = Resolution(logo: nil, answer: nil)
    }
    private struct Cached {
        let value: Resolution
        let saved: Date
        let expires: Date
    }
    private struct Flight {
        let token: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<Resolution, Error>]
    }
    private let store: TMDBMatchStore
    private let session: URLSession
    private var cache: [String: Cached] = [:]
    private var flights: [String: Flight] = [:]

    public init(store: TMDBMatchStore = .shared, session: URLSession = .shared) {
        self.store = store; self.session = session
    }

    public nonisolated static func displayTitle(_ title: String, fallback: String) -> String {
        let title = HTMLText.name(title)
        let address = title.lowercased().hasPrefix("http://") || title.lowercased().hasPrefix("https://")
        return String((title.isEmpty || address ? HTMLText.name(fallback) : title).prefix(240))
    }

    public func logo(for request: Request) async throws -> URL? {
        try Task.checkCancellation()
        guard request.allowed else { return nil }
        let choice = await store.choice(for: request.matchKey)
        try Task.checkCancellation()
        let existing = await store.answer(for: request.matchKey)
        try Task.checkCancellation()
        switch choice {
        case .none?: return try await currentLogo(nil, for: request, choice: choice)
        case .work(let type, let id, let season)?:
            if let details = existing?.details, details.mediaType == type, details.id == id,
               type != .tv || details.season?.number == season {
                return try await currentLogo(details.logo, for: request, choice: choice)
            }
            let key = "work|\(TMDBServiceSettings.identity)|\(request.match.language)|\(type.rawValue)|\(id)|\(season ?? -1)"
            let session = session, language = request.match.language
            let resolved = try await resolve(key: key) {
                let details = try await TMDBMatch.details(type, id: id, season: season, language: language, session: session)
                return Resolution(logo: PosterPresentation.imageURL(details.logo), answer: nil)
            }
            return try await currentLogo(resolved.logo, for: request, choice: choice)
        case nil: break
        }
        // Reading the exact key used by the detail page also respects a known missing logo.
        if let existing { return try await currentLogo(existing.details?.logo, for: request, choice: choice) }
        let session = session, match = request.match
        let resolved = try await resolve(key: request.titleKey) {
            let answer = try await TMDBMatch.lookup(match, session: session, progress: { _ in })
            return Resolution(logo: PosterPresentation.imageURL(answer.details?.logo), answer: answer)
        }
        try Task.checkCancellation()
        // A manual choice made during this request remains the source of truth.
        guard await store.choice(for: request.matchKey) == nil else { return try await logo(for: request) }
        try Task.checkCancellation()
        if let answer = resolved.answer { await store.save(answer, for: request.matchKey) }
        try Task.checkCancellation()
        return try await currentLogo(resolved.logo, for: request, choice: choice)
    }

    private func currentLogo(_ logo: URL?, for request: Request, choice: TMDBMatchStore.Choice?) async throws -> URL? {
        try Task.checkCancellation()
        let latest = await store.choice(for: request.matchKey)
        try Task.checkCancellation()
        guard latest == choice else { return try await self.logo(for: request) }
        return PosterPresentation.imageURL(logo)
    }

    private func resolve(key: String, load: @escaping @Sendable () async throws -> Resolution) async throws -> Resolution {
        if let cached = cache[key], cached.expires > Date() { return cached.value }
        cache[key] = nil
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if var flight = flights[key] {
                    flight.waiters[waiter] = continuation
                    flights[key] = flight
                    return
                }
                let token = UUID()
                let task = Task { [weak self] in
                    let result: Result<Resolution, Error>
                    do { result = .success(try await load()) }
                    catch { result = .failure(error) }
                    await self?.complete(key: key, token: token, result: result)
                }
                flights[key] = Flight(token: token, task: task, waiters: [waiter: continuation])
            }
        } onCancel: {
            Task { await self.cancel(key: key, waiter: waiter) }
        }
    }

    private func cancel(key: String, waiter: UUID) {
        guard var flight = flights[key], let continuation = flight.waiters.removeValue(forKey: waiter) else { return }
        if flight.waiters.isEmpty {
            flights[key] = nil
            flight.task.cancel()
        } else { flights[key] = flight }
        continuation.resume(throwing: CancellationError())
    }

    private func complete(key: String, token: UUID, result: Result<Resolution, Error>) {
        guard let flight = flights[key], flight.token == token else { return }
        flights[key] = nil
        let value: Resolution
        let keep: TimeInterval
        switch result {
        case .success(let resolved):
            value = resolved
            keep = resolved.answer?.status == .matched || resolved.logo != nil ? 7 * 86400 : 86400
        case .failure(let error):
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                for waiter in flight.waiters.values { waiter.resume(throwing: CancellationError()) }
                return
            }
            value = .empty
            keep = 300
        }
        let now = Date()
        cache[key] = Cached(value: value, saved: now, expires: now.addingTimeInterval(keep))
        if cache.count > 120 {
            for entry in cache.sorted(by: { $0.value.saved < $1.value.saved }).prefix(cache.count - 120) { cache[entry.key] = nil }
        }
        for waiter in flight.waiters.values { waiter.resume(returning: value) }
    }
}
