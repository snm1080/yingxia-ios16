import Foundation

/// Bounded ASS cue motion/fade evaluated on the player's media clock. Coordinates use the script's PlayRes.
public struct ASSAnimation: Sendable, Equatable {
    public struct Point: Sendable, Equatable {
        public let x, y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
    }
    private var origin: Point?
    private var target: Point?
    private var from = 0.0
    private var until: Double?
    private var fadeIn = 0.0, fadeOut = 0.0
    public init() {}
    /// Cue presence is selected by the timeline. Only rendered motion/fades
    /// need another UI clock publication while the same cue remains active.
    public var requiresContinuousTime: Bool { target != nil || fadeIn > 0 || fadeOut > 0 }
    /// ASS v4+ writes true as -1; tolerate files using 1 and reject malformed fields.
    static func styleFlag(_ value: String?) -> Bool { value.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }.map { $0 != 0 } ?? false }
    private static let blocks = try! NSRegularExpression(pattern: #"\{([^}]*)\}"#)
    private static let tags = try! NSRegularExpression(pattern: #"\\(pos|move|fad)\(([^)]*)\)"#)
    public static func parse(_ text: String) -> Self {
        var value = Self()
        let source = String(text.prefix(65536)) as NSString
        for block in blocks.matches(in: source as String, range: NSRange(location: 0, length: source.length)).prefix(128) {
            let content = source.substring(with: block.range(at: 1)) as NSString
            for tag in tags.matches(in: content as String, range: NSRange(location: 0, length: content.length)).prefix(128) {
                let name = content.substring(with: tag.range(at: 1))
                let pieces = content.substring(with: tag.range(at: 2)).components(separatedBy: ",")
                let numbers = pieces.compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                guard numbers.count == pieces.count, numbers.allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }) else { continue }
                switch name {
                case "pos" where numbers.count == 2:
                    value.origin = Point(x: numbers[0], y: numbers[1]); value.target = nil
                case "move" where numbers.count == 4 || numbers.count == 6:
                    guard numbers.count == 4 || (numbers[4] >= 0 && numbers[5] >= numbers[4]) else { continue }
                    value.origin = Point(x: numbers[0], y: numbers[1]); value.target = Point(x: numbers[2], y: numbers[3])
                    value.from = numbers.count == 6 ? numbers[4] / 1000 : 0
                    value.until = numbers.count == 6 ? numbers[5] / 1000 : nil
                case "fad" where numbers.count == 2 && numbers[0] >= 0 && numbers[1] >= 0:
                    value.fadeIn = numbers[0] / 1000; value.fadeOut = numbers[1] / 1000
                default: continue
                }
            }
        }
        return value
    }
    public func position(at age: Double, duration: Double) -> Point? {
        guard let origin else { return nil }
        guard let target else { return origin }
        // Decoder cues can have an unknown end until their replacement arrives. An untimed move
        // cannot infer its speed yet; explicit move timestamps remain independent of that end.
        guard until != nil || duration.isFinite else { return origin }
        let end = until ?? max(0, duration.isFinite ? duration : 0)
        let fraction = end <= from ? (age >= end ? 1.0 : 0) : min(1, max(0, (age - from) / (end - from)))
        return Point(x: origin.x + (target.x - origin.x) * fraction, y: origin.y + (target.y - origin.y) * fraction)
    }
    public func opacity(at age: Double, duration: Double) -> Double {
        guard age.isFinite, !duration.isNaN, duration >= 0, age >= 0, age <= duration else { return 0 }
        let entering = fadeIn > 0 ? min(1, age / fadeIn) : 1
        let leaving = fadeOut > 0 && duration.isFinite ? min(1, max(0, (duration - age) / fadeOut)) : 1
        return min(entering, leaving)
    }
}

/// Cue-specific positioning intent. A style's alignment alone can be inherited or malformed;
/// explicit override tags and named sign/effect styles identify coordinates worth preserving.
public enum ASSPositionIntent {
    private static let blocks = try! NSRegularExpression(pattern: #"\{([^}]*)\}"#)
    private static let positions = try! NSRegularExpression(pattern: #"\\(?:pos|move)\s*\("#)
    private static let alignment = try! NSRegularExpression(pattern: #"\\an([1-9])(?:\\|$)"#)
    private static let drawing = try! NSRegularExpression(pattern: #"\\p[1-9]"#)
    private static let named = try! NSRegularExpression(pattern: #"(?:^|[^a-z])(?:signs?|titles?|credits?|logo|staff|typeset|karaoke|lyrics?|opening|ending)(?:$|[^a-z])"#)

    public static func isAuthored(text: String, style: String?, effect: String?, specialAlignment: Bool) -> Bool {
        let value = String(text.prefix(65536)) as NSString
        for block in blocks.matches(in: value as String, range: NSRange(location: 0, length: value.length)).prefix(128) {
            let tags = value.substring(with: block.range(at: 1)) as NSString
            let range = NSRange(location: 0, length: tags.length)
            if positions.firstMatch(in: tags as String, range: range) != nil || drawing.firstMatch(in: tags as String, range: range) != nil { return true }
            // Explicit bottom-center alignment is ordinary dialogue; any other override carries intent.
            if alignment.matches(in: tags as String, range: range).contains(where: { tags.substring(with: $0.range(at: 1)) != "2" }) { return true }
        }
        let eventEffect = effect?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if eventEffect.hasPrefix("scroll") || eventEffect.hasPrefix("banner") { return true }
        guard specialAlignment, let style else { return false }
        let name = style.lowercased() as NSString
        return named.firstMatch(in: name as String, range: NSRange(location: 0, length: name.length)) != nil ||
            ["标牌", "标题", "片头", "片尾", "注释", "歌词", "招牌", "特效"].contains { style.contains($0) }
    }
}
