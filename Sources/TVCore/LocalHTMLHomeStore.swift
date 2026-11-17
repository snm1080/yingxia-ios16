import Foundation

public struct LocalHTMLHomeSource: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let address: String?
    public let filename: String?
    public var isFile: Bool { filename != nil }
}

/// Local HTML is copied into one managed directory; the original document's
/// security scope is needed only while copying. No external bookmark is kept.
public struct LocalHTMLHomeStore: Codable, Equatable, Sendable {
    public static let key = "local.htmlHome.v1"
    public static let changed = Notification.Name("LocalHTMLHomeChanged")
    public private(set) var sources: [LocalHTMLHomeSource] = []
    public private(set) var activeID = "builtin"
    public private(set) var lastHTMLID: String?
    public var active: LocalHTMLHomeSource? { sources.first { $0.id == activeID } }
    public init() {}
    private enum CodingKeys: String, CodingKey { case sources, activeID, lastHTMLID }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sources = try values.decode([LocalHTMLHomeSource].self, forKey: .sources)
        activeID = try values.decodeIfPresent(String.self, forKey: .activeID) ?? "builtin"
        // Older libraries only saved the selected home. Adopt it once without
        // losing it when the new startup preference opens the built-in homepage.
        lastHTMLID = try values.decodeIfPresent(String.self, forKey: .lastHTMLID)
            ?? (activeID == "builtin" ? nil : activeID)
    }
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HTMLHome", isDirectory: true)
    }
    public static func load(defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: key), var value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        if !value.sources.contains(where: { $0.id == value.activeID }) { value.activeID = "builtin" }
        if !value.sources.contains(where: { $0.id == value.lastHTMLID }) { value.lastHTMLID = nil }
        return value
    }
    public func save(defaults: UserDefaults = .standard) throws {
        defaults.set(try JSONEncoder().encode(self), forKey: Self.key)
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }
    public mutating func select(_ id: String) {
        if id == "builtin" { activeID = id }
        else if sources.contains(where: { $0.id == id }) { activeID = id; lastHTMLID = id }
    }
    /// Startup and explicit source selection have different meanings. Home
    /// always means built-in; only Last HTML restores the previous HTML source.
    public mutating func restoreStartup(_ destination: LocalHomeDestination, directory: URL = Self.directory) {
        activeID = "builtin"
        guard destination == .lastHTML, let source = sources.first(where: { $0.id == lastHTMLID }) else { return }
        if source.isFile {
            guard (try? html(for: source, directory: directory)) != nil else { return }
        } else {
            guard let address = source.address, let url = URL(string: address),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return }
        }
        activeID = source.id
    }
    public mutating func addRemote(name: String, address: String) throws {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address.count <= 32768, let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { throw HTMLHomeError.invalidAddress }
        guard sources.count < 64 else { throw HTMLHomeError.tooMany }
        guard !sources.contains(where: { $0.address == url.absoluteString }) else { throw HTMLHomeError.duplicate }
        sources.append(.init(id: UUID().uuidString, name: Self.title(name, fallback: host), address: url.absoluteString, filename: nil))
    }
    public mutating func importHTML(name: String, originalFilename: String, data: Data, directory: URL = Self.directory) throws {
        guard ["html", "htm"].contains((originalFilename as NSString).pathExtension.lowercased()),
              !data.isEmpty, data.count <= 1024 * 1024, let html = Self.decode(data), !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw HTMLHomeError.invalidFile }
        guard sources.count < 64 else { throw HTMLHomeError.tooMany }
        let id = UUID().uuidString, filename = id + ".html"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(filename), options: .atomic)
        sources.append(.init(id: id, name: Self.title(name, fallback: (originalFilename as NSString).deletingPathExtension), address: nil, filename: filename))
    }
    public mutating func remove(_ id: String, directory: URL = Self.directory, defaults: UserDefaults = .standard) throws {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        if let filename = sources[index].filename {
            let file = try Self.managedFile(filename, directory: directory)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
        sources.remove(at: index)
        defaults.removeObject(forKey: Self.cacheKey(id))
        if activeID == id { activeID = "builtin" }
        if lastHTMLID == id { lastHTMLID = nil }
    }
    /// List ordering changes presentation only; active and last-used homes are identified by ID.
    public mutating func move(_ id: String, by offset: Int) {
        guard offset != 0, let index = sources.firstIndex(where: { $0.id == id }),
              offset >= -index, offset < sources.count - index else { return }
        let source = sources.remove(at: index)
        sources.insert(source, at: index + offset)
    }
    public mutating func move(_ id: String, onto target: String) {
        guard let from = sources.firstIndex(where: { $0.id == id }),
              let to = sources.firstIndex(where: { $0.id == target }) else { return }
        move(id, by: to - from)
    }
    public func html(for source: LocalHTMLHomeSource, directory: URL = Self.directory) throws -> String {
        guard let filename = source.filename, sources.contains(where: { $0.id == source.id }) else { throw HTMLHomeError.invalidFile }
        let file = try Self.managedFile(filename, directory: directory)
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 1024 * 1024 else { throw HTMLHomeError.invalidFile }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        guard data.count <= 1024 * 1024, let html = Self.decode(data),
              !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw HTMLHomeError.invalidFile }
        return html
    }
    public static func cache(for id: String, defaults: UserDefaults = .standard) -> [String: String] {
        guard let data = defaults.data(forKey: cacheKey(id)), data.count <= 2 * 1024 * 1024 else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }
    public static func saveCache(_ cache: [String: String], for id: String, defaults: UserDefaults = .standard) throws {
        guard load(defaults: defaults).sources.contains(where: { $0.id == id }) else { throw HTMLHomeError.invalidFile }
        let data = try JSONEncoder().encode(cache)
        guard data.count <= 2 * 1024 * 1024 else { throw HTMLHomeError.cacheTooLarge }
        defaults.set(data, forKey: cacheKey(id))
    }
    private static func cacheKey(_ id: String) -> String { "local.htmlHome.cache." + id }
    private static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { return String(data: data, encoding: .utf16) }
        return String(data: data, encoding: .utf8)
    }
    private static func managedFile(_ name: String, directory: URL) throws -> URL {
        guard name == (name as NSString).lastPathComponent, UUID(uuidString: String(name.dropLast(5))) != nil, name.hasSuffix(".html") else { throw HTMLHomeError.invalidFile }
        return directory.appendingPathComponent(name)
    }
    private static func title(_ name: String, fallback: String) -> String {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((value.isEmpty ? fallback : value).prefix(120))
    }
    public enum HTMLHomeError: LocalizedError {
        case invalidAddress, invalidFile, tooMany, duplicate, cacheTooLarge
        public var errorDescription: String? {
            switch self {
            case .invalidAddress: "请填写 HTTP / HTTPS 首页地址。"
            case .invalidFile: "请选择不超过 1 MB 的 UTF-8 / UTF-16 HTML 或 HTM 文件。"
            case .tooMany: "最多可保存 64 个自定义首页。"
            case .duplicate: "该首页地址已添加。"
            case .cacheTooLarge: "首页缓存超过 2 MB，请清理此首页内的缓存后重试。"
            }
        }
    }
}
