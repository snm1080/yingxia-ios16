#if os(iOS)
import SwiftUI
import UIKit
import AVFoundation
import KSPlayer
import TVCore

/// Native ASS keeps the parser's attributed text and alignment until the user opts into style overrides.
/// UILabel draws UIKit's attributed font, stroke, shadow and inline colors without flattening them to strings.
struct NativeStyledSubtitleOverlay: View {
    let parts: [SubtitlePart]
    let pictureSize: CGSize
    var fills = false
    /// The caller supplies the actual fitted/cropped/custom-ratio video canvas when available.
    var explicitPicture: CGRect?
    var secondary = false
    var time = 0.0
    @State private var style = SubtitleStyle.load()
    var body: some View {
        GeometryReader { proxy in
            let whole = CGRect(origin: .zero, size: proxy.size)
            let picture = Self.picture(explicit: explicitPicture, source: pictureSize, inside: whole, fills: fills)
            if !style.overrideAssStyle {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    if let text = part.text {
                        let geometry = NativeStyledSubtitleGeometry(part: part, picture: picture, time: time, secondary: secondary)
                        let age = time - part.start
                        let duration = max(0, part.end - part.start)
                        if let point = geometry.point {
                            NativeAttributedSubtitleLabel(text: text, alignment: geometry.textAlignment, scale: geometry.scale * (secondary ? SubtitlePairGeometry.secondaryScale : 1))
                                .frame(maxWidth: geometry.width)
                                .fixedSize(horizontal: false, vertical: true)
                                .alignmentGuide(.leading) { size in geometry.anchorX * size.width - point.x }
                                .alignmentGuide(.top) { size in geometry.anchorY * size.height - point.y }
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                .opacity(part.animation.opacity(at: age, duration: duration))
                        } else {
                            NativeAttributedSubtitleLabel(text: text, alignment: geometry.textAlignment, scale: geometry.scale * (secondary ? SubtitlePairGeometry.secondaryScale : 1))
                                .padding(.leading, geometry.leading).padding(.trailing, geometry.trailing)
                                .padding(.vertical, geometry.margin)
                                .frame(width: picture.width, height: picture.height, alignment: geometry.placement)
                                .position(x: picture.midX, y: picture.midY)
                                .opacity(part.animation.opacity(at: age, duration: duration))
                        }
                    }
                }
            }
        }
        .opacity(style.opacity).clipped().allowsHitTesting(false).accessibilityHidden(true)
        .onReceive(NotificationCenter.default.publisher(for: SubtitleStyle.changed)) { _ in style = SubtitleStyle.load() }
    }
    static func picture(explicit: CGRect?, source: CGSize, inside whole: CGRect, fills: Bool) -> CGRect {
        explicit ?? (!fills && source.width > 0 && source.height > 0 ? AVMakeRect(aspectRatio: source, insideRect: whole) : whole)
    }
}

/// The authored ASS renderer and AI's hidden native labels share this exact canvas/margin/anchor geometry.
struct NativeStyledSubtitleGeometry {
    let picture: CGRect
    let scale: CGFloat
    let leading, trailing, margin: CGFloat
    let anchorX, anchorY: CGFloat
    let placement: Alignment
    let textAlignment: NSTextAlignment
    let point: CGPoint?

    init(part: SubtitlePart, picture: CGRect, time: Double, secondary: Bool = false) {
        self.picture = picture
        let position = part.textPosition
        scale = picture.height / max(1, part.canvasSize.height > 0 ? part.canvasSize.height : 720)
        leading = min(picture.width * 0.4, (position?.leftMargin ?? 10) * scale)
        trailing = min(picture.width * 0.4, (position?.rightMargin ?? 10) * scale)
        margin = min(picture.height * 0.4, (position?.verticalMargin ?? 10) * scale)
        let horizontal = position?.horizontalAlign ?? .center
        let vertical: VerticalAlignment = position?.verticalAlign ?? .bottom
        placement = Alignment(horizontal: horizontal, vertical: vertical)
        textAlignment = horizontal == .leading ? .left : horizontal == .trailing ? .right : .center
        anchorX = horizontal == .leading ? 0 : horizontal == .trailing ? 1 : 0.5
        if let authoredPoint = part.animation.position(at: time - part.start, duration: max(0, part.end - part.start)) {
            let canvasWidth = part.canvasSize.width > 0 ? part.canvasSize.width : 1280
            let canvasHeight = part.canvasSize.height > 0 ? part.canvasSize.height : 720
            point = CGPoint(x: picture.minX + CGFloat(authoredPoint.x) * picture.width / canvasWidth,
                            y: picture.minY + CGFloat(authoredPoint.y) * picture.height / canvasHeight)
            // Positioned cues already use their authored anchor even for a selected secondary track.
            let authoredVertical = position?.verticalAlign ?? .bottom
            anchorY = authoredVertical == .top ? 0 : authoredVertical == .center ? 0.5 : 1
        } else {
            point = nil
            anchorY = vertical == .top ? 0 : vertical == .center ? 0.5 : 1
        }
    }

