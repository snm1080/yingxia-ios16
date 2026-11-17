import Foundation

public struct DanmakuBASState: Sendable, Hashable {
    public let x, y, fontSize, rotateZ, rotateY, scaleX, scaleY, anchorX, anchorY, opacity: Double
    public let color: UInt32
    public init(_ value: JSONValue) {
        let fields = value.object ?? [:]
        func number(_ key: String, _ fallback: Double) -> Double { fields[key]?.string.flatMap(Double.init) ?? fallback }
        x = number("x", 0); y = number("y", 0); fontSize = number("fontSize", 25)
        rotateZ = number("rotateZ", 0); rotateY = number("rotateY", 0)
        scaleX = number("scaleX", 1); scaleY = number("scaleY", 1); anchorX = number("anchorX", 0); anchorY = number("anchorY", 0)
        opacity = number("opacity", 1); color = UInt32(clamping: fields["color"]?.int ?? 0xffffff)
    }
    private init(_ from: Self, _ to: Self, _ progress: Double) {
        func n(_ a: Double, _ b: Double) -> Double { a + (b - a) * progress }
        x = n(from.x, to.x); y = n(from.y, to.y); fontSize = n(from.fontSize, to.fontSize)
        rotateZ = n(from.rotateZ, to.rotateZ); rotateY = n(from.rotateY, to.rotateY)
        scaleX = n(from.scaleX, to.scaleX); scaleY = n(from.scaleY, to.scaleY)
        anchorX = n(from.anchorX, to.anchorX); anchorY = n(from.anchorY, to.anchorY); opacity = n(from.opacity, to.opacity)
        func byte(_ shift: UInt32) -> UInt32 { UInt32(max(0, min(255, n(Double(from.color >> shift & 255), Double(to.color >> shift & 255))))) }
        color = byte(16) << 16 | byte(8) << 8 | byte(0)
    }
    public func interpolated(to: Self, progress: Double) -> Self { Self(self, to, min(1, max(0, progress))) }
}
public struct DanmakuBASItem: Sendable, Hashable {
    public struct Frame: Sendable, Hashable {
        public let delay, duration: Double
        public let from, to: DanmakuBASState
    }
    public let text, drawing, font: String
    public let lifetime: Double
    public let outline: Bool
    public let base: DanmakuBASState
    public let frames: [Frame]
    public init(_ value: JSONValue) {
        let row = value.object ?? [:]
        text = row["text"]?.string ?? ""; drawing = row["drawing"]?.string ?? ""; font = row["font"]?.string ?? ""
        lifetime = row["lifetime"]?.string.flatMap(Double.init) ?? 4; outline = row["outline"] != .bool(false)
        base = DanmakuBASState(value)
        frames = (row["frames"]?.array ?? []).prefix(512).map { value in
            let fields = value.object ?? [:]
            return Frame(delay: fields["delay"]?.string.flatMap(Double.init) ?? 0, duration: max(0.001, fields["duration"]?.string.flatMap(Double.init) ?? 1), from: DanmakuBASState(fields["from"] ?? .null), to: DanmakuBASState(fields["to"] ?? .null))
        }
    }
    public func state(at age: Double) -> DanmakuBASState {
        var result = base
        for frame in frames {
            guard age >= frame.delay else { continue }
            result = frame.from.interpolated(to: frame.to, progress: (age - frame.delay) / frame.duration)
        }
        return result
    }
}
