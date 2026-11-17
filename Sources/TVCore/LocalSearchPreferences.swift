import Foundation

public struct LocalSearchPreferences: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        case `default`, all, groups
        public var title: String { switch self { case .default: "默认"; case .all: "全部"; case .groups: "分组" } }
    }
    public struct Group: Codable, Equatable, Identifiable, Sendable {
        public var id: String
        public var name: String
        public var siteIDs: [String]
        public init(id: String = UUID().uuidString, name: String = "", siteIDs: [String] = []) {
            self.id = id; self.name = name; self.siteIDs = siteIDs
        }
    }
    public var mode: Mode = .default
    public var disabledSiteIDs: Set<String> = []
    public var groups: [Group] = []
    public init() {}
    /// Stable membership is independent of collision suffixes and imported code versions.
    public static func memberID(for site: Site, fallbackOrigin: URL? = nil) -> String {
        guard let origin = site.provenance?.origin ?? fallbackOrigin else { return site.id }
        var address = URLComponents(url: origin, resolvingAgainstBaseURL: true)
        address?.fragment = nil
        let scheme = address?.scheme?.lowercased(), host = address?.host?.lowercased()
        address?.scheme = scheme
        address?.host = host
        if address?.host == "sources.yingxia.invalid", let record = origin.pathComponents.first(where: { $0 != "/" }) {
            address?.path = "/" + record + "/subscription"
            address?.query = nil
        }
        let scope = address?.url?.absoluteString ?? origin.absoluteString
        return "source:" + PluginChecksum.sha256(Data((scope + "\n" + site.sourceKey).utf8))
    }
    /// Convert current legacy presentation keys while their provenance is still available.
    public func normalized(for config: Subscription) -> Self {
        let members = Dictionary(config.sites.map { ($0.id, Self.memberID(for: $0)) }, uniquingKeysWith: { first, _ in first })
        func member(_ id: String) -> String { members[id] ?? id }
        var value = self
        value.disabledSiteIDs = Set(disabledSiteIDs.map(member))
        value.groups = groups.map { group in
            var group = group
            var seen = Set<String>()
            group.siteIDs = group.siteIDs.map(member).filter { seen.insert($0).inserted }
            return group
        }
        return value
    }
    public func resolvedGroups(sites: [Site]) -> [Group] {
        // Resolve each stable provenance identity once. A group containing 400 sources
        // previously recomputed all 400 SHA-256 identities for every one of its members.
        var members: [String: [String]] = [:]
        for site in sites {
            let stable = Self.memberID(for: site)
            members[stable, default: []].append(site.id)
            if stable != site.id { members[site.id, default: []].append(site.id) }
        }
        return groups.map { group in
            var value = group
            value.siteIDs = group.siteIDs.flatMap { members[$0] ?? [] }
            return value
        }
    }
    public func sites(from sites: [Site]) -> [Site] {
        let eligible = sites.filter(\.searchable)
        switch mode {
        case .all: return eligible
        case .default: return eligible.filter { !disabledSiteIDs.contains(Self.memberID(for: $0)) && !disabledSiteIDs.contains($0.id) }
        case .groups:
            let byID = Dictionary(eligible.flatMap { [(Self.memberID(for: $0), $0), ($0.id, $0)] }, uniquingKeysWith: { first, _ in first })
            var seen = Set<String>()
            return groups.flatMap(\.siteIDs).compactMap { id in
                guard let site = byID[id], seen.insert(site.id).inserted else { return nil }
                return site
            }
        }
    }
    /// Members keep their source IDs while library versions and enabled origins change.
    private static let storageKey = "local.search.preferences.v2"
    private static func legacyKey(_ config: Subscription) -> String {
        let origins = Set(config.sites.map { $0.origin(or: config.origin).absoluteString }).sorted()
        return "local.search.preferences." + origins.joined(separator: "|")
    }
    public static func load(config: Subscription, defaults: UserDefaults = .standard) -> Self {
        if let data = defaults.data(forKey: storageKey), let preferences = try? JSONDecoder().decode(Self.self, from: data) {
            let value = preferences.normalized(for: config)
            if value != preferences { value.save(config: config, defaults: defaults) }
            return value
        }
        if let data = defaults.data(forKey: legacyKey(config)), let preferences = try? JSONDecoder().decode(Self.self, from: data) {
            preferences.save(config: config, defaults: defaults)
            return preferences.normalized(for: config)
        }
        return Self()
    }
    public func save(config: Subscription, defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(normalized(for: config)) { defaults.set(data, forKey: Self.storageKey) }
    }
}
