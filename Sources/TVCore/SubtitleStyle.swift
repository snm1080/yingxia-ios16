import CoreMedia
import Foundation

/// How subtitles look in the player (#547): where they sit on the picture, their size, font, weight, colour, edge
/// and backdrop. The app draws the subtitle lines itself in this style (AVPlayer's own renderer keeps the system's
/// box behind them whatever the item's text style rules say). Where only AVPlayer can draw them, in Picture in
/// Picture, `attributes` carries what its renderer does follow. Saved under `key` as JSON.
public struct SubtitleStyle: Codable, Equatable, Sendable {
    public static let key = "subtitleStyle"
    /// Posted on the main thread when `save()` stores a new style, so a playing video takes it at once.
    public static let changed = Notification.Name("SubtitleStyleChanged")

    public enum TextColor: String, Codable, CaseIterable, Sendable {
        case white, yellow, cyan, green, pink
        /// Red, green and blue from 0 to 1.
        public var rgb: (red: Double, green: Double, blue: Double) {
            switch self {
            case .white: (1, 1, 1)
            case .yellow: (1, 0.86, 0.2)
            case .cyan: (0.45, 0.88, 1)
            case .green: (0.55, 0.95, 0.55)
            case .pink: (1, 0.62, 0.8)
            }
        }
        public var title: String {
            switch self {
            case .white: L10n.text("White")
            case .yellow: L10n.text("Yellow")
            case .cyan: L10n.text("Cyan")
            case .green: L10n.text("Green")
            case .pink: L10n.text("Pink")
            }
        }
    }

    /// What sets the letters off from the picture.
    public enum Edge: String, Codable, CaseIterable, Sendable {
        case none, shadow, outline, raised, depressed
        public var title: String {
            switch self {
            case .none: L10n.text("None")
            case .shadow: L10n.text("Drop Shadow")
            case .outline: L10n.text("Outline")
            case .raised: L10n.text("Raised")
            case .depressed: L10n.text("Depressed")
            }
        }
        var markup: CFString {
            switch self {
            case .none: kCMTextMarkupCharacterEdgeStyle_None
            case .shadow: kCMTextMarkupCharacterEdgeStyle_DropShadow
            case .outline: kCMTextMarkupCharacterEdgeStyle_Uniform
            case .raised: kCMTextMarkupCharacterEdgeStyle_Raised
            case .depressed: kCMTextMarkupCharacterEdgeStyle_Depressed
            }
        }
    }

    /// The box behind each line: none (#547 asked to lose the black one), see-through, or solid black.
    public enum Backdrop: String, Codable, CaseIterable, Sendable {
        case none, translucent, solid
        public var title: String {
            switch self {
            case .none: L10n.text("None")
            case .translucent: L10n.text("Translucent")
            case .solid: L10n.text("Solid")
            }
        }
        /// The black box's opacity.
        public var opacity: Double {
            switch self {
            case .none: 0
            case .translucent: 0.55
            case .solid: 1
            }
        }
    }

    /// Where the subtitle sits, as fractions of the picture. `x` is the centre of its lines across. Down, the point
    /// `y` of the way through the subtitle's own height sits `y` of the way down the picture: at 0 its top touches
    /// the picture's top, at 1 its bottom touches the bottom, and near the bottom a second line grows upwards.
    public var x = 0.5
    public var y = SubtitleStyle.bottom
    /// The letters' height as a percentage of the picture's.
    public var size = 5.0
    /// A font family installed on the device; nil is the system's.
    public var font: String?
    public var bold = false
    public var italic = false
    public var color = TextColor.white { didSet { if color != oldValue { customColor = nil } } }
    public var edge = Edge.shadow {
        didSet {
            guard edge != oldValue else { return }
            outlineSize = edge == .outline ? 2 : 0
            shadowOffset = edge == .shadow ? 1 : 0
        }
    }
    public var backdrop = Backdrop.none
    /// Kept separate from the legacy named swatches so older saved styles retain their selected color.
    public var customColor: String?
    public var opacity = 1.0
    public var outlineColor = "#000000"
    public var outlineSize = 2.0
    public var shadowOffset = 1.0
    public var overrideAssStyle = false
    public var foregroundRGB: (red: Double, green: Double, blue: Double) {
        customColor.map(PlayerStyleColor.rgb) ?? color.rgb
    }

    public init() {}

    public static let sizes: ClosedRange<Double> = 1.2...9.6
    /// Matches MacCat's default position 100. Explicit saved positions, including the earlier 0.92,
    /// remain untouched because that value may also have been chosen by the viewer.
    public static let top = 0.06, middle = 0.5, bottom = 1.0

