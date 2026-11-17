import CoreGraphics
import Foundation
import TVCore

/// Render only the declarative nodes produced by the portable BAS parser. All animation uses media age.
enum NativeBASRenderer {
    /// Movement, rotation and opacity change geometry only. Reuse raster tiles until their visible text/color/size changes.
    final class Cache {
        private var images: [String: CGImage] = [:]
        private var pixels = 0
        private var paths: [String: CGPath] = [:]
        private var pathPoints = 0
        func removeAll() { images.removeAll(keepingCapacity: true); pixels = 0; paths.removeAll(keepingCapacity: true); pathPoints = 0 }
        func image(key: String, make: () -> CGImage?) -> CGImage? {
            if let image = images[key] { return image }
            guard let image = make() else { return nil }
            let cost = image.width * image.height
            if pixels + cost > 8_000_000 || images.count >= 256 { removeAll() }
            if cost <= 8_000_000 { images[key] = image; pixels += cost }
            return image
        }
        func path(_ drawing: String) -> CGPath? {
            if let cached = paths[drawing] { return cached }
            guard let parsed = NativeBASRenderer.path(drawing) else { return nil }
            if pathPoints + drawing.utf8.count > 1024 * 1024 || paths.count >= 256 {
                paths.removeAll(keepingCapacity: true); pathPoints = 0
            }
            paths[drawing] = parsed; pathPoints += drawing.utf8.count
            return parsed
        }
    }
    static func sprites(_ effect: DanmakuEffect, age: Double, size: CGSize, scale: CGFloat, textScale: Double, maxCount: Int, pixelBudget: Int, cache: Cache? = nil, preferences: DanmakuText.Preferences = .init(), identity: UInt64 = 0) -> [DanmakuEngine.Sprite] {
        var result: [DanmakuEngine.Sprite] = []
        var remainingPixels = pixelBudget
        for (index, item) in effect.items.enumerated() {
            if result.count >= maxCount || remainingPixels <= 0 { break }
            guard age >= 0, age <= item.lifetime else { continue }
            let state = item.state(at: age)
            let image: CGImage
            let sourceBounds: CGRect
            if !item.drawing.isEmpty {
                guard let path = cache?.path(item.drawing) ?? path(item.drawing) else { continue }
                let bounds = path.boundingBoxOfPath
                guard bounds.width > 0, bounds.height > 0, bounds.width < 16_384, bounds.height < 16_384 else { continue }
                let desired = min(4, max(0.1, scale * CGFloat(textScale)))
                let renderScale = min(desired, 4096 / max(bounds.width, bounds.height), sqrt(CGFloat(remainingPixels) / max(1, bounds.width * bounds.height)))
                let key = "vector:\(item.drawing):\(state.color):\(renderScale)"
                let make = { () -> CGImage? in
                    guard let context = CGContext(data: nil, width: max(1, Int(ceil(bounds.width * renderScale))), height: max(1, Int(ceil(bounds.height * renderScale))), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
                    context.scaleBy(x: renderScale, y: renderScale)
                    context.translateBy(x: -bounds.minX, y: -bounds.minY)
                    context.addPath(path); context.setFillColor(color(state.color)); context.fillPath()
                    return context.makeImage()
                }
                guard let bitmap = cache.map({ $0.image(key: key, make: make) }) ?? make() else { continue }
                image = bitmap; sourceBounds = bounds
            } else {
                let font = CGFloat(state.fontSize * textScale)
                guard let bitmap = cachedText(item.text, color: state.color, size: font, scale: scale, family: item.font, outlined: item.outline, cache: cache, preferences: preferences),
                      bitmap.width <= 4096, bitmap.height <= 4096, bitmap.width * bitmap.height <= remainingPixels else { continue }
                image = bitmap; sourceBounds = CGRect(x: 0, y: 0, width: Double(bitmap.width) / Double(scale), height: Double(bitmap.height) / Double(scale))
            }
            let projection = max(0.001, abs(cos(state.rotateY * .pi / 180)))
            let width = sourceBounds.width * CGFloat(state.scaleX * projection) * size.width / 1280
            let height = sourceBounds.height * CGFloat(state.scaleY) * size.height / 720
            let frame = CGRect(x: (CGFloat(state.x) + sourceBounds.minX) * size.width / 1280 - width * CGFloat(state.anchorX),
                y: (CGFloat(state.y) + sourceBounds.minY) * size.height / 720 - height * CGFloat(state.anchorY), width: width, height: height)
            guard image.width * image.height <= remainingPixels else { continue }
            remainingPixels -= image.width * image.height
            result.append(DanmakuEngine.Sprite(image: image, frame: frame, opacity: state.opacity, rotation: state.rotateZ, id: identity + UInt64(index) + 1))
        }
        return result
    }
    private static func cachedText(_ text: String, color: UInt32, size: CGFloat, scale: CGFloat, family: String, outlined: Bool, cache: Cache?, preferences: DanmakuText.Preferences) -> CGImage? {
        let key = "text:\(color):\(size):\(scale):\(family):\(outlined):\(text)"
        let make = { DanmakuText.image(text, color: color, size: size, scale: scale, family: family, outlined: outlined, preferences: preferences) }
        if let cache { return cache.image(key: key, make: make) }
        return make()
    }
    static func path(_ source: String) -> CGPath? {
        let tokens = source.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard tokens.count <= 4096 else { return nil }
        var index = 0
        let path = CGMutablePath()
        func number() -> Double? { guard index < tokens.count, let value = Double(tokens[index]), value.isFinite, abs(value) <= 16_384 else { return nil }; index += 1; return value }
        while index < tokens.count {
            let command = tokens[index]; index += 1
            switch command {
            case "m", "l":
                guard let x = number(), let y = number() else { return nil }
                if command == "m" { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
            case "b":
                guard let x1 = number(), let y1 = number(), let x2 = number(), let y2 = number(), let x = number(), let y = number() else { return nil }
                path.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: x1, y: y1), control2: CGPoint(x: x2, y: y2))
            case "c": path.closeSubpath()
            default: return nil
            }
        }
        return path
    }
    private static func color(_ rgb: UInt32) -> CGColor { CGColor(srgbRed: CGFloat(rgb >> 16 & 255) / 255, green: CGFloat(rgb >> 8 & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1) }
}
