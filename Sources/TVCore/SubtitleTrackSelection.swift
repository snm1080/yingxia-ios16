/// Requested primary and secondary subtitle tracks. `nil` means automatic and `"no"` means off.
/// Selection stays independent of the decoder's enabled flags: text subtitle streams may continue
/// decoding while hidden, and must never leak into the other subtitle slot.
public struct SubtitleTrackSelection: Equatable, Sendable {
    public enum Target: String, CaseIterable, Sendable { case primary, secondary }

    public func selection(for target: Target) -> String? { target == .primary ? primary : secondary }
    public mutating func select(_ id: String?, for target: Target) {
        if target == .primary { selectPrimary(id) } else { selectSecondary(id) }
    }

    public private(set) var primary: String?
    public private(set) var secondary: String?

    public init(primary: String? = nil, secondary: String? = "no") {
        self.primary = Self.normalized(primary)
        self.secondary = Self.normalized(secondary)
        if let primary = self.primary, primary != "no", primary == self.secondary {
            self.secondary = "no"
        }
    }

    public mutating func selectPrimary(_ id: String?) {
        primary = Self.normalized(id)
        if let primary, primary != "no", primary == secondary { secondary = "no" }
    }

    public mutating func selectSecondary(_ id: String?) {
        secondary = Self.normalized(id)
        if let secondary, secondary != "no", secondary == primary { primary = "no" }
    }

    public func resolved(available: [String], preferred: String? = nil, automaticAvailable: [String]? = nil) -> (primary: String?, secondary: String?) {
        func automatic(excluding excluded: String?) -> String? {
            let candidates = (automaticAvailable ?? available).filter { available.contains($0) }
            if let preferred, preferred != excluded, candidates.contains(preferred) { return preferred }
            return candidates.first { $0 != excluded }
        }
        func explicit(_ id: String?) -> String? {
            guard let id, id != "no", available.contains(id) else { return nil }
            return id
        }
        // An explicitly selected secondary track is reserved before automatic primary selection.
        let explicitSecondary = explicit(secondary)
        let primary = self.primary == nil ? automatic(excluding: explicitSecondary) : explicit(self.primary)
        let secondary = self.secondary == nil ? automatic(excluding: primary) : explicitSecondary
        return (primary, secondary == primary ? nil : secondary)
    }

    private static func normalized(_ id: String?) -> String? {
        id == "auto" || id == "" ? nil : id
    }
}