    /// The width of the box the lines wrap in, centred on `x` and kept inside the picture, as a fraction of its width.
    public var width: Double { min(0.9, 2 * min(x, 1 - x)) }

    /// Keep the existing position until its measured text box would enter the home-indicator area.
    /// Position 100 therefore ends at the safe picture bottom without moving a saved 92 unnecessarily.
    public static func safeVerticalOrigin(position: Double, textHeight: Double, pictureTop: Double,
                                          pictureHeight: Double, viewportHeight: Double,
                                          bottomInset: Double, padding: Double = 6) -> Double {
        let ratio = min(1, max(0, position))
        let requested = pictureTop + (pictureHeight - textHeight) * ratio
        let safeBottom = min(pictureTop + pictureHeight, viewportHeight - max(0, bottomInset) - max(0, padding))
        return max(pictureTop, min(requested, safeBottom - textHeight))
    }

    /// AI text shares the selected subtitle position. When a primary cue is also visible, keep its
    /// renderer and anchor intact and place the measured companion just above it (below for a top cue).
    public static func companionVerticalOrigin(position: Double, textHeight: Double, primaryTextHeight: Double,
                                               pictureTop: Double, pictureHeight: Double, viewportHeight: Double,
                                               bottomInset: Double, padding: Double = 6, gap: Double = 6) -> Double {
        let normal = safeVerticalOrigin(position: position, textHeight: textHeight, pictureTop: pictureTop,
            pictureHeight: pictureHeight, viewportHeight: viewportHeight, bottomInset: bottomInset, padding: padding)
        guard primaryTextHeight > 0 else { return normal }
        let primary = safeVerticalOrigin(position: position, textHeight: primaryTextHeight, pictureTop: pictureTop,
            pictureHeight: pictureHeight, viewportHeight: viewportHeight, bottomInset: bottomInset, padding: padding)
        let separation = max(0, gap)
        let above = primary - separation - textHeight
        if above >= pictureTop { return above }
        let below = primary + primaryTextHeight + separation
        let safeBottom = min(pictureTop + pictureHeight, viewportHeight - max(0, bottomInset) - max(0, padding))
        if below + textHeight <= safeBottom { return below }
        return max(pictureTop, above)
    }