    /// ASS style/color alone does not imply a special authored location.
    static func isDialogue(_ part: SubtitlePart) -> Bool {
        !part.usesAuthoredPosition && part.animation.position(at: 0, duration: max(0, part.end - part.start)) == nil
    }

    var width: CGFloat { max(0, picture.width - leading - trailing) }
    var maximumTextHeight: CGFloat? { point == nil ? max(0, picture.height - 2 * margin) : nil }

    func rectangle(for measured: CGSize) -> CGRect {
        if let point {
            // The renderer anchors the max-width frame around the UILabel. Reserving that frame
            // preserves its existing left/right anchoring and contains every aligned glyph inside it.
            return CGRect(x: point.x - width * anchorX, y: point.y - measured.height * anchorY,
                          width: width, height: measured.height)
        }
        return CGRect(x: picture.minX + leading + (width - measured.width) * anchorX,
                      y: picture.minY + margin + (picture.height - 2 * margin - measured.height) * anchorY,
                      width: measured.width, height: measured.height)
    }

    func reservedRectangle(for measured: CGSize, text: NSAttributedString) -> CGRect {
        var horizontal: CGFloat = 0, vertical: CGFloat = 0
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, _, _ in
            let font = attributes[.font] as? UIFont
            let fontSize = max(8, (font?.pointSize ?? 0) * scale)
            let stroke = abs((attributes[.strokeWidth] as? NSNumber)?.doubleValue ?? 0) / 100 * fontSize
            var extraX = CGFloat(stroke), extraY = CGFloat(stroke)
            if let shadow = attributes[.shadow] as? NSShadow {
                extraX += (abs(shadow.shadowOffset.width) + shadow.shadowBlurRadius) * scale
                extraY += (abs(shadow.shadowOffset.height) + shadow.shadowBlurRadius) * scale
            }
            horizontal = max(horizontal, extraX); vertical = max(vertical, extraY)
        }
        return rectangle(for: measured).insetBy(dx: -horizontal, dy: -vertical)
    }
}

struct NativeAttributedSubtitleLabel: UIViewRepresentable {
    let text: NSAttributedString
    let alignment: NSTextAlignment
    let scale: CGFloat
    final class Coordinator {
        var source: NSAttributedString?
        var scale: CGFloat?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UILabel {
        let label = UILabel(); label.numberOfLines = 0; label.backgroundColor = .clear
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
    func updateUIView(_ view: UILabel, context: Context) {
        // ASS move/fade changes geometry, not authored glyph styling. Retain one
        // scaled cue per label instead of rebuilding font/shadow runs every tick.
        if context.coordinator.source !== text || context.coordinator.scale != scale {
            context.coordinator.source = text; context.coordinator.scale = scale
            view.attributedText = scaled(text, scale: scale)
        }
        if view.textAlignment != alignment { view.textAlignment = alignment }
    }
    private func scaled(_ source: NSAttributedString, scale: CGFloat) -> NSAttributedString {
        return Self.scaledText(source, scale: scale)
    }
    static func scaledText(_ source: NSAttributedString, scale: CGFloat) -> NSAttributedString {
        let value = NSMutableAttributedString(attributedString: source)
        source.enumerateAttributes(in: NSRange(location: 0, length: source.length)) { attributes, range, _ in
            if let font = attributes[.font] as? UIFont { value.addAttribute(.font, value: font.withSize(max(8, font.pointSize * scale)), range: range) }
            if let shadow = (attributes[.shadow] as? NSShadow)?.copy() as? NSShadow {
                shadow.shadowOffset = CGSize(width: shadow.shadowOffset.width * scale, height: shadow.shadowOffset.height * scale)
                shadow.shadowBlurRadius *= scale
                value.addAttribute(.shadow, value: shadow, range: range)
            }
            if let spacing = attributes[.kern] as? Double { value.addAttribute(.kern, value: spacing * scale, range: range) }
        }
        return value
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UILabel, context: Context) -> CGSize? {
        uiView.sizeThatFits(CGSize(width: proposal.width ?? 300, height: .greatestFiniteMagnitude))
    }
}

/// Text and bitmap cues with authored positions stay separate; ordinary dialogue is measured
/// together so both tracks wrap, separate and remain above the actual home-indicator area.
struct PlayerSubtitlePresentation {
    var lines: [String] = []
    var styledParts: [SubtitlePart] = []
    var sourceTime = 0.0
    var bitmaps: [KSPlaybackSubtitleBitmap] = []

