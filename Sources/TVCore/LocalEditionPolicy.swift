import Foundation

public enum LocalEditionPolicy {
    /// A merged imported source has provenance; a lone document declares its sites in raw data.
    /// Old app catalogs appended provider/drive rows without either. Never identify those rows
    /// by display name or key alone: an explicitly imported source may use the very same name.
    public static func importedCatalog(_ document: Subscription) -> Subscription {
        let declared = (document.raw["sites"]?.array ?? []).compactMap(\.object)
        let sites = document.sites.filter { site in
            if site.provenance != nil || !site.isBuiltIn { return true }
            return declared.contains { $0["key"]?.string == site.sourceKey && $0["api"]?.string == site.api }
        }
        guard sites.count != document.sites.count else { return document }
        return Subscription(origin: document.origin, importedAt: document.importedAt,
                            sites: sites, lives: document.lives, raw: document.raw)
    }

    /// This receives only the application's own source document, never a user's subscription.
    public static func withoutBuiltInLive(_ document: Subscription) -> Subscription {
        var raw = document.raw
        raw["yingxiaLive"] = .array([])
        raw["lives"] = .array([])
        return Subscription(origin: document.origin, importedAt: document.importedAt,
                            sites: document.sites, lives: [], raw: raw)
    }
}
