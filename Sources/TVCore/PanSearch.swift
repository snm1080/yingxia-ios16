import Foundation
import Perception

public struct MediaMetadataHint: Codable, Equatable, Sendable {
    public let id: Int
    public let mediaType: TMDBMatch.MediaType
    public let season: Int?
    /// The cover already displayed for this exact TMDB work. Optional for older saved requests.
    public let poster: URL?
    public let posterHeaders: [String: String]?
    public init(id: Int, mediaType: TMDBMatch.MediaType, season: Int? = nil,
                poster: URL? = nil, posterHeaders: [String: String]? = nil) {
        self.id = id; self.mediaType = mediaType; self.season = season
        self.poster = poster; self.posterHeaders = posterHeaders
    }
}

/// Persisted UI fields. MacCat's Node service validates and interprets every option.
public struct PanSearchSettings: Codable, Equatable, Sendable {
    public var panApiBase = "https://so.252035.xyz"
    public var panToken = ""
    public var panCloudTypes = ""
    public var panChannels = ""
    public var panPlugins = ""
    public var panInclude = ""
    public var panExclude = ""
    public var panSource = "all"
    public var panResult = "merge"
    public var panConcurrency = ""
    public var panRefresh = false
    public var panExt = ""
    public var panCheckLinks = true
    private static let key = "local.pan.settings.v1"
    public static let changed = Notification.Name("PanSearchSettings.changed")
    public init() {}
    public static func load(defaults: UserDefaults = .standard) -> Self {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
    }
    public func save(defaults: UserDefaults = .standard) throws {
        defaults.set(try JSONEncoder().encode(self), forKey: Self.key)
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }
    public var serviceConfiguration: [String: JSONValue] {
        ["panApiBase": .string(panApiBase), "panToken": .string(panToken), "panCloudTypes": .string(panCloudTypes),
         "panChannels": .string(panChannels), "panPlugins": .string(panPlugins), "panInclude": .string(panInclude),
         "panExclude": .string(panExclude), "panSource": .string(panSource), "panResult": .string(panResult),
         "panConcurrency": .string(panConcurrency), "panRefresh": .bool(panRefresh), "panExt": .string(panExt), "panCheckLinks": .bool(panCheckLinks)]
    }
    public func configure() async throws { try await MobileMediaServices.configure(["tmdb": .object(serviceConfiguration)]) }
}

public struct PanSearchItem: Identifiable, Equatable, Sendable, Codable {
    public let id: String
    public let title: String
    public let url: String
    public let input: String
    public let diskType: String
    public let password: String
    public let source: String
    public let datetime: String
    public init(id: String, title: String, url: String, input: String, diskType: String, password: String = "", source: String = "", datetime: String = "") {
        self.id = id; self.title = title; self.url = url; self.input = input; self.diskType = diskType
        self.password = password; self.source = source; self.datetime = datetime
    }
    public var checkInput: JSONValue { .object(["id": .string(id), "diskType": .string(diskType), "url": .string(url), "password": .string(password)]) }
}

