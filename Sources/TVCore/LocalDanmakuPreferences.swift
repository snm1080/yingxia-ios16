import Foundation

public enum LocalDanmakuPreferences {
    public static let builtinKey = "danmakuBuiltinEnabled"
    public static let changed = Notification.Name("LocalDanmakuConfigurationChanged")
    public static func enabled(defaults: UserDefaults = .standard) -> Bool { defaults.object(forKey: "danmakuEnabled") as? Bool ?? true }
    public static func builtinEnabled(defaults: UserDefaults = .standard) -> Bool { defaults.object(forKey: builtinKey) as? Bool ?? true }
    public static func hasBuiltin(_ raw: [String: JSONValue]) -> Bool {
        for key in ["danmaku", "danmu", "danmu_api", "danmaku_api", "danmuSearchUrl"] {
            guard let value = raw[key] else { continue }
            switch value {
            case .string(let value): if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
            case .array(let value): if !value.isEmpty { return true }
            case .object(let value): if !value.isEmpty { return true }
            default: break
            }
        }
        return ["video", "data", "config"].contains { key in raw[key]?.object.map(hasBuiltin) ?? false }
    }
}
