@preconcurrency import AVFoundation
import SwiftUI
import Perception
import TVCore
#if os(iOS)
import KSPlayer
#endif

/// The subtitle lines on screen now, which the app draws itself in the chosen `SubtitleStyle` (#547). Each item gets a
/// legible output that stops AVPlayer drawing them (its renderer keeps the system's box behind the letters whatever
/// the item's text style rules say) and hands over the text of the cues as they come and go. Nothing runs between
/// cues, and nothing at all while no subtitle is chosen.
@MainActor @Perceptible final class SubtitleCues: NSObject, AVPlayerItemLegibleOutputPushDelegate {
    private(set) var lines: [String] = []
    /// The picture's size, to place the lines on the picture rather than on the whole view.
    private(set) var pictureSize: CGSize = .zero
    private(set) var style = SubtitleStyle.load()
    /// How late the lines show (#599). 0 keeps AVPlayer's own timing.
    private(set) var delay = SubtitleDelay.load()
    /// What AVPlayer handed over, waiting for its turn while `delay` is on.
    @PerceptionIgnored private var schedule = SubtitleSchedule()
    /// The playback time `advance(to:)` saw last: what is due there when the delay is turned off.
    @PerceptionIgnored private var lastAdvanced: Double?
    @PerceptionIgnored private var lastDocumentTexts: [String]?
    /// A subtitle file the app shows itself (`ExternalSubtitles`, #576), at the player's clock: while there is one,
    /// what AVPlayer hands over is ignored (its own subtitles are off then).
    private(set) var document: SubtitleDocument?
    #if os(iOS)
    private(set) var styledParts: [SubtitlePart] = []
    private(set) var styledSourceTime = 0.0
    @PerceptionIgnored private var documentStyledParts: [SubtitlePart] = []
    @PerceptionIgnored private var documentStyledReach: [Double] = []
    #endif
    @PerceptionIgnored var timing = SubtitleTiming() {
        didSet { if let lastAdvanced, document != nil { advance(to: lastAdvanced) } }
    }
    /// Runs when one of the item's own subtitles is chosen while a file shows: the file makes way.
    @PerceptionIgnored var nativeChosen: () -> Void = {}
    /// AVPlayer draws the subtitles itself while the picture is somewhere the app's overlay isn't: Picture in Picture.
    var native = false {
        didSet {
            guard native != oldValue else { return }
            for output in outputs.allObjects { output.suppressesPlayerRendering = !native }
        }
    }
    @PerceptionIgnored private let outputs = NSHashTable<AVPlayerItemLegibleOutput>.weakObjects()
    @PerceptionIgnored private weak var item: AVPlayerItem?
    @PerceptionIgnored private var sizeObservation: NSKeyValueObservation?