public struct PanSearchResult: Equatable, Sendable {
    public let query: String
    public let items: [PanSearchItem]
    public let counts: [String: Int]
    public let partial: Bool
    public let diskTypes: [String]
    public let diskCounts: [String: Int]
    private let dateOrderedItems: [PanSearchItem]
    public init(query: String, items: [PanSearchItem], counts: [String: Int] = [:], partial: Bool = false) {
        self.query = query; self.items = items; self.counts = counts; self.partial = partial
        let iso = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter(); fractional.formatOptions.insert(.withFractionalSeconds)
        let calendar = DateFormatter(); calendar.locale = Locale(identifier: "en_US_POSIX"); calendar.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let itemDates = Dictionary(items.map { item in
            let date = iso.date(from: item.datetime) ?? fractional.date(from: item.datetime) ?? calendar.date(from: item.datetime)
            return (item.id, date?.timeIntervalSince1970 ?? -.infinity)
        }, uniquingKeysWith: { first, _ in first })
        var types = [String](), countsByDisk = [String: Int]()
        for item in items {
            if countsByDisk[item.diskType] == nil { types.append(item.diskType) }
            countsByDisk[item.diskType, default: 0] += 1
        }
        diskTypes = types; diskCounts = countsByDisk
        dateOrderedItems = items.enumerated().sorted { lhs, rhs in
            let left = itemDates[lhs.element.id] ?? -.infinity, right = itemDates[rhs.element.id] ?? -.infinity
            return left == right ? lhs.offset < rhs.offset : left > right
        }.map(\.element)
    }
    /// Provider tabs follow the service's first appearance order, as in HomePan.
    public func visibleItems(disk: String = "", hideInvalid: Bool = true, checksEnabled: Bool = true,
                             checks: [String: PanLinkStatus]) -> [PanSearchItem] {
        // Dates never change while checking links. Preserve their precomputed order
        // and partition valid links instead of sorting every full-list redraw.
        var valid = [PanSearchItem](), other = [PanSearchItem]()
        for item in dateOrderedItems where disk.isEmpty || disk == item.diskType {
            let state = checksEnabled ? checks[item.id]?.state : nil
            if hideInvalid && state == .bad { continue }
            if state == .ok { valid.append(item) } else { other.append(item) }
        }
        return valid + other
    }
    public init(json: JSONValue) throws {
        guard let object = json.object, let query = object["query"]?.string, let rows = object["items"]?.array else {
            throw TVError.unsupported("盘搜未返回有效资源")
        }
        let items = try rows.map { row -> PanSearchItem in
            guard let f = row.object, let id = f["id"]?.string, let title = f["title"]?.string,
                  let url = f["url"]?.string, let input = f["input"]?.string, let type = f["diskType"]?.string else {
                throw TVError.unsupported("盘搜返回的资源缺少分享信息")
            }
            return PanSearchItem(id: id, title: title, url: url, input: input, diskType: type,
                                 password: f["password"]?.string ?? "", source: f["source"]?.string ?? "", datetime: f["datetime"]?.string ?? "")
        }
        self.init(query: query, items: items, counts: object["counts"]?.object?.compactMapValues(\.int) ?? [:], partial: object["partial"] == .bool(true))
    }
}

public struct PanLinkStatus: Identifiable, Equatable, Sendable {
    public enum State: String, CaseIterable, Sendable { case ok, bad, locked, unsupported, uncertain }
    public let id: String
    public let state: State
    public let summary: String
    public init(id: String, state: State, summary: String) { self.id = id; self.state = state; self.summary = summary }
}
public struct PanCheckResult: Sendable {
    public let enabled: Bool
    public let items: [PanLinkStatus]
    public init(json: JSONValue) throws {
        guard let fields = json.object, let rows = fields["items"]?.array else { throw TVError.unsupported("链接检测返回格式无效") }
        enabled = fields["enabled"] == .bool(true)
        items = try rows.map { row in
            guard let f = row.object, let id = f["id"]?.string else { throw TVError.unsupported("链接检测缺少资源标识") }
            return PanLinkStatus(id: id, state: PanLinkStatus.State(rawValue: f["state"]?.string ?? "") ?? .uncertain,
                                 summary: f["summary"]?.string ?? "暂时无法确认")
        }
    }
}

public enum PanSearchService {
    public static func search(_ query: String, year: String?) async throws -> PanSearchResult {
        try await PanSearchResult(json: MobileMediaServices.call("pan.search", ["query": .string(query), "year": .string(year ?? "")]))
    }
    public static func checkParameters(_ items: [PanSearchItem], refresh: Bool, manual: Bool) -> [String: JSONValue] {
        ["items": .array(items.map(\.checkInput)), "refresh": .bool(refresh), "manual": .bool(manual)]
    }
    public static func check(_ items: [PanSearchItem], refresh: Bool, manual: Bool = false) async throws -> PanCheckResult {
        try await PanCheckResult(json: MobileMediaServices.call("pan.check", checkParameters(items, refresh: refresh, manual: manual)))
    }
}

