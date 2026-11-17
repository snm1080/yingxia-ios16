import Foundation
import Perception

@MainActor @Perceptible public final class SearchModel {
    public var draft = ""
    public var selectedSource: String? { didSet { cardsInvalid = true } }
    public var results: [SearchSourceResult] = [] { didSet { invalidateResults() } }
    public var busy = false
    public var completed = 0
    public var total = 0
    public var keyword = ""
    public var stopped = false
    /// Sources this search left out because they are failing (`SourceHealth.paused`); a retry asks them.
    public private(set) var paused: [Site] = []
    /// Keys of the sources this search asks: searchable, not hidden by the viewer, not paused.
    public private(set) var asking: Set<String> = []
    /// Paused because the viewer left the results, not by Stop; `resumeSuspended` continues it.
    public private(set) var suspended = false
    /// A restoration bookmark, not presentation state. iOS 16 writes it as visible
    /// card geometry changes; observing those writes redraws the whole result page.
    /// Source/group/query changes already request scrolling explicitly in the view.
    @PerceptionIgnored public var scrollID: String?
    /// Later result pages, in the order they arrived, so the grid only ever grows at its end.
    public private(set) var batches: [SearchBatch] = [] { didSet { invalidateResults() } }
    public private(set) var loadingMore = false
    /// A failed later page is retryable and never consumes its page number.
    public private(set) var pageErrors: [String: String] = [:]
    public private(set) var groups: [LocalSearchPreferences.Group] = [] { didSet { groupsInvalid = true; cardsInvalid = true } }
    public private(set) var selectedGroup: String? { didSet { cardsInvalid = true } }
    private var runSites: [Site] = []
    /// The next page to ask each source for; `Int.max` once a source has no more.
    private var nextPage: [String: Int] = [:]
    private var lastPagedSource: String?
    private(set) var moreTask: Task<Void, Never>?
    private var pageGeneration = UUID()
    private var resultsVisible = true
    /// Changes only with a new search, unlike `generation`, which pausing also changes.
    private var runID = UUID()
    private static let sourceKey = "searchSource"
    /// When the current run began and how many sources were already done, for a time estimate.
    public private(set) var runStart: (date: Date, completed: Int)?
    private var generation = UUID()
    private(set) var task: Task<Void, Never>?

    private let http: HTTPClient
    private struct Cached {
        let results: [SearchSourceResult]
        let total: Int
        let created: Date
    }
    private var cache: [String: Cached] = [:]
    private var subscriptionID: String?
    /// Each source's position in `SourceStrategy` order, or the viewer's own; matches are listed in this order.
    private var rank: [String: Int] = [:] { didSet { invalidateResults() } }
    @PerceptionIgnored private var resultIndexInvalid = true
    @PerceptionIgnored private var groupsInvalid = true
    @PerceptionIgnored private var cardsInvalid = true
    @PerceptionIgnored private var orderedMatches: [SearchSourceResult] = []
    @PerceptionIgnored private var errorResults: [SearchSourceResult] = []
    @PerceptionIgnored private var sourceVideos: [String: [Video]] = [:]
    @PerceptionIgnored private var sourceCounts: [String: Int] = [:]
    @PerceptionIgnored private var groupMembers: [String: Set<String>] = [:]
    @PerceptionIgnored private var visibleCards: [SearchVideoResult] = []
    @PerceptionIgnored private var pendingResults: [SearchSourceResult] = []
    @PerceptionIgnored private var publicationTask: Task<Void, Never>?
    private var excluded: @MainActor (Site) -> Bool = { _ in false }
    /// The viewer's source order; while it is on, it replaces `SourceStrategy`'s.
    public var order: SourceOrder?
    /// Store supplies its current enabled catalog, so a retained results page cannot restart an
    /// older source list after subscription/Python changes. Nil keeps standalone model callers.
    public var currentCatalog: (@MainActor () -> Subscription?)?
    public init(http: HTTPClient = HTTPClient()) { self.http = http }

