import Foundation

/// The same 17 catalog effects and independent weights used by MacCat. Selection is stable for a
/// comment, so measuring its tile, seeking, and redrawing an animation always choose the same effect.
public struct FancyDanmakuPreferences: Equatable, Sendable {
    public static let ids = ["badge", "meteor", "pink", "neon", "heart", "star", "flower", "rainbow", "ice", "fire", "ribbon", "spark", "jelly", "particles", "electric", "glitch", "comic"]
    public static let defaultNames = "云朵\n主角\n追光者\n小确幸\n星河\n梦想家\n守护者"
    public var enabled = false
    public var ratio = 30.0
    public var icons = true
    public var kinds = Self.ids
    public var weights = Array(repeating: 100.0, count: 17)
    public var names = Self.defaultNames
    public init() {}
    public struct Choice: Equatable, Sendable {
        public let variant: String
        public let label: String
    }
    public var normalized: Self {
        var value = self
        value.ratio = ratio.isFinite ? min(100, max(0, ratio)) : 30
        value.kinds = Self.ids.filter { kinds.contains($0) }
        value.weights = Self.ids.indices.map { index in
            let weight = weights.indices.contains(index) ? weights[index] : 100
            return weight.isFinite ? min(100, max(0, weight)) : 100
        }
        var seen = Set<String>()
        value.names = names.prefix(2048).components(separatedBy: .newlines).compactMap { raw -> String? in
            let clean = String(raw.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 && !"{}\\".unicodeScalars.contains($0) })
                .trimmingCharacters(in: .whitespaces)
            let name = String(clean.prefix(16))
            return !name.isEmpty && seen.insert(name).inserted ? name : nil
        }.prefix(30).joined(separator: "\n")
        return value
    }
    public static func load(_ defaults: UserDefaults = .standard) -> Self {
        var value = Self()
        value.enabled = defaults.bool(forKey: "danmakuFancyEnabled")
        value.ratio = defaults.object(forKey: "danmakuFancyRatio") as? Double ?? 30
        value.icons = defaults.object(forKey: "danmakuFancyIcons") as? Bool ?? true
        if let kinds = defaults.string(forKey: "danmakuFancyKinds") { value.kinds = kinds.components(separatedBy: ",") }
        if let weights = defaults.string(forKey: "danmakuFancyWeights") { value.weights = weights.components(separatedBy: ",").map { Double($0) ?? 100 } }
        value.names = defaults.string(forKey: "danmakuFancyNames") ?? Self.defaultNames
        return value.normalized
    }
    public func save(_ defaults: UserDefaults = .standard) {
        let value = normalized
        defaults.set(value.enabled, forKey: "danmakuFancyEnabled")
        defaults.set(value.ratio, forKey: "danmakuFancyRatio")
        defaults.set(value.icons, forKey: "danmakuFancyIcons")
        defaults.set(value.kinds.joined(separator: ","), forKey: "danmakuFancyKinds")
        defaults.set(value.weights.map(String.init(describing:)).joined(separator: ","), forKey: "danmakuFancyWeights")
        defaults.set(value.names, forKey: "danmakuFancyNames")
    }
    public func choice(text: String, time: Double) -> Choice? {
        selector.choice(text: text, time: time)
    }
    /// Prepared once per settings change, outside the per-frame rasterization loop.
    public var selector: Selector { Selector(self) }
    public struct Selector: Sendable {
        private let enabled: Bool
        private let ratio: Double
        private let entries: [(variant: String, ceiling: Double)]
        private let names: [String]
        private let total: Double
        fileprivate init(_ preferences: FancyDanmakuPreferences) {
            let value = preferences.normalized
            enabled = value.enabled; ratio = value.ratio
            names = value.names.components(separatedBy: "\n").filter { !$0.isEmpty }
            var sum = 0.0
            entries = FancyDanmakuPreferences.ids.indices.compactMap { index in
                guard value.kinds.contains(FancyDanmakuPreferences.ids[index]), value.weights[index] > 0 else { return nil }
                sum += value.weights[index]
                return (FancyDanmakuPreferences.ids[index], sum)
            }
            total = sum
        }
        public func choice(text: String, time: Double) -> Choice? {
            guard enabled, ratio > 0, total > 0 else { return nil }
            var hash: UInt64 = 14695981039346656037
            for byte in "\(time.isFinite ? Int64((max(-1e12, min(1e12, time)) * 1000).rounded()) : 0):\(text)".utf8 {
                hash = (hash ^ UInt64(byte)) &* 1099511628211
            }
            guard Double(hash % 10000) < ratio * 100 else { return nil }
            let slot = Double((hash >> 16) % 1_000_000) / 1_000_000 * total
            guard let entry = entries.first(where: { slot < $0.ceiling }) else { return nil }
            let label = entry.variant == "badge" && !names.isEmpty ? names[Int((hash >> 32) % UInt64(names.count))] : ""
            return Choice(variant: entry.variant, label: label)
        }
    }
}