    func dialogueParts(style: SubtitleStyle) -> [SubtitlePart] {
        guard !style.overrideAssStyle else { return [] }
        return styledParts.filter { NativeStyledSubtitleGeometry.isDialogue($0) && $0.text != nil &&
            $0.animation.opacity(at: sourceTime - $0.start, duration: max(0, $0.end - $0.start)) > 0 }
    }
    func authoredParts(style: SubtitleStyle) -> [SubtitlePart] {
        style.overrideAssStyle ? [] : styledParts.filter { !NativeStyledSubtitleGeometry.isDialogue($0) }
    }
    func plainLines(style: SubtitleStyle) -> [String] {
        style.overrideAssStyle || styledParts.isEmpty ? lines : []
    }
}

struct PlayerCombinedSubtitleOverlay: View {
    let primary: PlayerSubtitlePresentation
    let secondary: PlayerSubtitlePresentation
    let pictureSize: CGSize
    var fills = false
    var videoAspect = PlayerVideoAspect()
    @State private var style = SubtitleStyle.load()

    var body: some View {
        GeometryReader { proxy in
            let picture = videoAspect.pictureFrame(in: proxy.size, source: pictureSize)
            let shown = style.clamped
            let mainParts = primary.dialogueParts(style: shown)
            let secondParts = secondary.dialogueParts(style: shown)
            let mainBitmaps = dialogueBitmaps(primary.bitmaps, picture: picture)
            let secondBitmaps = dialogueBitmaps(secondary.bitmaps, picture: picture)
            let paired = (!primary.plainLines(style: shown).isEmpty || !mainParts.isEmpty || !mainBitmaps.isEmpty) &&
                (!secondary.plainLines(style: shown).isEmpty || !secondParts.isEmpty || !secondBitmaps.isEmpty)
            let letters = max(4, picture.height * shown.size / 100)
            let lineHeight = PlayerSubtitleTextMetrics.normalLineHeight(parts: mainParts, picture: picture,
                style: shown, letters: letters)
            PlayerSubtitlePairLayout(style: shown, picture: picture, viewport: proxy.size,
                bottomInset: subtitleBottomInset(in: proxy), normalLineHeight: lineHeight) {
                PlayerDialogueSubtitleContent(lines: primary.plainLines(style: shown), parts: mainParts,
                    bitmaps: paired ? mainBitmaps : [], picture: picture, style: shown, time: primary.sourceTime, scale: 1)
                PlayerDialogueSubtitleContent(lines: secondary.plainLines(style: shown), parts: secondParts,
                    bitmaps: paired ? secondBitmaps : [], picture: picture, style: shown, time: secondary.sourceTime,
                    scale: SubtitlePairGeometry.secondaryScale)
            }
            NativeStyledSubtitleOverlay(parts: primary.authoredParts(style: shown), pictureSize: pictureSize,
                fills: fills, explicitPicture: picture, time: primary.sourceTime)
            NativeStyledSubtitleOverlay(parts: secondary.authoredParts(style: shown), pictureSize: pictureSize,
                fills: fills, explicitPicture: picture, secondary: true, time: secondary.sourceTime)
            ForEach(Array((paired ? authoredBitmaps(primary.bitmaps + secondary.bitmaps, picture: picture) : primary.bitmaps + secondary.bitmaps).enumerated()), id: \.offset) { _, bitmap in
                if let rectangle = bitmapRectangle(bitmap, picture: picture) {
                    Image(uiImage: bitmap.image).resizable().frame(width: rectangle.width, height: rectangle.height)
                        .position(x: rectangle.midX, y: rectangle.midY).opacity(shown.opacity)
                }
            }
        }.clipped().allowsHitTesting(false).accessibilityHidden(true)
            .onReceive(NotificationCenter.default.publisher(for: SubtitleStyle.changed)) { _ in style = SubtitleStyle.load() }
    }
    private func bitmapRectangle(_ bitmap: KSPlaybackSubtitleBitmap, picture: CGRect) -> CGRect? {
        SubtitleBitmapGeometry.rectangle(origin: bitmap.origin, imageSize: bitmap.image.size, canvasSize: bitmap.canvasSize, picture: picture)
    }
    private func dialogueBitmaps(_ bitmaps: [KSPlaybackSubtitleBitmap], picture: CGRect) -> [KSPlaybackSubtitleBitmap] {
        bitmaps.filter { bitmapRectangle($0, picture: picture).map { SubtitleBitmapGeometry.isBottomDialogue($0, in: picture) } ?? false }
    }
    private func authoredBitmaps(_ bitmaps: [KSPlaybackSubtitleBitmap], picture: CGRect) -> [KSPlaybackSubtitleBitmap] {
        bitmaps.filter { bitmapRectangle($0, picture: picture).map { !SubtitleBitmapGeometry.isBottomDialogue($0, in: picture) } ?? false }
    }
}

enum PlayerSubtitleTextMetrics {
    static func font(style: SubtitleStyle, letters: CGFloat) -> UIFont {
        PlayerFontLibrary.ensureRegistered()
        let base = style.font.flatMap { UIFont(name: $0, size: letters) } ?? UIFont.systemFont(ofSize: letters)
        var traits: UIFontDescriptor.SymbolicTraits = []
        if style.bold { traits.insert(.traitBold) }
        if style.italic { traits.insert(.traitItalic) }
        return base.fontDescriptor.withSymbolicTraits(traits).map { UIFont(descriptor: $0, size: letters) } ?? base
    }
    static func lineHeight(style: SubtitleStyle, letters: CGFloat) -> CGFloat { font(style: style, letters: letters).lineHeight }
    static func normalLineHeight(parts: [SubtitlePart], picture: CGRect, style: SubtitleStyle, letters: CGFloat) -> CGFloat {
        let nativeHeight = parts.compactMap { part -> CGFloat? in
            guard let text = part.text else { return nil }
            let scale = NativeStyledSubtitleGeometry(part: part, picture: picture, time: part.start).scale
            var height: CGFloat = 0
            text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, _, _ in
                if let font = value as? UIFont { height = max(height, font.withSize(max(8, font.pointSize * scale)).lineHeight) }
            }
            return height > 0 ? height : nil
        }.max()
        return nativeHeight ?? lineHeight(style: style, letters: letters)
    }
}

private struct PlayerDialogueSubtitleContent: View {
    let lines: [String]
    let parts: [SubtitlePart]
    let bitmaps: [KSPlaybackSubtitleBitmap]
    let picture: CGRect
    let style: SubtitleStyle
    let time: Double
    let scale: CGFloat
    var body: some View {
        VStack(spacing: 2) {
            if !lines.isEmpty {
                SubtitleLines(lines: lines, style: style, letters: max(4, picture.height * style.size / 100) * scale)
            }
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                if let text = part.text {
                    NativeAttributedSubtitleLabel(text: text, alignment: .center,
                        scale: NativeStyledSubtitleGeometry(part: part, picture: picture, time: time).scale * scale)
                        .opacity(style.opacity * part.animation.opacity(at: time - part.start, duration: max(0, part.end - part.start)))
                }
            }
            ForEach(Array(bitmaps.enumerated()), id: \.offset) { _, bitmap in
                if let rectangle = SubtitleBitmapGeometry.rectangle(origin: bitmap.origin, imageSize: bitmap.image.size,
                    canvasSize: bitmap.canvasSize, picture: picture) {
                    Image(uiImage: bitmap.image).resizable()
                        .frame(width: rectangle.width * scale, height: rectangle.height * scale).opacity(style.opacity)
                }
            }
        }.fixedSize(horizontal: false, vertical: true)
    }
}

private struct PlayerSubtitlePairLayout: SwiftUI.Layout {
    let style: SubtitleStyle
    let picture: CGRect
    let viewport: CGSize
    let bottomInset: CGFloat
    let normalLineHeight: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { viewport }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let textProposal = ProposedViewSize(width: picture.width * style.width, height: nil)
        let main = subviews[0].sizeThatFits(textProposal), second = subviews[1].sizeThatFits(textProposal)
        let pair = SubtitlePairGeometry.rectangles(primarySize: main, secondarySize: second,
            normalLineHeight: normalLineHeight, style: style, picture: picture,
            viewportHeight: viewport.height, bottomInset: bottomInset,
            padding: max(6, style.outlineSize + style.shadowOffset))
        for index in 0..<2 {
            let rectangle = index == 0 ? pair.primary : pair.secondary
            subviews[index].place(at: CGPoint(x: bounds.minX + rectangle.minX, y: bounds.minY + rectangle.minY),
                anchor: .topLeading, proposal: textProposal)
        }
    }
}
#endif