    /// Reserve actual authored text/image rectangles. Prefer the nearest free safe region; if the
    /// primary fills it, keep AI at a visible safe origin instead of pushing it outside the picture.
    public static func nonOverlappingVerticalOrigin(requestedOrigin: Double, textHeight: Double,
                                                    textLeft: Double, textWidth: Double, picture: CGRect,
                                                    viewportHeight: Double, bottomInset: Double,
                                                    padding: Double = 6, gap: Double = 6,
                                                    occupied: [CGRect]) -> Double {
        let top = Double(picture.minY)
        let safeBottom = min(Double(picture.maxY), viewportHeight - max(0, bottomInset) - max(0, padding))
        let height = max(0, textHeight.isFinite ? textHeight : 0)
        let maximum = max(top, safeBottom - height)
        let wanted = min(maximum, max(top, requestedOrigin.isFinite ? requestedOrigin : top))
        guard height > 0, maximum > top else { return wanted }
        let separation = max(0, gap)
        let ranges = occupied.compactMap { rect -> (Double, Double)? in
            guard !rect.isNull, !rect.isEmpty,
                  [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy(\.isFinite),
                  Double(rect.maxX) + separation > textLeft,
                  Double(rect.minX) - separation < textLeft + textWidth,
                  Double(rect.maxY) > top, Double(rect.minY) < safeBottom else { return nil }
            return (Double(rect.minY) - separation - height, Double(rect.maxY) + separation)
        }
        func fits(_ origin: Double) -> Bool { !ranges.contains { origin > $0.0 && origin < $0.1 } }
        if fits(wanted) { return wanted }
        let candidates = ([top, maximum] + ranges.flatMap { [$0.0, $0.1] })
            .filter { $0 >= top && $0 <= maximum && fits($0) }
        return candidates.min { lhs, rhs in
            let left = abs(lhs - wanted), right = abs(rhs - wanted)
            return left == right ? lhs < rhs : left < right
        } ?? wanted
    }

    /// The same style with its numbers kept in range: a hand-edited or older value can't push a subtitle off the picture.
    public var clamped: SubtitleStyle {
        var style = self
        style.x = min(max(x.isFinite ? x : 0.5, 0.15), 0.85)
        style.y = min(max(y.isFinite ? y : Self.bottom, 0), 1)
        style.size = min(max(size.isFinite ? size : 5, Self.sizes.lowerBound), Self.sizes.upperBound)
        style.opacity = opacity.isFinite ? min(1, max(0, opacity)) : 1
        style.outlineSize = outlineSize.isFinite ? min(8, max(0, outlineSize)) : 2
        style.shadowOffset = shadowOffset.isFinite ? min(8, max(0, shadowOffset)) : 1
        if let customColor { style.customColor = PlayerStyleColor.normalize(customColor) }
        style.outlineColor = PlayerStyleColor.normalize(outlineColor, fallback: "#000000")
        if let font, font.trimmingCharacters(in: .whitespaces).isEmpty { style.font = nil }
        return style
    }

    /// The text-markup attributes for AVPlayer's own renderer (`AVTextStyleRule`), for when it draws the subtitles:
    /// the letters' size, font, weight, colour and edge. It leaves the place to the cue and draws the system's
    /// box whatever a rule says, so neither is set.
    public var attributes: [String: Any] {
        let style = clamped
        let (red, green, blue) = style.foregroundRGB
        var attributes: [String: Any] = [
            kCMTextMarkupAttribute_ForegroundColorARGB as String: [style.opacity, red, green, blue],
            kCMTextMarkupAttribute_CharacterEdgeStyle as String: style.edge.markup as String,
            kCMTextMarkupAttribute_BaseFontSizePercentageRelativeToVideoHeight as String: style.size,
            kCMTextMarkupAttribute_BoldStyle as String: style.bold,
            kCMTextMarkupAttribute_ItalicStyle as String: style.italic,
        ]
        if let font = style.font { attributes[kCMTextMarkupAttribute_FontFamilyName as String] = font }
        return attributes
    }

    /// The saved style, or the standard one.
    public static func load(_ defaults: UserDefaults = .standard) -> SubtitleStyle {
        guard let data = defaults.data(forKey: key), let style = try? JSONDecoder().decode(SubtitleStyle.self, from: data) else { return SubtitleStyle() }
        return style.clamped
    }

    public func save(_ defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(clamped) else { return }
        defaults.set(data, forKey: Self.key)
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    /// The subtitle lines in `strings`, as a legible output hands them over: one string for each cue on screen,
    /// each perhaps several lines. Blank lines and the spaces around lines go.
    public static func lines(_ strings: [String]) -> [String] {
        strings.flatMap { $0.components(separatedBy: .newlines) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private enum CodingKeys: String, CodingKey { case x, y, size, font, bold, italic, color, edge, backdrop, customColor, opacity, outlineColor, outlineSize, shadowOffset, overrideAssStyle }

    /// Fields a newer or older app didn't save keep their standard values, and unknown choices fall back to them.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let standard = SubtitleStyle()
        x = (try? container.decodeIfPresent(Double.self, forKey: .x)) ?? standard.x
        y = (try? container.decodeIfPresent(Double.self, forKey: .y)) ?? standard.y
        size = (try? container.decodeIfPresent(Double.self, forKey: .size)) ?? standard.size
        font = try? container.decodeIfPresent(String.self, forKey: .font)
        bold = (try? container.decodeIfPresent(Bool.self, forKey: .bold)) ?? standard.bold
        italic = (try? container.decodeIfPresent(Bool.self, forKey: .italic)) ?? standard.italic
        color = (try? container.decodeIfPresent(TextColor.self, forKey: .color)) ?? standard.color
        edge = (try? container.decodeIfPresent(Edge.self, forKey: .edge)) ?? standard.edge
        backdrop = (try? container.decodeIfPresent(Backdrop.self, forKey: .backdrop)) ?? standard.backdrop
        customColor = try? container.decodeIfPresent(String.self, forKey: .customColor)
        opacity = (try? container.decodeIfPresent(Double.self, forKey: .opacity)) ?? standard.opacity
        outlineColor = (try? container.decodeIfPresent(String.self, forKey: .outlineColor)) ?? standard.outlineColor
        outlineSize = (try? container.decodeIfPresent(Double.self, forKey: .outlineSize)) ?? (edge == .outline ? 2 : 0)
        shadowOffset = (try? container.decodeIfPresent(Double.self, forKey: .shadowOffset)) ?? (edge == .shadow ? 1 : 0)
        overrideAssStyle = (try? container.decodeIfPresent(Bool.self, forKey: .overrideAssStyle)) ?? standard.overrideAssStyle
    }
}