/// Request ownership for a retained native page; a cancelled/late provider can never replace another query.
@MainActor @Perceptible public final class PanSearchModel {
    public private(set) var query = ""
    public private(set) var year: String?
    public private(set) var metadataHint: MediaMetadataHint?
    public private(set) var result: PanSearchResult?
    public private(set) var checks: [String: PanLinkStatus] = [:]
    /// Retained presentation: scrolling reads this array without any filtering or sorting.
    public private(set) var visibleItems: [PanSearchItem] = []
    public private(set) var checkCounts: [PanLinkStatus.State: Int] = [:]
    @PerceptionIgnored private var selectedDisk = ""
    @PerceptionIgnored private var hideInvalid = true
    @PerceptionIgnored private var checksEnabled = true
    @PerceptionIgnored private var projectionTask: Task<Void, Never>?
    public private(set) var searching = false
    public private(set) var checking = false
    public private(set) var checkingIDs = Set<String>()
    private var checkedAt: [String: Date] = [:]
    public private(set) var error: String?
    private var generation = 0
    private var checkGeneration = 0
    public init() {}
    public func setFilter(disk: String, hideInvalid: Bool, checksEnabled: Bool) {
        guard disk != selectedDisk || hideInvalid != self.hideInvalid || checksEnabled != self.checksEnabled else { return }
        selectedDisk = disk; self.hideInvalid = hideInvalid; self.checksEnabled = checksEnabled
        updateVisibleItems()
    }
    private func scheduleVisibleItems() {
        guard projectionTask == nil else { return }
        projectionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, let self else { return }
            self.updateVisibleItems()
        }
    }
    private func updateVisibleItems() {
        projectionTask?.cancel(); projectionTask = nil
        let next = result?.visibleItems(disk: selectedDisk, hideInvalid: hideInvalid, checksEnabled: checksEnabled, checks: checks) ?? []
        if next != visibleItems { visibleItems = next }
    }
    public func updateQuery(_ value: String, year: String? = nil, metadataHint: MediaMetadataHint? = nil) {
        cancel(); query = value; self.year = year; self.metadataHint = metadataHint
        result = nil; checks = [:]; checkCounts = [:]; visibleItems = []; checkedAt = [:]; error = nil
    }
    public func cancel() { updateVisibleItems(); generation += 1; checkGeneration += 1; searching = false; checking = false; checkingIDs = [] }
    public func search(using read: @escaping @Sendable (String, String?) async throws -> PanSearchResult = PanSearchService.search) async {
        generation += 1; checkGeneration += 1
        let own = generation, value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { error = "请输入片名"; return }
        searching = true; checking = false; checkingIDs = []; error = nil; result = nil; checks = [:]; checkCounts = [:]; visibleItems = []; checkedAt = [:]
        defer { if own == generation { searching = false } }
        do {
            let answer = try await read(value, year)
            guard own == generation, !Task.isCancelled else { return }
            result = answer; updateVisibleItems()
        } catch { if own == generation, !Task.isCancelled { self.error = error.localizedDescription } }
    }
    public func check(refresh: Bool = false, using read: @escaping @Sendable ([PanSearchItem], Bool) async throws -> PanCheckResult = { items, refresh in try await PanSearchService.check(items, refresh: refresh) }) async {
        guard let result, !result.items.isEmpty else { return }
        checkGeneration += 1
        let own = checkGeneration, search = generation
        // Resume a retained page without repeatedly checking recent outcomes.
        // Explicit refresh removes the old badges while replacements are pending.
        let pending = result.items.filter { refresh || checks[$0.id] == nil || Date().timeIntervalSince(checkedAt[$0.id] ?? .distantPast) >= 300 }
        if refresh { checks = [:]; checkCounts = [:]; checkedAt = [:]; updateVisibleItems() }
        checkingIDs = Set(pending.map(\.id)); checking = !pending.isEmpty
        defer { if own == checkGeneration { checking = false; checkingIDs = []; updateVisibleItems() } }
        await withTaskGroup(of: (String, Bool, PanLinkStatus).self) { group in
            var next = 0
            func enqueue(_ item: PanSearchItem) {
                group.addTask {
                    do {
                        let reply = try await read([item], refresh)
                        let status = reply.items.first { $0.id == item.id }
                            ?? PanLinkStatus(id: item.id, state: .uncertain, summary: "暂时无法确认")
                        return (item.id, reply.enabled, status)
                    } catch {
                        return (item.id, true, PanLinkStatus(id: item.id, state: .uncertain, summary: "网络连接失败，暂时无法确认"))
                    }
                }
            }
            // Publish each finished link independently. A slow provider must
            // never hold back nineteen completed results in the same RPC batch.
            while next < min(10, pending.count) { enqueue(pending[next]); next += 1 }
            for await (id, enabled, status) in group {
                guard own == checkGeneration, search == generation, !Task.isCancelled else { group.cancelAll(); return }
                guard enabled else { group.cancelAll(); return }
                if let previous = checks[id] { checkCounts[previous.state, default: 0] -= 1 }
                checks[id] = status; checkCounts[status.state, default: 0] += 1
                checkedAt[id] = Date(); checkingIDs.remove(id); scheduleVisibleItems()
                if next < pending.count { enqueue(pending[next]); next += 1 }
            }
        }
    }
}
