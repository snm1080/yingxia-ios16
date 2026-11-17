import Foundation
import CoreText
import CoreGraphics
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import TVCore

// Decoded once, independently of text tiles. Geometry is shared with Canvas and
// ASS; animation evaluates media age and never reads a wall clock.
enum NativeFancyDanmakuPainter {
    struct Effect: Hashable {
        let variant: String, label: String
        let border: Int, background: Int
        let icons: Bool
    }
    struct Motion: Decodable { let period: Double, phase: Double, opacity: Double, dx: Double, dy: Double }
    struct Shape: Decodable {
        let kind: String, x: Double, y: Double, ew: Double, eh: Double, fill: String
        let rw: Double?, rh: Double?, dx: Double?, dy: Double?, radius: Double?, stroke: String?, line: Double?, opacity: Double?
        let optional: Bool?, rotation: Double?, animation: Motion?
    }
    struct Spec: Decodable {
        let id: String, name: String, accent: String, background: String, foreground: String
        let inset: Double, right: Double, height: Double, textY: Double
        let textColors: [String]?, outline: String?, stroke: Double?, echo: Bool?
        let shapes: [Shape]
        var textCenterY: Double {
            // Panel effects center their text inside the full-width body.
            // Unframed effects retain the catalog's 1.2em text line.
            if let body = shapes.first(where: { $0.fill == "background" && $0.rw == 1 && $0.x == 0 && $0.y == 0 && $0.eh > 0 }) {
                return (body.dy ?? 0) + body.eh / 2
            }
            return textY + 0.6
        }
    }
    private struct Command: Decodable {
        let op: String, values: [Double]
        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            op = try container.decode(String.self)
            var result: [Double] = []
            while !container.isAtEnd { result.append(try container.decode(Double.self)) }
            values = result
        }
    }
    private struct Catalog: Decodable { let paths: [String: [Command]], effects: [Spec] }
    private static let catalog = try! JSONDecoder().decode(Catalog.self, from: Data(NativeFancyDanmakuCatalog.json.utf8))
    private final class TextTile {
        let image: CGImage
        let dimensions: CGSize
        let leading: CGFloat
        init(_ image: CGImage, dimensions: CGSize, leading: CGFloat) {
            self.image = image; self.dimensions = dimensions; self.leading = leading
        }
    }
    // MacCat separates static glyphs from animated decoration. Keep the same
    // outline, gradient and echo pixels while only repainting the shapes.
    nonisolated(unsafe) private static let textTiles: NSCache<NSString, TextTile> = {
        let cache = NSCache<NSString, TextTile>()
        cache.totalCostLimit = 24 * 1024 * 1024; cache.countLimit = 256
        return cache
    }()
    private static let preferenceLock = NSLock()
    nonisolated(unsafe) private static var preferences = FancyDanmakuPreferences.load()
    nonisolated(unsafe) private static var selector = preferences.selector
    static func refreshPreferences(_ next: FancyDanmakuPreferences = .load()) {
        preferenceLock.withLock { preferences = next; selector = next.selector }
    }
    static var specs: [Spec] { catalog.effects }
    static func spec(_ variant: String) -> Spec? { catalog.effects.first { $0.id == variant } }
    static func labelFont(_ size: CGFloat) -> CTFont { CTFontCreateWithName("Helvetica-Bold" as CFString, size * 0.62, nil) }
    static func labelLine(_ label: String, size: CGFloat, color: CGColor? = nil) -> CTLine {
        var values: [NSAttributedString.Key: Any] = [.init(kCTFontAttributeName as String): labelFont(size)]
        if let color { values[.init(kCTForegroundColorAttributeName as String)] = color }
        return CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: values))
    }
    static func inset(_ effect: Effect, fontSize: CGFloat) -> CGFloat {
        guard effect.variant == "badge" else { return fontSize * CGFloat(spec(effect.variant)?.inset ?? 0.55) }
        guard !effect.label.isEmpty else { return fontSize * (effect.icons ? 1.65 : 0.4) }
        let width = CGFloat(CTLineGetTypographicBounds(labelLine(effect.label, size: fontSize), nil, nil, nil))
        // The capsule has .2em padding on either side and a .15em gap before the comment.
        return fontSize * (effect.icons ? 1.35 : 0.2) + width + fontSize * 0.55
    }
    static func color(_ hex: String) -> CGColor {
        let rgb = Int(hex.dropFirst(), radix: 16) ?? 0xffffff
        return color(rgb)
    }
    static func color(_ rgb: Int) -> CGColor {
        CGColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
    static func paint(_ effect: Effect, context: CGContext, size: CGSize, fontSize fs: CGFloat, inset: CGFloat, age: Double, opacity multiplier: Double = 1) {
        guard let spec = spec(effect.variant) else { return }
        func resolve(_ value: String) -> CGColor {
            (value == "accent" ? color(effect.border) : value == "background" ? color(effect.background) : color(value))
        }
        for shape in spec.shapes {
            if shape.optional == true && !effect.icons { continue }
            var t = 0.0, opacity = shape.opacity ?? 1
            if let motion = shape.animation {
                let phase = (max(0, age) / motion.period + motion.phase).truncatingRemainder(dividingBy: 1)
                t = 1 - abs(phase * 2 - 1)
                opacity *= motion.opacity + (1 - motion.opacity) * t
            }
            let x = CGFloat(shape.x) * size.width + CGFloat((shape.dx ?? 0) + (shape.animation?.dx ?? 0) * t) * fs
            let y = CGFloat(shape.y) * size.height + CGFloat((shape.dy ?? 0) + (shape.animation?.dy ?? 0) * t) * fs
            let w = CGFloat(shape.rw ?? 0) * size.width + CGFloat(shape.ew) * fs
            let h = CGFloat(shape.rh ?? 0) * size.height + CGFloat(shape.eh) * fs
            guard w > 0, h > 0 else { continue }
            context.saveGState()
            context.setAlpha(CGFloat(opacity * multiplier))
            context.translateBy(x: x + w / 2, y: y + h / 2)
            context.rotate(by: CGFloat(shape.rotation ?? 0) * .pi / 180)
            context.translateBy(x: -w / 2, y: -h / 2)
            let rect = CGRect(x: 0, y: 0, width: w, height: h), drawing: CGPath
            if shape.kind == "circle" { drawing = CGPath(ellipseIn: rect, transform: nil) }
            else if shape.kind == "round" {
                let r = min(CGFloat(shape.radius ?? 0.1) * fs, min(w, h) / 2)
                drawing = CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
            } else if shape.kind == "rect" { drawing = CGPath(rect: rect, transform: nil) }
            else {
                let p = CGMutablePath()
                for cmd in catalog.paths[shape.kind] ?? [] {
                    let v = cmd.values
                    switch cmd.op {
                    case "M": p.move(to: CGPoint(x: v[0] * w, y: v[1] * h))
                    case "L": p.addLine(to: CGPoint(x: v[0] * w, y: v[1] * h))
                    case "C": p.addCurve(to: CGPoint(x: v[4] * w, y: v[5] * h), control1: CGPoint(x: v[0] * w, y: v[1] * h), control2: CGPoint(x: v[2] * w, y: v[3] * h))
                    default: p.closeSubpath()
                    }
                }
                drawing = p
            }
            context.addPath(drawing); context.setFillColor(resolve(shape.fill)); context.fillPath()
            if let stroke = shape.stroke { context.addPath(drawing); context.setStrokeColor(resolve(stroke)); context.setLineWidth(CGFloat(shape.line ?? 0.04) * fs); context.strokePath() }
            context.restoreGState()
        }
        if effect.variant == "badge", !effect.label.isEmpty {
            context.setAlpha(CGFloat(multiplier))
            let left = fs * (effect.icons ? 1.35 : 0.2)
            let labelWidth = max(0, inset - left - fs * 0.15)
            let label = labelLine(effect.label, size: fs, color: color(effect.background))
            var ascent: CGFloat = 0, descent: CGFloat = 0
            let labelWidthActual = CGFloat(CTLineGetTypographicBounds(label, &ascent, &descent, nil))
            context.setFillColor(resolve("accent"))
            context.addPath(CGPath(roundedRect: CGRect(x: left, y: fs * 0.5, width: labelWidth, height: fs * 0.63), cornerWidth: fs * 0.3, cornerHeight: fs * 0.3, transform: nil)); context.fillPath()
            context.saveGState()
            context.translateBy(x: left + (labelWidth - labelWidthActual) / 2, y: fs * 0.5 + (fs * 0.63 + ascent - descent) / 2)
            context.scaleBy(x: 1, y: -1)
            context.textPosition = .zero
            CTLineDraw(label, context)
            context.restoreGState()
        }
    }
    static func effect(_ comment: Danmaku) -> Effect? {
        let (icons, choice) = preferenceLock.withLock { (preferences.icons, selector.choice(text: comment.text, time: comment.time)) }
        if let value = comment.effect, ["badge", "highlight", "celebrate"].contains(value.kind) {
            let fallback = value.kind == "badge" ? "badge" : value.kind == "celebrate" ? "spark" : "heart"
            let variant = spec(value.variant) == nil ? fallback : value.variant
            return Effect(variant: variant, label: value.label, border: Int(value.border), background: Int(value.background), icons: value.icons && icons)
        }
        guard comment.position != .positioned,
              let choice, let spec = spec(choice.variant) else { return nil }
        return Effect(variant: choice.variant, label: choice.label, border: Int(spec.accent.dropFirst(), radix: 16) ?? 0xffffff,
                      background: Int(spec.background.dropFirst(), radix: 16) ?? 0x202020, icons: icons)
    }
    static func width(_ comment: Danmaku, size: CGFloat) -> Double {
        width(comment, effect: effect(comment), size: size)
    }
    static func width(_ comment: Danmaku, effect: Effect?, size: CGFloat, preferences: DanmakuText.Preferences = .init()) -> Double {
        guard let effect else { return DanmakuText.width(comment.text, size: size, preferences: preferences) }
        return DanmakuText.width(comment.text, size: size, includeOverhang: true, preferences: preferences) + Double(inset(effect, fontSize: size)) + Double(size * CGFloat(spec(effect.variant)?.right ?? 0.55))
    }
    static func isAnimated(_ effect: Effect) -> Bool {
        spec(effect.variant)?.shapes.contains { $0.animation != nil && ($0.optional != true || effect.icons) } == true
    }
    static func image(_ comment: Danmaku, size: CGFloat, scale: CGFloat, age: Double = 0) -> CGImage? {
        guard let effect = effect(comment) else { return nil }
        return image(comment, effect: effect, size: size, scale: scale, age: age)
    }
    static func image(_ comment: Danmaku, effect: Effect, size: CGFloat, scale: CGFloat, age: Double = 0, preferences: DanmakuText.Preferences = .init()) -> CGImage? {
        return image(comment.text, effect: effect, size: size, scale: scale, age: age, preferences: preferences)
    }
    static func preview(variant: String, icons: Bool, label: String, size: CGFloat, scale: CGFloat, age: Double) -> CGImage? {
        guard let spec = spec(variant) else { return nil }
        let effect = Effect(variant: variant, label: variant == "badge" ? label : "", border: Int(spec.accent.dropFirst(), radix: 16) ?? 0xffffff,
                            background: Int(spec.background.dropFirst(), radix: 16) ?? 0x202020, icons: icons)
        return image("弹幕效果", effect: effect, size: size, scale: scale, age: age)
    }
    private static func image(_ text: String, effect: Effect, size: CGFloat, scale: CGFloat, age: Double, preferences: DanmakuText.Preferences = .init()) -> CGImage? {
        guard let tile = textTile(text, effect: effect, size: size, scale: scale, preferences: preferences) else { return nil }
        let dimensions = tile.dimensions
        let bitmapSize = CGSize(width: CGFloat(tile.image.width) / scale, height: CGFloat(tile.image.height) / scale)
        guard let canvas = CGContext(data: nil, width: tile.image.width, height: tile.image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        canvas.scaleBy(x: scale, y: scale)
        canvas.translateBy(x: 0, y: bitmapSize.height); canvas.scaleBy(x: 1, y: -1)
        paint(effect, context: canvas, size: dimensions, fontSize: size, inset: tile.leading, age: age)
        canvas.translateBy(x: 0, y: bitmapSize.height); canvas.scaleBy(x: 1, y: -1)
        // A ceil-rounded texture must be copied at its real pixel extent;
        // squeezing it into the fractional design size shifts its lower rows.
        canvas.draw(tile.image, in: CGRect(origin: .zero, size: bitmapSize))
        return canvas.makeImage()
    }
    private static func textTile(_ text: String, effect: Effect, size: CGFloat, scale: CGFloat, preferences: DanmakuText.Preferences) -> TextTile? {
        let key = "\(effect):\(size):\(scale):\(preferences.family):\(preferences.weight):\(text)" as NSString
        if let cached = textTiles.object(forKey: key) { return cached }
        guard let spec = spec(effect.variant) else { return nil }
        let leading = inset(effect, fontSize: size)
        let dimensions = CGSize(width: DanmakuText.width(text, size: size, includeOverhang: true, preferences: preferences) + Double(leading + size * spec.right), height: Double(size) * spec.height)
        guard dimensions.width > 0, dimensions.width * scale < 8192, dimensions.height * scale < 2048,
              dimensions.width * dimensions.height * scale * scale < 2 * 1024 * 1024,
              let canvas = CGContext(data: nil, width: Int(ceil(dimensions.width * scale)), height: Int(ceil(dimensions.height * scale)), bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        canvas.scaleBy(x: scale, y: scale)
        canvas.translateBy(x: 0, y: CGFloat(canvas.height) / scale); canvas.scaleBy(x: 1, y: -1)
        let gradient = spec.textColors.flatMap { $0.count >= 2 ? [$0[0], $0[1]] : nil }
        let stroke = (spec.stroke ?? 0.025) * Double(size)
        func drawText(_ color: UInt32, x: CGFloat = 0, opacity: CGFloat = 1, useGradient: Bool = false) {
            guard let glyph = DanmakuText.image(text, color: color, size: size, scale: scale,
                gradient: useGradient ? gradient : nil, outlineColor: spec.outline, outlineWidth: stroke, usePreferences: false,
                verticalAlignment: .inkCenter, preferences: preferences) else { return }
            let glyphSize = CGSize(width: CGFloat(glyph.width) / scale, height: CGFloat(glyph.height) / scale)
            canvas.saveGState(); canvas.setAlpha(opacity)
            canvas.translateBy(x: leading + x, y: size * spec.textCenterY + glyphSize.height / 2); canvas.scaleBy(x: 1, y: -1)
            canvas.draw(glyph, in: CGRect(origin: .zero, size: glyphSize)); canvas.restoreGState()
        }
        if spec.echo == true {
            drawText(0xff68af, x: -size * 0.045, opacity: 0.55)
            drawText(0x55f7ee, x: size * 0.045, opacity: 0.55)
        }
        drawText(UInt32(spec.foreground.dropFirst(), radix: 16) ?? 0xffffff, useGradient: true)
        guard let bitmap = canvas.makeImage() else { return nil }
        let tile = TextTile(bitmap, dimensions: dimensions, leading: leading)
        textTiles.setObject(tile, forKey: key, cost: bitmap.bytesPerRow * bitmap.height)
        return tile
    }


}
