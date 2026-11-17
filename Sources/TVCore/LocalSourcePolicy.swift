import Foundation

/// One subscription is selected at a time. Each Python source has its own independent switch.
public enum LocalSourcePolicy {
    public static func setting(_ address: String, enabled: Bool, in entries: [SubscriptionEntry], groups: [String: LocalSourceGroup]) -> [SubscriptionEntry] {
        guard entries.contains(where: { $0.address == address }) else { return entries }
        let category = groups[address] ?? .subscription
        return entries.map { entry in
            var value = entry
            if entry.address == address { value.enabled = enabled }
            else if enabled, category == .subscription, (groups[entry.address] ?? .subscription) == .subscription { value.enabled = false }
            return value
        }
    }

    /// Keep every imported entry and its Python switch. Older subscription lists may contain
    /// multiple selections; the first enabled subscription owns the current library.
    public static func normalized(_ entries: [SubscriptionEntry], groups: [String: LocalSourceGroup]) -> [SubscriptionEntry] {
        var hasSubscription = false
        return entries.map { entry in
            var value = entry
            if value.enabled, (groups[entry.address] ?? .subscription) == .subscription {
                value.enabled = !hasSubscription
                hasSubscription = true
            }
            return value
        }
    }

    /// Generic bundle filenames are not useful names; use the nearest meaningful URL component.
    /// Query parameters and URL credentials never become a display name.
    public static func name(for url: URL, isDirectory: Bool = false) -> String {
        if url.isFileURL {
            return isDirectory ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        }
        let parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        if url.host()?.lowercased() == "raw.githubusercontent.com", parts.count > 1 { return parts[1] }
        let generic: Set<String> = ["index", "index.config", "config", "subscription", "subscriptions", "tvbox", "api", "raw", "main", "master"]
        for part in parts.reversed() {
            var name = part
            for suffix in [".md5", ".json", ".zip", ".js", ".py"] where name.lowercased().hasSuffix(suffix) {
                name = String(name.dropLast(suffix.count))
            }
            if !name.isEmpty, !generic.contains(name.lowercased()) { return name }
        }
        let host = url.host() ?? "来源"
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
