import Foundation

extension Site {
    public var searchable: Bool {
        let enabled: Bool
        switch raw["searchable"] {
        case .bool(let value): enabled = value
        case .number, .string: enabled = raw["searchable"]?.int == 1 || raw["searchable"] == .string("true")
        default: enabled = true
        }
        return enabled && !Self.disabledSearch(raw["supportSearch"])
            && raw["indexs"] != .bool(true) && raw["indexs"]?.int != 1
    }
    private static func disabledSearch(_ value: JSONValue?) -> Bool {
        value == .bool(false) || value == .number(0) || value == .string("0") || value == .string("false")
    }
    /// TVBox's `hide: 1` keeps a search-only source out of the source lists.
    public var hidden: Bool { raw["hide"]?.int == 1 }
    public func canBrowse(jarURL: URL?) -> Bool {
        if isCloudFiles { return true }
        let jarURL = spider(or: jarURL)
        if native { return true }
        if runsLitePort { return true }
        #if os(macOS)
        let hasPlugin = jarURL != nil || raw["jar"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        switch runtime {
        case .javascript, .python: return LocalJarHost.available(runtime)
        case .jar: return hasPlugin && EmbeddedJarHost.available
        case .api, .unsupported: return false
        }
        #elseif os(iOS) || os(tvOS)
        if runtime == .javascript { return ScriptRuntime.available }
        if runtime == .python { return EmbeddedPythonHost.available }
        return runtime == .jar && EmbeddedJarHost.available && (jarURL != nil || raw["jar"]?.string?.isEmpty == false)
        #else
        return false
        #endif
    }
}

/// One later page of a source's search results.
public struct SearchBatch: Identifiable, Sendable {
    public let source: String
    public let page: Int
    public let videos: [Video]
    public var id: String { "\(source)#\(page)" }
}

public struct SearchSourceResult: Identifiable, Sendable {
    public let site: Site
    public let page: CatalogPage?
    public let error: String?
    public var id: String { site.id }
}

/// A materialized video card. IDs are scoped to a source, so equal IDs from different
/// sources remain separate results.
public struct SearchVideoResult: Identifiable, Sendable {
    public let site: Site
    public let video: Video
    public let id: String
    public init(site: Site, video: Video) {
        self.site = site; self.video = video
        id = "\(site.id.utf8.count):\(site.id)\(video.id)"
    }
}

public enum GlobalSearch {
    /// Native HTTP, embedded Python, QuickJS and Node have independent limits inside one
    /// global memory/network budget. Pending sources are data, not hundreds of running tasks.
    public static func search(sites: [Site], origin: URL, jarURL: URL?, query: String,
                              http: HTTPClient = HTTPClient(), concurrency: Int = 8,
                              onResult: @escaping @Sendable (SearchSourceResult) async -> Void) async {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty, !Task.isCancelled else { return }
        let eligible = sites.filter { $0.searchable && $0.canBrowse(jarURL: jarURL) }
        let began = ContinuousClock.now
        let runtimeCounts = Dictionary(grouping: eligible, by: lane).mapValues(\.count)
        Diagnostics.shared.record(.info, "search", "begin sources=\(eligible.count) skipped=\(sites.count - eligible.count) runtimes=\(runtimeCounts)")
        defer { Diagnostics.shared.record(.info, "search", "end elapsed=\(began.duration(to: .now)) cancelled=\(Task.isCancelled)") }
        let width = min(8, max(1, concurrency))
        let limits: [SearchScheduler.Lane: Int] = [.native: min(6, width), .python: min(4, width),
            .quickJS: min(4, width), .node: width, .jar: min(5, width)]
        await SearchScheduler.search(sites: eligible, maximumConcurrent: min(12, width * 2), limits: limits,
                                     lane: lane, operation: { site in
            await fetchPage(site: site, origin: origin, jarURL: jarURL, keyword: keyword, page: 1, http: http)
        }, onResult: onResult)
    }

    /// Pagination shares the same admission budget as first-page and replacement searches.
    static func page(site: Site, origin: URL, jarURL: URL?, query: String, page: Int, http: HTTPClient) async -> SearchSourceResult {
        await SearchScheduler.request(site: site, lane: lane(site)) {
            await fetchPage(site: site, origin: origin, jarURL: jarURL, keyword: query, page: page, http: http)
        }
    }

    private static func lane(_ site: Site) -> SearchScheduler.Lane {
        if site.native { return .native }
        switch site.preferredRuntime {
        case .python: return .python
        case .javascript: return site.raw["catPawOpen"] != nil ? .node : .quickJS
        case .jar: return .jar
        case .api, .unsupported: return .native
        }
    }

    private enum Answer: Sendable {
        case page(CatalogPage), failure(String), expired, cancelled
    }
    private static func fetchPage(site: Site, origin: URL, jarURL: URL?, keyword: String, page: Int, http: HTTPClient) async -> SearchSourceResult {
        let began = ContinuousClock.now
        // A first plugin answer includes its local module preparation. HTTP sources need less.
        let seconds = lane(site) == .native ? 15 : 25
        let answer = await withTaskGroup(of: Answer.self) { group in
            group.addTask {
                do {
                    try Task.checkCancellation()
                    let page = try await CatalogClient(site: site, origin: origin, http: http, jarURL: jarURL)
                        .list(category: nil, query: keyword, page: page)
                    try Task.checkCancellation()
                    return .page(page)
                } catch {
                    if Task.isCancelled { return .cancelled }
                    return .failure(error.localizedDescription)
                }
            }
            group.addTask {
                do { try await Task.sleep(for: .seconds(seconds)); return .expired }
                catch { return .cancelled }
            }
            let first = await group.next() ?? .cancelled
            group.cancelAll()
            // Leaving the group waits for the source's cancellation fence. It does not detach
            // a timed-out runtime and then start more work behind its occupied worker slot.
            return first
        }
        let elapsed = began.duration(to: .now)
        switch answer {
        case .page(let page):
            Diagnostics.shared.record(.debug, "search", "source=\(site.key) ok videos=\(page.videos.count) elapsed=\(elapsed)")
            return SearchSourceResult(site: site, page: page, error: nil)
        case .expired:
            Diagnostics.shared.record(.warning, "search", "source=\(site.key) deadline=\(seconds)s elapsed=\(elapsed)")
            return SearchSourceResult(site: site, page: nil, error: "站点搜索超过 \(seconds) 秒，可单独重试。")
        case .failure(let message):
            Diagnostics.shared.record(.warning, "search", "source=\(site.key) failed elapsed=\(elapsed) error=\(message)")
            return SearchSourceResult(site: site, page: nil, error: message)
        case .cancelled:
            return SearchSourceResult(site: site, page: nil, error: CancellationError().localizedDescription)
        }
    }
}
