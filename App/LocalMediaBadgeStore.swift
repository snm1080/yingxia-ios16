import Foundation
import CryptoKit

struct LocalMediaBadgeSource: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let address: String
    let data: Data
    static let builtin = Self(id: "builtin", name: "内置徽章", address: "", data: Data())
    var isBuiltin: Bool { id == Self.builtin.id }
    var rules: PlayerBadgeRules? {
        let data = isBuiltin ? Bundle.main.url(forResource: "maccat-media-badges", withExtension: "json").flatMap { try? Data(contentsOf: $0) } : data
        return data.flatMap { try? PlayerBadgeRules(data: $0) }
    }
}

struct LocalMediaBadgeStore: Codable, Sendable {
    static let key = "local.mediaBadges.v1"
    static let enabledKey = "local.mediaBadges.enabled"
    static let changed = Notification.Name("LocalMediaBadgesChanged")
    private(set) var sources: [LocalMediaBadgeSource] = [.builtin]
    private(set) var activeID = "builtin"
    var active: LocalMediaBadgeSource { sources.first { $0.id == activeID } ?? .builtin }
    static func load(defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: key), var value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        value.sources.removeAll { $0.isBuiltin }
        value.sources.insert(.builtin, at: 0)
        if !value.sources.contains(where: { $0.id == value.activeID }) { value.activeID = "builtin" }
        return value
    }
    func save(defaults: UserDefaults = .standard) throws {
        defaults.set(try JSONEncoder().encode(self), forKey: Self.key)
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }
    mutating func apply(_ id: String) {
        if sources.contains(where: { $0.id == id }) { activeID = id }
    }
    mutating func remove(_ id: String) {
        guard id != "builtin" else { return }
        sources.removeAll { $0.id == id }
        if activeID == id { activeID = "builtin" }
    }
    /// Parse before mutating, so a failed refresh preserves the previously saved catalog.
    mutating func add(address: String, data: Data) throws {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard data.count <= 4 * 1024 * 1024, let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil, url.fragment == nil else { throw BadgeError.invalidAddress }
        let rules = try PlayerBadgeRules(data: data)
        guard !rules.rules.isEmpty, rules.rules.count <= 2000,
              Set(rules.rules.map(\.row.id)).count == rules.rules.count else { throw BadgeError.emptyCatalog }
        let id = SHA256.hash(data: Data(address.utf8)).map { String(format: "%02x", $0) }.joined()
        guard sources.count < 31 || sources.contains(where: { $0.id == id }) else { throw BadgeError.tooMany }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let supplied = ((object?["name"] as? String) ?? (object?["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let filename = url.deletingPathExtension().lastPathComponent
        let name = String((supplied.isEmpty ? (filename.isEmpty ? url.host! : filename) : supplied).prefix(80))
        let source = LocalMediaBadgeSource(id: id, name: name, address: address, data: data)
        if let index = sources.firstIndex(where: { $0.id == id }) { sources[index] = source }
        else { sources.append(source) }
    }
    enum BadgeError: LocalizedError {
        case invalidAddress, emptyCatalog, tooMany
        var errorDescription: String? {
            switch self {
            case .invalidAddress: "请填写 HTTP / HTTPS 徽章 JSON 地址，文件不得超过 4 MB。"
            case .emptyCatalog: "该地址没有可用的媒体徽章规则。"
            case .tooMany: "最多可保存 30 个自定义徽章方案。"
            }
        }
    }
}
