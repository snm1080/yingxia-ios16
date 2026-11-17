import TVCore

extension Store {
    /// The import category owns navigation. A Python entry can itself contain a Node bundle,
    /// and an ordinary TVBox subscription can list Python alongside other script runtimes.
    func localSourceGroup(for site: Site) -> LocalSourceGroup {
        if let config = subscription {
            let origin = LocalHomeSourceSelection.stableOrigin(site.origin(or: config.origin).absoluteString)
            if let owner = subscriptions.first(where: {
                $0.enabled && documents[$0.address].map { LocalHomeSourceSelection.stableOrigin($0.origin.absoluteString) == origin } == true
            }) {
                return localSourceGroups[owner.address] ?? .subscription
            }
        }
        return site.runtime == .python ? .python : .subscription
    }
}
