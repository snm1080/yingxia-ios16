#if os(iOS)
import UIKit
import KSPlayer
import TVCore

/// Draws only the app's selected subtitles. Video pixels and the PiP display layer
/// remain owned by the playback engine; this transparent image uses top-left pixels.
@MainActor final class PictureInPictureSubtitleRenderer {
    private struct Glyph {
        let source: NSAttributedString
        let width: CGFloat
        let scale: CGFloat
        let alignment: NSTextAlignment
        let plainStyle: SubtitleStyle?
        let image: CGImage
        let size: CGSize
        let inset: CGFloat
    }
    private struct Drawing {
        let image: CGImage
        let rectangle: CGRect
        let opacity: CGFloat
        func matches(_ other: Self) -> Bool {
            image === other.image && rectangle == other.rectangle && opacity == other.opacity
        }
    }
    private struct Dialogue {
        var drawings: [Drawing] = []
        var size = CGSize.zero
        mutating func append(_ glyph: Glyph, opacity: CGFloat, gap: CGFloat) {
            if size.height > 0 { size.height += gap }
            drawings.append(Drawing(image: glyph.image,
                rectangle: CGRect(x: -glyph.inset, y: size.height - glyph.inset,
                    width: CGFloat(glyph.image.width), height: CGFloat(glyph.image.height)), opacity: opacity))
            size.width = max(size.width, glyph.size.width)
            size.height += glyph.size.height
        }
    }
    private var glyphs: [Glyph] = []
    private var lastSize = CGSize.zero
    private var lastDrawings: [Drawing] = []
    private var lastImage: CGImage?

    func reset() {
        glyphs.removeAll(); lastDrawings.removeAll(); lastImage = nil; lastSize = .zero
    }

