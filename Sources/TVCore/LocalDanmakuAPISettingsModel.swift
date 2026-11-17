import Foundation

/// The editor owns a draft until validation and persistence both succeed.
public struct LocalDanmakuAPISettingsModel {
    public private(set) var entries: [NativeDanmakuAPI]
    public private(set) var builtin: Bool
    public private(set) var isEditing = false
    private var editingID: String?
    public var name = ""
    public var address = ""
    public private(set) var message = ""

    public init(defaults: UserDefaults = .standard) {
        entries = NativeDanmakuAPIStore.load(defaults: defaults)
        builtin = LocalDanmakuPreferences.builtinEnabled(defaults: defaults)
    }
    public mutating func beginAdding() {
        editingID = nil; name = ""; address = ""; message = ""; isEditing = true
    }
    public mutating func beginEditing(_ id: String) {
        guard let api = entries.first(where: { $0.id == id }) else { return }
        editingID = id; name = api.name; address = api.url; message = ""; isEditing = true
    }
    public mutating func cancelEditing() {
        editingID = nil; name = ""; address = ""; message = ""; isEditing = false
    }
    @discardableResult public mutating func save(defaults: UserDefaults = .standard) -> Bool {
        guard isEditing else { return false }
        var next = entries
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if let editingID {
            guard let index = next.firstIndex(where: { $0.id == editingID }) else {
                message = "该 API 已删除，请取消后重新添加。"; return false
            }
            next[index].name = title; next[index].url = url
        } else { next.append(NativeDanmakuAPI(name: title, url: url)) }
        guard persist(next, defaults: defaults) else { return false }
        cancelEditing(); message = "已保存弹幕 API。"
        return true
    }
    public mutating func setEnabled(_ enabled: Bool, id: String, defaults: UserDefaults = .standard) {
        var next = entries
        guard let index = next.firstIndex(where: { $0.id == id }) else { return }
        next[index].enabled = enabled
        _ = persist(next, defaults: defaults)
    }
    public mutating func remove(_ id: String, defaults: UserDefaults = .standard) {
        let next = entries.filter { $0.id != id }
        guard next.count != entries.count, persist(next, defaults: defaults) else { return }
        if editingID == id { cancelEditing() }
    }
    public mutating func setBuiltinEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        builtin = enabled
        defaults.set(enabled, forKey: LocalDanmakuPreferences.builtinKey)
        NotificationCenter.default.post(name: LocalDanmakuPreferences.changed, object: nil)
    }
    private mutating func persist(_ next: [NativeDanmakuAPI], defaults: UserDefaults) -> Bool {
        do {
            try NativeDanmakuAPIStore.save(next, defaults: defaults)
            entries = next; message = "已保存弹幕 API。"
            return true
        } catch { message = error.localizedDescription; return false }
    }
}
