import Foundation

/// Merge keys can change when another subscription is enabled. Keep the original source key and owner.
struct LocalHomeSourceSelection: Codable, Hashable {
    let origin: String
    let sourceKey: String
    let python: Bool

    init(origin: String, sourceKey: String, python: Bool) {
        self.origin = Self.stableOrigin(origin)
        self.sourceKey = sourceKey
        self.python = python
    }

    func save(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey(python: python))
    }

    static func saved(python: Bool, defaults: UserDefaults = .standard) -> Self? {
        guard let data = defaults.data(forKey: storageKey(python: python)),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.python == python, !value.origin.isEmpty, !value.sourceKey.isEmpty else { return nil }
        // Also adopt records saved before owned JSON versions used the stable record address.
        return Self(origin: value.origin, sourceKey: value.sourceKey, python: value.python)
    }

    static func destination(_ preference: String, available: [Self], defaults: UserDefaults = .standard) -> Self? {
        guard preference == "lastSite" || preference == "lastPython",
              let saved = saved(python: preference == "lastPython", defaults: defaults) else { return nil }
        return available.first { $0 == saved }
    }

    private static func storageKey(python: Bool) -> String { "local.home." + (python ? "lastPython" : "lastSite") }

    static func stableOrigin(_ address: String) -> String {
        guard let url = URL(string: address), url.host?.lowercased() == "sources.yingxia.invalid",
              let record = url.pathComponents.dropFirst().first else { return address }
        // Runtime asset URLs include a version hash. Navigation owns the record, not one downloaded version.
        return "https://sources.yingxia.invalid/\(record)/subscription"
    }
}