    private func catalog(_ proposed: Subscription) -> Subscription? {
        let current: Subscription?
        if let currentCatalog { current = currentCatalog() } else { current = proposed }
        #if os(iOS)
        return current.map(LocalEditionPolicy.importedCatalog)
        #else
        return current
        #endif
    }

    /// Source keys can be reused after a subscription update, and importedAt may remain the
    /// timestamp of another enabled source. Include provenance and execution data in the cache.
    private static func identity(_ config: Subscription) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let members = config.sites.map { site in
            [site.id, site.sourceKey, site.origin(or: config.origin).absoluteString, String(site.type), site.api,
             site.provenance?.spider?.absoluteString ?? "", String(describing: site.detectedRuntime),
             (try? encoder.encode(site.raw)).map { String(decoding: $0, as: UTF8.self) } ?? ""]
        }
        let encoded = (try? encoder.encode(members)).map(PluginChecksum.sha256) ?? ""
        return "\(config.origin)|\(config.importedAt.timeIntervalSince1970)|\(config.spiderURL?.absoluteString ?? "")|\(encoded)"
    }

    private func invalidateResults() { resultIndexInvalid = true; cardsInvalid = true }

    /// Observe the original collections while retaining derived arrays between UI reads.
    /// A 400-source run used to sort and scan every source again for each counter and card.
    private func indexResults() {
        _ = results; _ = batches; _ = rank
        guard resultIndexInvalid else { return }
        resultIndexInvalid = false
        errorResults = results.filter { $0.error != nil }
        orderedMatches = results.filter { $0.page?.videos.isEmpty == false }.enumerated().sorted { lhs, rhs in
            let left = rank[lhs.element.id] ?? .max, right = rank[rhs.element.id] ?? .max
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
        sourceVideos = Dictionary(results.map { ($0.id, $0.page?.videos ?? []) }, uniquingKeysWith: { first, _ in first })
        for batch in batches { sourceVideos[batch.source, default: []].append(contentsOf: batch.videos) }
        sourceCounts = sourceVideos.mapValues { Set($0.map(\.id)).count }
    }
    private func indexGroups() {
        _ = groups
        guard groupsInvalid else { return }
        groupsInvalid = false
        groupMembers = Dictionary(groups.map { ($0.id, Set($0.siteIDs)) }, uniquingKeysWith: { first, _ in first })
    }
    public var failures: [SearchSourceResult] { indexResults(); return errorResults }
    public var matches: [SearchSourceResult] { indexResults(); return orderedMatches }

    /// The All Sources choice is the current group's total, even while one source is selected.
    public var videoCount: Int {
        indexResults(); indexGroups()
        return orderedMatches.filter { includesInSelectedGroup($0.id) }.reduce(0) { $0 + sourceCounts[$1.id, default: 0] }
    }
    public func videoCount(for source: String) -> Int { indexResults(); return sourceCounts[source, default: 0] }
    public func videos(for source: String) -> [Video] { indexResults(); return sourceVideos[source] ?? [] }

    /// First pages in source order, then later pages in arrival order. Repeated view reads
    /// share this array until a result, filter, group, rank or later page actually changes.
    public var items: [SearchVideoResult] {
        indexResults(); indexGroups(); _ = selectedSource; _ = selectedGroup
        guard cardsInvalid else { return visibleCards }
        cardsInvalid = false
        let shown = orderedMatches.filter { includesInSelectedGroup($0.id) && (selectedSource == nil || $0.id == selectedSource) }
        let sites = Dictionary(shown.map { ($0.id, $0.site) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        visibleCards = []
        func append(_ site: Site, _ videos: [Video]) {
            for video in videos {
                let item = SearchVideoResult(site: site, video: video)
                if seen.insert(item.id).inserted { visibleCards.append(item) }
            }
        }
        for result in shown { append(result.site, result.page?.videos ?? []) }
        for batch in batches { if let site = sites[batch.source] { append(site, batch.videos) } }
        return visibleCards
    }

    /// Shows one source's results (nil: every source). The choice carries over to later searches.
    public func select(_ source: String?) {
        selectedSource = source; scrollID = nil
        UserDefaults.standard.set(source, forKey: Self.sourceKey)
    }
    public func selectGroup(_ id: String?) { selectedGroup = id; selectedSource = nil; scrollID = nil }
    public func includesInSelectedGroup(_ source: String) -> Bool {
        guard let selectedGroup else { return true }
        indexGroups()
        return groupMembers[selectedGroup]?.contains(source) == true
    }
    public var visiblePageErrors: [String: String] {
        pageErrors.filter { includesInSelectedGroup($0.key) && (selectedSource == nil || selectedSource == $0.key) }
    }

    private func paginationCandidates(_ source: String?, excludingFailed: Bool) -> [SearchSourceResult] {
        matches.filter {
            includesInSelectedGroup($0.id) && (source == nil || source == $0.id)
                && (!excludingFailed || pageErrors[$0.id] == nil)
        }
    }

    /// Whether a source (nil: any matching source) has another page of results.
    public func canLoadMore(_ source: String?, excludingFailed: Bool = false) -> Bool {
        let candidates = paginationCandidates(source, excludingFailed: excludingFailed)
        return candidates.contains { result in (nextPage[result.id] ?? 2) <= (result.page?.pageCount ?? 1) }
    }

    /// Fetches the next page of a source (nil: of every matching source that has one) and appends
    /// what is new; a source that answers nothing new is done.
    public func loadMore(_ source: String?, config: Subscription, excludingFailed: Bool = false) {
        guard resultsVisible, !loadingMore, !suspended, !keyword.isEmpty else { return }
        guard let config = catalog(config) else { reset(); return }
        if subscriptionID != Self.identity(config) {
            let query = keyword
            reset()
            if !query.isEmpty { search(query, config: config) }
            return
        }
        let targets = paginationCandidates(source, excludingFailed: excludingFailed)
            .filter { (nextPage[$0.id] ?? 2) <= ($0.page?.pageCount ?? 1) }
        guard !targets.isEmpty else { return }
        let scheduled: [SearchSourceResult]
        if source == nil, let last = lastPagedSource, let index = targets.firstIndex(where: { $0.id == last }) {
            scheduled = Array((Array(targets.dropFirst(index + 1)) + targets.prefix(index + 1)).prefix(6))
        } else { scheduled = Array(targets.prefix(6)) }
        loadingMore = true
        let run = runID, pageToken = pageGeneration, keyword = keyword, http = http
        moreTask = Task {
            // Pagination is one queue, not a second burst of six plugin requests.
            for result in scheduled {
                guard !Task.isCancelled, self.pageGeneration == pageToken else { break }
                let page = self.nextPage[result.id] ?? 2
                let response = await GlobalSearch.page(site: result.site, origin: config.origin, jarURL: config.spiderURL,
                                                       query: keyword, page: page, http: http)
                guard !Task.isCancelled, self.runID == run, self.pageGeneration == pageToken else { break }
                if source == nil { self.lastPagedSource = result.id }
                guard let answer = response.page else {
                    self.pageErrors[result.id] = response.error ?? "站点下一页没有返回结果，可重试。"
                    continue
                }
                let known = Set(self.videos(for: result.id).map(\.id))
                var seen = known
                let fresh = answer.videos.filter { seen.insert($0.id).inserted }
                self.pageErrors[result.id] = nil
                self.nextPage[result.id] = fresh.isEmpty ? Int.max : page + 1
                if !fresh.isEmpty { self.batches.append(SearchBatch(source: result.id, page: page, videos: fresh)) }
            }
            if self.runID == run, self.pageGeneration == pageToken {
                self.loadingMore = false; self.moreTask = nil
            }
        }
    }

    private func cancelPages() {
        pageGeneration = UUID()
        moreTask?.cancel(); moreTask = nil; loadingMore = false
    }

    private func clearPages() {
        cancelPages()
        batches = []; nextPage = [:]; lastPagedSource = nil; pageErrors = [:]; loadingMore = false; runID = UUID()
    }

    public func stop() {
        flushResults(token: generation)
        publicationTask?.cancel(); publicationTask = nil
        generation = UUID()
        task?.cancel(); task = nil
        cancelPages()
        stopped = busy; busy = false
        suspended = false
    }

    /// Pauses a running search while the viewer is on another page (a result's detail, another
    /// section), so its plugin calls stop competing with what they are looking at. Sources that
    /// already answered keep their results; the rest run again on `resumeSuspended`.
    public func suspend() {
        resultsVisible = false
        let unfinished = busy || suspended
        let wasStopped = stopped
        stop()
        stopped = wasStopped || unfinished
        suspended = unfinished
    }

    public func resumeSuspended(config: Subscription) {
        guard let config = catalog(config) else { reset(); return }
        if subscriptionID != Self.identity(config) {
            let query = keyword
            reset()
            if !query.isEmpty { search(query, config: config) }
            return
        }
        resultsVisible = true
        guard suspended else { return }
        suspended = false
        resume(config: config)
    }

    public func reset() {
        stop()
        draft = ""; keyword = ""; results = []; completed = 0; total = 0; paused = []; asking = []
        selectedSource = nil; selectedGroup = nil; groups = []; runSites = []; scrollID = nil; stopped = false
        clearPages()
        cache = [:]; subscriptionID = nil
        excluded = { _ in false }
    }

    public static func eligible(_ sites: [Site], jarURL: URL?, excluding hidden: (Site) -> Bool) -> [Site] {
        sites.filter { $0.searchable && $0.canBrowse(jarURL: jarURL) && !hidden($0) }
    }

    public static func visible(_ results: [SearchSourceResult], excluding hidden: (Site) -> Bool) -> [SearchSourceResult] {
        results.filter { !hidden($0.site) }
    }

    public func search(_ query: String, config: Subscription, preferences: LocalSearchPreferences? = nil, excluding hidden: @escaping @MainActor (Site) -> Bool = { _ in false }) {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        guard let config = catalog(config) else { reset(); return }
        let identity = Self.identity(config)
        if subscriptionID != identity { reset(); subscriptionID = identity }
        let preferences = preferences ?? LocalSearchPreferences.load(config: config)
        let effectiveHidden: @MainActor (Site) -> Bool
        if preferences.mode == .default { effectiveHidden = hidden }
        else { effectiveHidden = { _ in false } }
        excluded = effectiveHidden
        stop()
        resultsVisible = true
        keyword = value; draft = value; results = []; completed = 0
        clearPages()
        runSites = preferences.sites(from: config.sites)
        groups = preferences.mode == .groups ? preferences.resolvedGroups(sites: config.sites)
            : [.init(id: preferences.mode.rawValue, name: preferences.mode.title, siteIDs: runSites.map(\.id))]
        selectedGroup = groups.first?.id
        let eligible = Self.eligible(runSites, jarURL: config.spiderURL, excluding: effectiveHidden)
        let now = Date()
        paused = eligible.filter { SourceHealth.shared.paused($0, origin: config.origin, now: now) }
        let held = Set(paused.map(\.id))
        let sites = eligible.filter { !held.contains($0.id) }
        asking = Set(sites.map(\.key))
        let preferred = UserDefaults.standard.string(forKey: Self.sourceKey)
        selectedSource = sites.contains { $0.id == preferred && includesInSelectedGroup($0.id) } ? preferred : nil; scrollID = nil
        rank = Dictionary(arrange(eligible, config: config, failing: failing(config)).enumerated().map { ($1.id, $0) }) { first, _ in first }
        total = sites.count
        let cacheKey = value + "|" + eligible.map(\.id).joined(separator: "|")
        if let hit = cache[cacheKey], Date().timeIntervalSince(hit.created) < 300 {
            results = Self.visible(hit.results, excluding: effectiveHidden)
            total = sites.count
            completed = results.count
            stopped = false
            return
        }
        run(sites, config: config)
    }

    public func resume(config: Subscription, retryFailures: Bool = false) {
        guard let config = catalog(config) else { reset(); return }
        if subscriptionID != Self.identity(config) {
            let query = keyword
            reset()
            if !query.isEmpty { search(query, config: config) }
            return
        }
        guard !busy, !keyword.isEmpty else { return }
        let finished = Set(results.map(\.id))
        let failed = Set(failures.map(\.id))
        // A retry also asks the sources paused for failing: the viewer asked for them.
        let held = Set(paused.map(\.id))
        let sites = Self.eligible(runSites, jarURL: config.spiderURL, excluding: excluded).filter {
            retryFailures ? failed.contains($0.id) || held.contains($0.id) : !finished.contains($0.id) && !held.contains($0.id)
        }
        if retryFailures {
            results.removeAll { failed.contains($0.id) }; completed = results.count
            total += paused.count; paused = []
        }
        asking.formUnion(sites.map(\.key))
        run(sites, config: config)
    }

    private func run(_ sites: [Site], config: Subscription) {
        let token = generation
        let keyword = keyword
        stopped = false; busy = !sites.isEmpty
        guard busy else { return }
        runStart = (Date(), completed)
        task = Task {
            // Already-running sources first, then `SourceStrategy` order (runtime, channel, subscription).
            var warm = Set<String>()
            #if os(macOS)
            warm = await LocalJarHost.shared.reusableSourceKeys()
            #endif
            let failing = self.failing(config)
            let arranged = self.arrange(sites, config: config, failing: failing)
            // Built-in sources answer first: they are quick and the ones most often filtered to.
            // The viewer's own order is asked as it is, top first.
            // Sources that keep failing go last, warm or not, so they never hold up the rest.
            let preferred = self.order?.enabled == true ? arranged
                : (arranged.filter { warm.contains($0.key) } + arranged.filter { !warm.contains($0.key) }).enumerated().sorted { ($0.element.isBuiltIn ? 0 : 1, $0.offset) < ($1.element.isBuiltIn ? 0 : 1, $1.offset) }.map(\.element)
            let ordered = preferred.filter { !failing($0) } + preferred.filter(failing)
            guard self.generation == token else { return }
            await GlobalSearch.search(sites: ordered, origin: config.origin, jarURL: config.spiderURL, query: keyword, http: self.http) { result in
                await self.receive(result, token: token)
            }
            guard self.generation == token else { return }
            self.flushResults(token: token)
            self.busy = false; self.task = nil
            if self.completed == self.total {
                let cacheKey = keyword + "|" + Self.eligible(self.runSites, jarURL: config.spiderURL, excluding: self.excluded).map(\.id).joined(separator: "|")
                self.cache[cacheKey] = Cached(results: self.results, total: self.total, created: Date())
                if self.cache.count > 6, let oldest = self.cache.min(by: { $0.value.created < $1.value.created })?.key { self.cache[oldest] = nil }
            }
        }
    }

    /// `SourceStrategy` order, or the viewer's own while it is on (sources it doesn't list yet follow).
    private func arrange(_ sites: [Site], config: Subscription, failing: (Site) -> Bool) -> [Site] {
        let automatic = SourceStrategy.arrange(sites, where: { _ in true }, failing: failing)
        guard let order, order.enabled else { return automatic }
        return order.arrange(automatic, origin: config.origin)
    }

    /// Sources in a `SourceHealth` cooldown. Search leaves them out; when a retry asks them, they go
    /// after the others (and are listed after them unless the viewer's own order is on).
    private func failing(_ config: Subscription) -> @Sendable (Site) -> Bool {
        let now = Date()
        let down = Set(config.sites.filter { SourceHealth.shared.paused($0, origin: config.origin, now: now) }.map(\.id))
        return { down.contains($0.id) }
    }

    private func receive(_ result: SearchSourceResult, token: UUID) {
        guard generation == token else { return }
        pendingResults.append(result)
        if results.isEmpty { flushResults(token: token); return }
        guard publicationTask == nil else { return }
        publicationTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            guard let self, !Task.isCancelled, self.generation == token else { return }
            self.publicationTask = nil
            self.flushResults(token: token)
        }
    }
    private func flushResults(token: UUID) {
        guard generation == token, !pendingResults.isEmpty else { return }
        publicationTask?.cancel(); publicationTask = nil
        let pending = pendingResults; pendingResults.removeAll(keepingCapacity: true)
        results.append(contentsOf: pending)
        completed += pending.count
    }
}