public enum PlayerStyleColor {
    public static func normalize(_ text: String, fallback: String = "#FFFFFF") -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count == 7, value.first == "#", UInt32(value.dropFirst(), radix: 16) != nil else { return fallback }
        return value.uppercased()
    }
    public static func rgb(_ text: String) -> (red: Double, green: Double, blue: Double) {
        let value = UInt32(normalize(text).dropFirst(), radix: 16) ?? 0xffffff
        return (Double(value >> 16 & 255) / 255, Double(value >> 8 & 255) / 255, Double(value & 255) / 255)
    }
    public static func randomColor(text: String) -> UInt32 {
        let hash = stableHash(text)
        // Pastel colors remain readable against moving video, and remain stable across redraws.
        return (128 + (hash & 127)) << 16 | (128 + (hash >> 8 & 127)) << 8 | (128 + (hash >> 16 & 127))
    }
    /// The FNV-1a hash every text-derived colour here shares, so a comment
    /// keeps its colour across redraws and across colour modes.
    public static func stableHash(_ text: String) -> UInt32 {
        var hash: UInt32 = 2166136261
        for byte in text.utf8 { hash = (hash ^ UInt32(byte)) &* 16777619 }
        return hash
    }
    /// WebHTV's automatic gradient, as its danmaku colour mode computes it:
    /// the text hash walks the golden angle (137.508°) to a hue, paired with
    /// the hue 117° further on, at fixed saturation 0.55 and value 1.0; a
    /// text whose hash is a multiple of 5 (about one in five) stays plain
    /// white instead. Returns the two "#RRGGBB" stops, nil for a white text.
    public static func autoGradientColors(text: String) -> [String]? {
        let hash = stableHash(text)
        guard hash % 5 != 0 else { return nil }
        let hue = (Double(hash) * 137.508).truncatingRemainder(dividingBy: 360)
        return [hexColor(hue: hue), hexColor(hue: hue + 117)]
    }
    private static func hexColor(hue: Double) -> String {
        let hue = hue.truncatingRemainder(dividingBy: 360)
        let chroma = 0.55 // value 1.0 × saturation 0.55
        let x = chroma * (1 - abs((hue / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = 1.0 - chroma
        let (r, g, b): (Double, Double, Double)
        switch hue {
        case ..<60: (r, g, b) = (chroma, x, 0)
        case ..<120: (r, g, b) = (x, chroma, 0)
        case ..<180: (r, g, b) = (0, chroma, x)
        case ..<240: (r, g, b) = (0, x, chroma)
        case ..<300: (r, g, b) = (x, 0, chroma)
        default: (r, g, b) = (chroma, 0, x)
        }
        return String(format: "#%02X%02X%02X", Int(((r + m) * 255).rounded()), Int(((g + m) * 255).rounded()), Int(((b + m) * 255).rounded()))
    }
}