    override init() {
        super.init()
        schedule.delay = delay
        NotificationCenter.default.addObserver(self, selector: #selector(styleChanged), name: SubtitleStyle.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(delayChanged), name: SubtitleDelay.changed, object: nil)
    }

    /// Gives a new item its output; every item the queue may play needs one.
    func attach(_ item: AVPlayerItem) {
        let output = AVPlayerItemLegibleOutput()
        output.suppressesPlayerRendering = !native
        output.setDelegate(self, queue: .main)
        item.add(output)
        outputs.add(output)
    }

    /// The item now playing: its lines show, the last item's go.
    func follow(_ item: AVPlayerItem?) {
        guard item !== self.item else { return }
        // A file belongs to an episode; the session shows it again on the next one's item, if it is the same episode.
        if let old = self.item { NotificationCenter.default.removeObserver(self, name: AVPlayerItem.mediaSelectionDidChangeNotification, object: old) }
        self.item = item
        lines = []
        pictureSize = .zero
        schedule.reset()
        lastAdvanced = nil
        sizeObservation = item?.observe(\.presentationSize, options: [.initial, .new]) { [weak self] item, _ in
            let size = item.presentationSize
            Task { @MainActor [weak self] in if self?.pictureSize != size { self?.pictureSize = size } }
        }
        // Subtitles turned off: the output says nothing more about the last lines.
        if let item { NotificationCenter.default.addObserver(self, selector: #selector(selectionChanged), name: AVPlayerItem.mediaSelectionDidChangeNotification, object: item) }
    }

    #if os(iOS)
    /// KS provides decoded text while external documents keep their existing timing controls.
    func updateKS(lines next: [String], pictureSize: CGSize) {
        if self.pictureSize != pictureSize { self.pictureSize = pictureSize }
        guard document == nil else { return }
        if lines != next { lines = next }
    }
    func resetKS() {
        lines = []; pictureSize = .zero; document = nil
        styledParts = []; documentStyledParts = []; documentStyledReach = []
        lastDocumentTexts = nil
        schedule.reset(); lastAdvanced = nil
    }
    #endif

    /// Where the picture is in a view `bounds` big: fitted inside it, or the whole view when it fills (and is cropped).
    func pictureRect(in bounds: CGSize, fills: Bool) -> CGRect {
        let whole = CGRect(origin: .zero, size: bounds)
        guard !fills, pictureSize.width > 0, pictureSize.height > 0 else { return whole }
        return AVMakeRect(aspectRatio: pictureSize, insideRect: whole)
    }

    nonisolated func legibleOutput(_ output: AVPlayerItemLegibleOutput, didOutputAttributedStrings strings: [NSAttributedString],
                                   nativeSampleBuffers nativeSamples: [Any], forItemTime itemTime: CMTime) {
        let lines = SubtitleStyle.lines(strings.map(\.string))
        // The delegate queue is the main queue (`attach`).
        MainActor.assumeIsolated {
            guard let item, item.outputs.contains(where: { $0 === output }), document == nil else { return }
            if delay > 0 {
                // Held until its turn. AVPlayer repeats a cue it is still showing; `schedule` keeps the last word.
                schedule.enqueue(lines, at: itemTime.seconds)
            } else if self.lines != lines {
                self.lines = lines
            }
        }
    }

    /// Shows the lines whose delay has passed, at the player's own clock: a paused video holds them, and so does
    /// one still buffering. Call it while `delay` is on; at 0 the lines go up as AVPlayer hands them over.
    func advance(to time: Double) {
        if let document, time.isFinite {
            lastAdvanced = time
            let source = timing.source(at: time)
            let texts = document.texts(at: source)
            if lastDocumentTexts != texts {
                lastDocumentTexts = texts
                let next = SubtitleStyle.lines(texts)
                if next != lines { lines = next }
            }
            #if os(iOS)
            let sourceTime = Double(source) / 1_000_000
            let styled = styledDocumentParts(at: sourceTime)
            let changed = !styledParts.elementsEqual(styled, by: { $0 === $1 })
            if changed || styled.contains(where: { $0.animation.requiresContinuousTime }) {
                if styledSourceTime != sourceTime { styledSourceTime = sourceTime }
            }
            if changed {
                // SubtitlePart's Equatable compares only times; changed text at the
                // same interval must still invalidate the app's attributed overlay.
                withMutation(keyPath: \.styledParts) { styledParts = styled }
            }
            #endif
            return
        }
        guard delay > 0, time.isFinite else { return }
        // A seek is the schedule's to tell: it clears the line and what waited for the old place.
        lastAdvanced = time
        if let next = schedule.lines(at: time), next != lines { lines = next }
    }

    /// Shows `document` (nil: back to the item's own subtitles) from `time` on.
    func show(_ document: SubtitleDocument?, timing: SubtitleTiming, at time: Double?) {
        self.timing = timing
        guard document != self.document else { return }
        self.document = document
        lastDocumentTexts = nil
        #if os(iOS)
        documentStyledParts = []; documentStyledReach = []; styledParts = []
        if let document, document.format.isStyled, let text = document.sourceText {
            let parser = AssParse()
            let scanner = Scanner(string: text)
            _ = scanner.scanCharacters(from: .controlCharacters)
            if parser.canParse(scanner: scanner) {
                documentStyledParts = parser.parse(scanner: scanner)
                var reach = -Double.infinity
                documentStyledReach = documentStyledParts.map { reach = max(reach, $0.end); return reach }
            }
        }
        #endif
        schedule.reset()
        lines = []
        if let time { advance(to: time) }
    }

    @objc private func styleChanged() { style = SubtitleStyle.load() }

    #if os(iOS)
    private func styledDocumentParts(at time: Double) -> [SubtitlePart] {
        var low = 0, high = documentStyledParts.count
        while low < high {
            let middle = (low + high) / 2
            if documentStyledParts[middle].start <= time { low = middle + 1 } else { high = middle }
        }
        var index = low - 1, active: [SubtitlePart] = []
        while index >= 0, documentStyledReach[index] > time {
            if documentStyledParts[index].end > time { active.append(documentStyledParts[index]) }
            index -= 1
        }
        return active.reversed()
    }
    #endif

    @objc private func delayChanged() {
        let next = SubtitleDelay.load()
        guard next != delay else { return }
        delay = next
        schedule.delay = next
        guard next == 0 else { return }
        // Off again: what is up now is whatever the player's clock has due, not what was queued last.
        if let lastAdvanced, let now = schedule.lines(at: lastAdvanced) { lines = now }
        schedule.reset()
    }
    /// Clears the lines once no subtitle is chosen. A newly chosen one sends its own lines, sometimes before this.
    @objc private func selectionChanged() {
        guard let item else { return }
        Task { [weak self, weak item] in
            guard let item, let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
                  let self, self.item === item else { return }
            // A track change too: the old track's lines must not wait behind the new one's.
            self.schedule.reset()
            if let option = item.currentMediaSelection.selectedMediaOption(in: group) {
                if self.document != nil, !option.hasMediaCharacteristic(.containsOnlyForcedSubtitles) { self.nativeChosen() }
                return
            }
            guard self.document == nil else { return }
            self.lines = []
        }
    }
}

/// The playing video's subtitle lines over its picture, in the chosen style.
struct SubtitleOverlay: View {
    let cues: SubtitleCues
    /// The picture fills the view and is cropped, rather than fitting inside it.
    var fills = false
    var body: some View {
        WithPerceptionTracking {
            GeometryReader { proxy in
                WithPerceptionTracking {
                    if !cues.native, !cues.lines.isEmpty {
                        let picture = cues.pictureRect(in: proxy.size, fills: fills)
                        let style = cues.style.clamped
                        #if os(iOS)
                        if !style.overrideAssStyle, !cues.styledParts.isEmpty {
                            NativeStyledSubtitleOverlay(parts: cues.styledParts, pictureSize: cues.pictureSize, fills: fills, time: cues.styledSourceTime)
                        } else {
                            SubtitleLines(lines: cues.lines, style: style, letters: max(4, picture.height * style.size / 100))
                                .subtitlePlacement(style, in: picture, viewportHeight: proxy.size.height,
                                                   bottomInset: subtitleBottomInset(in: proxy))
                        }
                        #else
                        SubtitleLines(lines: cues.lines, style: style, letters: max(4, picture.height * style.size / 100))
                            .subtitlePlacement(style, in: picture)
                        #endif
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }
}

/// A subtitle's lines in `style`, the letters `letters` points tall, each line on its own box when the style has one.
struct SubtitleLines: View {
    let lines: [String]
    let style: SubtitleStyle
    let letters: CGFloat
    /// Keeps each line on one line, shrinking it to fit: the preview's sample.
    var oneLine = false

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: letters * 0.15) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    WithPerceptionTracking {
                        ZStack {
                            if style.outlineSize > 0 {
                                ForEach(0..<8, id: \.self) { direction in
                                    Text(line).font(font).foregroundStyle(outlineSwatch)
                                        .offset(x: cos(Double(direction) * .pi / 4) * style.outlineSize,
                                                y: sin(Double(direction) * .pi / 4) * style.outlineSize)
                                }
                            }
                            Text(line).font(font).foregroundStyle(swatch)
                        }
                            .subtitleRelief(style.edge, letters: letters)
                            .shadow(color: .black.opacity(style.shadowOffset > 0 ? 0.85 : 0), radius: style.shadowOffset * 0.35,
                                    x: style.shadowOffset, y: style.shadowOffset)
                            .padding(.horizontal, style.backdrop == .none ? 0 : letters * 0.3)
                            .padding(.vertical, style.backdrop == .none ? 0 : letters * 0.06)
                            .background(Color.black.opacity(style.backdrop.opacity), in: RoundedRectangle(cornerRadius: letters * 0.12, style: .continuous))
                    }
                }
            }
            .multilineTextAlignment(.center)
            .lineLimit(oneLine ? 1 : nil)
            .minimumScaleFactor(oneLine ? 0.5 : 1)
            .fixedSize(horizontal: false, vertical: true)
            .opacity(style.opacity)
        }
    }

    private var font: Font {
        #if os(iOS)
        PlayerFontLibrary.ensureRegistered()
        #endif
        var font = style.font.map { Font.custom($0, fixedSize: letters) } ?? .system(size: letters)
        if style.bold { font = font.bold() }
        if style.italic { font = font.italic() }
        return font
    }

    private var swatch: Color {
        let (red, green, blue) = style.foregroundRGB
        return Color(red: red, green: green, blue: blue)
    }
    private var outlineSwatch: Color {
        let (red, green, blue) = PlayerStyleColor.rgb(style.outlineColor)
        return Color(red: red, green: green, blue: blue)
    }
}

extension View {
    @ViewBuilder func subtitleRelief(_ edge: SubtitleStyle.Edge, letters: CGFloat) -> some View {
        if edge == .raised || edge == .depressed { subtitleEdge(edge, letters: letters) } else { self }
    }
    /// Places a subtitle on `picture` (a rect in the parent's space) where `style` says: its lines in a box
    /// `style.width` of the picture wide centred on `x`, and the point `y` of the way through its height `y` of the
    /// way down the picture.
    func subtitlePlacement(_ style: SubtitleStyle, in picture: CGRect, viewportHeight: CGFloat? = nil, bottomInset: CGFloat = 0) -> some View {
        frame(width: picture.width * style.width)
            .alignmentGuide(.leading) { d in d.width / 2 - picture.minX - picture.width * style.x }
            .alignmentGuide(.top) { d in
                guard let viewportHeight else { return d.height * style.y - picture.minY - picture.height * style.y }
                return -SubtitleStyle.safeVerticalOrigin(position: style.y, textHeight: d.height,
                    pictureTop: picture.minY, pictureHeight: picture.height, viewportHeight: viewportHeight,
                    bottomInset: bottomInset, padding: max(6, style.outlineSize + style.shadowOffset))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The subtitle edge styles, near enough to how AVPlayer's renderer draws them.
    @ViewBuilder func subtitleEdge(_ edge: SubtitleStyle.Edge, letters: CGFloat) -> some View {
        let step = max(1, letters * 0.04)
        switch edge {
        case .none: self
        case .shadow: shadow(color: .black.opacity(0.85), radius: step, x: step * 0.6, y: step * 0.6)
        case .outline:
            shadow(color: .black, radius: 0, x: step, y: 0).shadow(color: .black, radius: 0, x: -step, y: 0)
                .shadow(color: .black, radius: 0, x: 0, y: step).shadow(color: .black, radius: 0, x: 0, y: -step)
        case .raised: shadow(color: .black.opacity(0.85), radius: 0, x: step, y: step)
        case .depressed: shadow(color: .black.opacity(0.85), radius: 0, x: -step, y: -step)
        }
    }
}

#if os(iOS)
/// `playerBleed` deliberately removes SwiftUI safe-area insets, so convert the actual window's
/// safe bottom into this overlay's coordinates. Inline/letterboxed pictures above it need no inset.
@MainActor func subtitleBottomInset(in proxy: GeometryProxy) -> CGFloat {
    guard let window = UIApplication.shared.appWindowScene?.windows.first(where: \.isKeyWindow) else { return proxy.safeAreaInsets.bottom }
    let safeBottom = window.bounds.maxY - window.safeAreaInsets.bottom
    return max(proxy.safeAreaInsets.bottom, max(0, proxy.frame(in: .global).maxY - safeBottom))
}
#endif