    func image(primary: PlayerSubtitlePresentation, secondary: PlayerSubtitlePresentation,
               style: SubtitleStyle, size: CGSize) -> CGImage? {
        guard size.width.isFinite, size.height.isFinite, size.width >= 1, size.height >= 1 else {
            reset(); return nil
        }
        let size = CGSize(width: size.width.rounded(.down), height: size.height.rounded(.down))
        let picture = CGRect(origin: .zero, size: size), style = style.clamped
        guard style.opacity > 0 else { lastImage = nil; lastDrawings.removeAll(); return nil }
        let main = active(primary), second = active(secondary)
        let mainParts = main.dialogueParts(style: style), secondParts = second.dialogueParts(style: style)
        let mainBitmaps = bottomBitmaps(main.bitmaps, picture: picture)
        let secondBitmaps = bottomBitmaps(second.bitmaps, picture: picture)
        let paired = (!main.plainLines(style: style).isEmpty || !mainParts.isEmpty || !mainBitmaps.isEmpty) &&
            (!second.plainLines(style: style).isEmpty || !secondParts.isEmpty || !secondBitmaps.isEmpty)
        let mainDialogue = dialogue(main, parts: mainParts, bitmaps: paired ? mainBitmaps : [],
            picture: picture, style: style, scale: 1)
        let secondDialogue = dialogue(second, parts: secondParts, bitmaps: paired ? secondBitmaps : [],
            picture: picture, style: style, scale: SubtitlePairGeometry.secondaryScale)
        let letters = max(4, picture.height * style.size / 100)
        let pair = SubtitlePairGeometry.rectangles(primarySize: mainDialogue.size, secondarySize: secondDialogue.size,
            normalLineHeight: PlayerSubtitleTextMetrics.normalLineHeight(parts: mainParts,
                picture: picture, style: style, letters: letters),
            style: style, picture: picture, viewportHeight: size.height, bottomInset: 0,
            padding: max(6, style.outlineSize + style.shadowOffset))
        var drawings = placed(mainDialogue, in: pair.primary) + placed(secondDialogue, in: pair.secondary)
        drawings += authored(main, picture: picture, style: style, secondary: false)
        drawings += authored(second, picture: picture, style: style, secondary: true)
        for bitmap in main.bitmaps + second.bitmaps {
            guard let rectangle = bitmapRectangle(bitmap, picture: picture),
                  !paired || !SubtitleBitmapGeometry.isBottomDialogue(rectangle, in: picture) else { continue }
            drawings.append(Drawing(image: bitmapImage(bitmap.image), rectangle: rectangle, opacity: style.opacity))
        }
        drawings = drawings.filter { $0.opacity > 0 && !$0.rectangle.isEmpty && $0.rectangle.intersects(picture) }
        guard !drawings.isEmpty else { lastImage = nil; lastDrawings.removeAll(); return nil }
        if size == lastSize, drawings.count == lastDrawings.count,
           zip(drawings, lastDrawings).allSatisfy({ $0.matches($1) }) { return lastImage }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        format.opaque = false; format.preferredRange = .standard
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            for drawing in drawings {
                UIImage(cgImage: drawing.image).draw(in: drawing.rectangle, blendMode: .normal, alpha: drawing.opacity)
            }
        }.cgImage
        lastSize = size; lastDrawings = drawings; lastImage = rendered
        return rendered
    }

    /// The engine normally supplies active cues, but delayed selections cannot leave
    /// an expired ASS cue burned into a cached PiP frame after a seek or replacement.
    private func active(_ value: PlayerSubtitlePresentation) -> PlayerSubtitlePresentation {
        var result = value
        result.styledParts = value.styledParts.filter {
            value.sourceTime >= $0.start && value.sourceTime < $0.end &&
                !($0.text?.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
        if !value.styledParts.isEmpty, result.styledParts.isEmpty { result.lines = [] }
        return result
    }

    private func dialogue(_ value: PlayerSubtitlePresentation, parts: [SubtitlePart],
                          bitmaps: [KSPlaybackSubtitleBitmap], picture: CGRect,
                          style: SubtitleStyle, scale: CGFloat) -> Dialogue {
        var result = Dialogue()
        let width = picture.width * style.width
        let letters = max(4, picture.height * style.size / 100) * scale
        for line in value.plainLines(style: style) where !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let rgb = style.foregroundRGB
            let source = NSAttributedString(string: line, attributes: [
                .font: PlayerSubtitleTextMetrics.font(style: style, letters: letters),
                .foregroundColor: UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)])
            let glyph = glyph(source, width: width, scale: 1, alignment: .center, plainStyle: style)
            result.append(glyph, opacity: style.opacity, gap: letters * 0.15)
        }
        for part in parts {
            guard let text = part.text else { continue }
            let geometry = NativeStyledSubtitleGeometry(part: part, picture: picture, time: value.sourceTime)
            let glyph = glyph(text, width: width, scale: geometry.scale * scale, alignment: .center)
            result.append(glyph, opacity: style.opacity * part.animation.opacity(at: value.sourceTime - part.start,
                duration: max(0, part.end - part.start)), gap: 2)
        }
        for bitmap in bitmaps {
            guard let rectangle = bitmapRectangle(bitmap, picture: picture) else { continue }
            if result.size.height > 0 { result.size.height += 2 }
            let width = rectangle.width * scale, height = rectangle.height * scale
            result.drawings.append(Drawing(image: bitmapImage(bitmap.image),
                rectangle: CGRect(x: 0, y: result.size.height, width: width, height: height), opacity: style.opacity))
            result.size.width = max(result.size.width, width); result.size.height += height
        }
        return result
    }

    private func placed(_ dialogue: Dialogue, in rectangle: CGRect) -> [Drawing] {
        dialogue.drawings.map { drawing in
            // Glyph textures include their outline padding; centering their complete
            // width keeps each differently wrapped line on the same pair center.
            Drawing(image: drawing.image,
                rectangle: CGRect(x: rectangle.midX - drawing.rectangle.width / 2,
                    y: rectangle.minY + drawing.rectangle.minY,
                    width: drawing.rectangle.width, height: drawing.rectangle.height), opacity: drawing.opacity)
        }
    }

    private func authored(_ value: PlayerSubtitlePresentation, picture: CGRect,
                          style: SubtitleStyle, secondary: Bool) -> [Drawing] {
        value.authoredParts(style: style).compactMap { part in
            guard let text = part.text else { return nil }
            let opacity = style.opacity * part.animation.opacity(at: value.sourceTime - part.start,
                duration: max(0, part.end - part.start))
            guard opacity > 0 else { return nil }
            let geometry = NativeStyledSubtitleGeometry(part: part, picture: picture, time: value.sourceTime,
                secondary: secondary)
            let glyph = glyph(text, width: geometry.width,
                scale: geometry.scale * (secondary ? SubtitlePairGeometry.secondaryScale : 1),
                alignment: geometry.textAlignment)
            let rectangle = geometry.rectangle(for: glyph.size).insetBy(dx: -glyph.inset, dy: -glyph.inset)
            return Drawing(image: glyph.image, rectangle: rectangle, opacity: opacity)
        }
    }

    private func glyph(_ source: NSAttributedString, width: CGFloat, scale: CGFloat,
                       alignment: NSTextAlignment, plainStyle: SubtitleStyle? = nil) -> Glyph {
        let width = max(1, width)
        if let cached = glyphs.last(where: { $0.width == width && $0.scale == scale && $0.alignment == alignment &&
            $0.plainStyle == plainStyle && $0.source.isEqual(to: source) }) { return cached }
        let text = NativeAttributedSubtitleLabel.scaledText(source, scale: scale)
        var inset: CGFloat = 2, letters: CGFloat = 0
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, _, _ in
            let fontSize = (attributes[.font] as? UIFont)?.pointSize ?? 17
            letters = max(letters, fontSize)
            let stroke = abs((attributes[.strokeWidth] as? NSNumber)?.doubleValue ?? 0) / 100 * fontSize
            var effect = stroke
            if let shadow = attributes[.shadow] as? NSShadow {
                effect += max(abs(shadow.shadowOffset.width), abs(shadow.shadowOffset.height)) + shadow.shadowBlurRadius * 2
            }
            inset = max(inset, effect + 2)
        }
        if let style = plainStyle { inset = max(inset, style.outlineSize + style.shadowOffset * 2 + 2) }
        let backdrop = plainStyle?.backdrop ?? SubtitleStyle.Backdrop.none
        let horizontal = backdrop == .none ? 0 : letters * 0.3
        let vertical = backdrop == .none ? 0 : letters * 0.06
        let label = UILabel(); label.numberOfLines = 0; label.backgroundColor = .clear
        label.textAlignment = alignment; label.attributedText = text
        let measured = label.sizeThatFits(CGSize(width: max(1, width - horizontal * 2), height: .greatestFiniteMagnitude))
        // A max-width UILabel preserves ASS alignment and the exact wrapping proposal
        // used by the inline VStack; effects extend outside the measured text box.
        let contentWidth = plainStyle == nil ? width : min(width, ceil(measured.width) + horizontal * 2)
        let size = CGSize(width: max(1, contentWidth), height: ceil(measured.height) + vertical * 2)
        let textRect = CGRect(x: inset + horizontal, y: inset + vertical,
            width: max(1, contentWidth - horizontal * 2), height: ceil(measured.height))
        label.frame = CGRect(origin: .zero, size: textRect.size)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        format.opaque = false; format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: CGSize(width: ceil(size.width + inset * 2),
            height: ceil(size.height + inset * 2)), format: format).image { renderer in
            let context = renderer.cgContext
            if let style = plainStyle {
                if style.backdrop.opacity > 0 {
                    UIColor.black.withAlphaComponent(style.backdrop.opacity).setFill()
                    UIBezierPath(roundedRect: CGRect(x: inset, y: inset, width: size.width, height: size.height),
                        cornerRadius: letters * 0.12).fill()
                }
                context.saveGState()
                if style.shadowOffset > 0 {
                    context.setShadow(offset: CGSize(width: style.shadowOffset, height: style.shadowOffset),
                        blur: style.shadowOffset * 0.35, color: UIColor.black.withAlphaComponent(0.85).cgColor)
                }
                if style.edge == .raised || style.edge == .depressed {
                    let step = max(1, letters * 0.04) * (style.edge == .depressed ? -1 : 1)
                    context.setShadow(offset: CGSize(width: step, height: step), blur: 0,
                        color: UIColor.black.withAlphaComponent(0.85).cgColor)
                }
                if style.outlineSize > 0 {
                    let outline = NSMutableAttributedString(attributedString: text)
                    let rgb = PlayerStyleColor.rgb(style.outlineColor)
                    outline.addAttribute(.foregroundColor,
                        value: UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1),
                        range: NSRange(location: 0, length: outline.length))
                    label.attributedText = outline
                    for direction in 0..<8 {
                        let angle = Double(direction) * .pi / 4
                        label.drawText(in: textRect.offsetBy(dx: cos(angle) * style.outlineSize,
                            dy: sin(angle) * style.outlineSize))
                    }
                    label.attributedText = text
                }
                label.drawText(in: textRect); context.restoreGState()
            } else { label.drawText(in: textRect) }
        }.cgImage!
        let value = Glyph(source: NSAttributedString(attributedString: source), width: width, scale: scale,
            alignment: alignment, plainStyle: plainStyle, image: image, size: size, inset: inset)
        glyphs.append(value)
        if glyphs.count > 32 { glyphs.removeFirst(glyphs.count - 32) }
        return value
    }

    private func bitmapRectangle(_ bitmap: KSPlaybackSubtitleBitmap, picture: CGRect) -> CGRect? {
        SubtitleBitmapGeometry.rectangle(origin: bitmap.origin, imageSize: bitmap.image.size,
            canvasSize: bitmap.canvasSize, picture: picture)
    }
    private func bottomBitmaps(_ values: [KSPlaybackSubtitleBitmap], picture: CGRect) -> [KSPlaybackSubtitleBitmap] {
        values.filter { bitmapRectangle($0, picture: picture).map {
            SubtitleBitmapGeometry.isBottomDialogue($0, in: picture)
        } ?? false }
    }
    private func bitmapImage(_ image: UIImage) -> CGImage {
        if image.imageOrientation == .up, let cgImage = image.cgImage { return cgImage }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }.cgImage!
    }
}

#endif
