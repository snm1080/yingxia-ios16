import Foundation

public struct DanmakuEffect: Sendable, Hashable {
    public struct Point: Sendable, Hashable { public let x, y: Double }
    public let path: [Point]
    private let pathEnds: [Double]
    public let items: [DanmakuBASItem]
    public let font: String
    public let outline: Bool
    public let rotateY: Double
    public let variant: String
    public let icons: Bool
    public let kind: String
    public let x, y, toX, toY, lifetime, moveDuration, moveDelay, opacity, endOpacity, rotateZ, fontSize: Double
    public let label, icon: String
    public let foreground, background, border: UInt32
    public init(_ value: JSONValue) {
        let fields = value.object ?? [:]
        func number(_ key: String, _ fallback: Double) -> Double { fields[key]?.string.flatMap(Double.init) ?? fallback }
        path = (fields["path"]?.array ?? []).prefix(512).map { Point(x: $0.object?["x"]?.string.flatMap(Double.init) ?? 0, y: $0.object?["y"]?.string.flatMap(Double.init) ?? 0) }
        var distance = 0.0
        pathEnds = zip(path, path.dropFirst()).map {
            distance += hypot($1.x - $0.x, $1.y - $0.y)
            return distance
        }
        items = (fields["items"]?.array ?? []).prefix(64).map(DanmakuBASItem.init)
        font = fields["font"]?.string ?? ""; outline = fields["outline"] != .bool(false); rotateY = number("rotateY", 0)
        variant = fields["variant"]?.string ?? ""; icons = fields["icons"] != .bool(false)
        kind = fields["kind"]?.string ?? ""; label = fields["label"]?.string ?? ""; icon = fields["icon"]?.string ?? ""
        x = number("x", 0); y = number("y", 0); toX = number("toX", x); toY = number("toY", y)
        lifetime = number("lifetime", 4); moveDuration = number("moveDuration", lifetime); moveDelay = number("moveDelay", 0)
        opacity = number("opacity", 1); endOpacity = number("endOpacity", 1); rotateZ = number("rotateZ", 0); fontSize = number("fontSize", 25)
        foreground = UInt32(clamping: fields["foreground"]?.int ?? 0xffffff)
        background = UInt32(clamping: fields["background"]?.int ?? 0x301527)
        border = UInt32(clamping: fields["border"]?.int ?? 0xe962ab)
    }
    public func coordinate(progress: Double) -> Point {
        let progress = min(1, max(0, progress))
        guard path.count > 1 else { return Point(x: x + (toX - x) * progress, y: y + (toY - y) * progress) }
        let distance = (pathEnds.last ?? 0) * progress
        var low = 0, high = pathEnds.count - 1
        while low < high {
            let middle = (low + high) / 2
            if pathEnds[middle] < distance { low = middle + 1 } else { high = middle }
        }
        let start = low > 0 ? pathEnds[low - 1] : 0
        let length = pathEnds[low] - start
        let fraction = length > 0 ? (distance - start) / length : 0
        return Point(x: path[low].x + (path[low + 1].x - path[low].x) * fraction,
                     y: path[low].y + (path[low + 1].y - path[low].y) * fraction)
    }
}
public enum NativeDanmakuDecoder {
    public static func comment(_ value: JSONValue, time fallbackTime: Double = 0) -> Danmaku? {
        guard let row = value.object, let text = row["text"]?.string, !text.isEmpty else { return nil }
        let time = row["time"]?.string.flatMap(Double.init) ?? fallbackTime
        guard time.isFinite, time >= 0 else { return nil }
        let mode = row["mode"]?.int ?? 1
        guard mode != 8 else { return nil }
        let effect = row["effect"].map(DanmakuEffect.init)
        let position: Danmaku.Position = effect?.kind == "positioned" || effect?.kind == "bas" ? .positioned : mode == 6 ? .reverse : mode == 5 ? .top : mode == 4 ? .bottom : .scroll
        return Danmaku(time: time, position: position, color: UInt32(clamping: row["color"]?.int ?? 0xffffff), text: String(text.prefix(4096)), effect: effect)
    }
}
