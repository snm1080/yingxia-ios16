import Foundation
import CryptoKit

public enum LocalBackupCategory: String, CaseIterable, Codable, Identifiable, Sendable {
    case history, favorites, settings, sources
    public var id: String { rawValue }
    public var title: String { switch self { case .history: "观看记录"; case .favorites: "收藏"; case .settings: "应用设置"; case .sources: "订阅与 Python 来源文件" } }
}

public struct LocalBackupSource: Codable, Equatable, Sendable {
    public var record: Data
    public var files: [String: Data]
    public init(record: Data, files: [String: Data]) { self.record = record; self.files = files }
}

public struct LocalBackupPayload: Codable, Equatable, Sendable {
    public var history: [Data] = []
    public var favorites: [Data] = []
    public var settings: [String: Data] = [:]
    public var subscriptions = Data()
    public var sourceGroups = Data()
    public var sources: [LocalBackupSource] = []
    /// Private undo journal only. Portable exports leave this empty.
    public var documents: [String: Data] = [:]
    public init() {}
}

public struct LocalBackupArchive: Codable, Sendable {
    public static let maximumBytes = 128 * 1024 * 1024
    public let schema: Int
    public let app: String
    public let createdAt: Date
    public let payload: Data
    public let sha256: String
    public init(_ value: LocalBackupPayload, now: Date = Date()) throws {
        schema = 1; app = "Yingxia-iOS"; createdAt = now
        payload = try JSONEncoder().encode(value)
        sha256 = Self.digest(payload)
        guard payload.count < Self.maximumBytes else { throw Failure.tooLarge }
    }
    public func encoded() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumBytes else { throw Failure.tooLarge }
        return data
    }
    public static func read(_ data: Data) throws -> (Self, LocalBackupPayload) {
        guard data.count <= maximumBytes else { throw Failure.tooLarge }
        let header = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard header?["app"] as? String == "Yingxia-iOS", header?["schema"] as? Int == 1 else { throw Failure.version }
        let archive = try JSONDecoder().decode(Self.self, from: data)
        guard archive.sha256 == digest(archive.payload) else { throw Failure.checksum }
        var value = try JSONDecoder().decode(LocalBackupPayload.self, from: archive.payload)
        // Older exports may contain the retired feature switch. Keep the rest of
        // that backup usable without silently hiding whole sections after restore.
        value.settings.removeValue(forKey: "local.hiddenFeatures")
        guard value.history.count <= 100_000, value.favorites.count <= 100_000, value.sources.count <= 200,
              value.documents.isEmpty, value.settings.keys.allSatisfy(isAllowedSetting) else { throw Failure.invalid }
        for source in value.sources {
            guard !source.files.isEmpty, source.files.count <= 1000,
                  source.files.keys.allSatisfy(safePath), source.files.values.reduce(0, { $0 + $1.count }) <= 90 * 1024 * 1024 else { throw Failure.invalid }
        }
        return (archive, value)
    }
    public static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func safePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.contains("\0")
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    public static func isAllowedSetting(_ key: String) -> Bool {
        let names: Set<String> = ["local.appearance", "local.home.defaultDestination", "local.home.continueWatching",
            "local.library.historyLayout", "local.library.favoritesLayout", "local.videoCache.enabled", "local.videoCache.sizeGB",
            "local.playback.prefetchNext", "local.hlsAdClean", "autoPlayNextEpisode", "subtitleStyle",
            "danmakuEnabled", "danmakuAutoMatch", "danmakuBuiltinEnabled", "danmakuFontSize", "danmakuOpacity", "danmakuArea",
            "danmakuFontFamily", "danmakuFontWeight", "danmakuLineSpacing", "danmakuDelay", "danmakuSpeed", "danmakuMaxRows",
            "danmakuAreaPercent", "danmakuColorMode", "danmakuGradientStart", "danmakuGradientEnd", "danmakuFancyEnabled",
            "danmakuFancyRatio", "danmakuFancyIcons", "danmakuFancyKinds", "danmakuFancyWeights", "danmakuFancyNames",
            "local.mediaBadges.enabled", "onlineSubtitle.xunlei", "onlineSubtitle.shooter", "onlineSubtitle.assrt",
            "onlineSubtitle.subtitlecat", "onlineSubtitle.subhd", "onlineSubtitle.language",
            "local.playback.subtitleDelay", "local.playback.videoAspect", "local.playback.queueView", "local.playback.informationStyle"]
        return names.contains(key)
    }
    /// Library headers and temporary/authenticated URLs are omitted just as in
    /// MacCat's portable backup. Source code files remain byte-for-byte intact.
    public static func portable(_ data: Data) throws -> Data {
        func clean(_ value: Any, depth: Int) throws -> Any {
            guard depth <= 30 else { throw Failure.invalid }
            if let object = value as? [String: Any] {
                var next: [String: Any] = [:]
                for (key, value) in object {
                    if ["__proto__", "constructor", "prototype", "bookmarks"].contains(key) { continue }
                    if key.lowercased().contains("header") { next[key] = [String: String](); continue }
                    if key.range(of: #"^(authorization|cookie|token|api.?key|password|passwd|secret|credentials?)$"#, options: [.regularExpression, .caseInsensitive]) != nil { continue }
                    next[key] = try clean(value, depth: depth + 1)
                }
                return next
            }
            if let values = value as? [Any] { return try values.map { try clean($0, depth: depth + 1) } }
            if let string = value as? String, var parts = URLComponents(string: string), ["http", "https"].contains(parts.scheme?.lowercased() ?? "") {
                parts.user = nil; parts.password = nil
                parts.queryItems = parts.queryItems?.filter { $0.name.range(of: "token|sign|key|auth|credential|password|cookie|expire|pwd", options: [.regularExpression, .caseInsensitive]) == nil }
                if parts.queryItems?.isEmpty == true { parts.queryItems = nil }
                return parts.string ?? ""
            }
            return value
        }
        return try JSONSerialization.data(withJSONObject: clean(JSONSerialization.jsonObject(with: data), depth: 0), options: [.sortedKeys])
    }
    public enum Failure: LocalizedError {
        case tooLarge, version, checksum, invalid
        public var errorDescription: String? {
            switch self {
            case .tooLarge: "备份不能超过 128 MiB。"
            case .version: "请选择映匣 iOS 备份。MacCat 桌面版备份格式暂不支持。"
            case .checksum: "备份校验失败，文件可能已损坏。"
            case .invalid: "备份包含无效字段或来源文件。"
            }
        }
    }
}
