import Foundation

/// Local speech generation does not require a remote service or an API key.
public struct AISubtitleRecognitionSettings: Equatable, Sendable {
    public let onlineEnabled: Bool
    public let mode: String
    public let locale: String
    // Capture provider settings too, so an in-flight result cannot outlive a language/service edit.
    public let serviceIdentity: [String]
    public init(onlineEnabled: Bool, mode: String, locale: String, serviceIdentity: [String] = []) {
        self.onlineEnabled = onlineEnabled; self.mode = mode
        self.serviceIdentity = serviceIdentity
        let locale = locale.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "_", with: "-")
        self.locale = locale.isEmpty ? "zh-CN" : locale
    }
    public var isLocal: Bool { mode == "local" }
    public var canGenerate: Bool { isLocal || onlineEnabled && ["chat", "transcription"].contains(mode) }
    public var canTranslate: Bool { onlineEnabled }
    public struct Request: Equatable, Sendable {
        public let generate: Bool, translate: Bool, denied: Bool
    }
    /// Turning a control off always works. A stale invalid control is cleared,
    /// and an unavailable new request never enables its independent neighbour.
    public func request(currentGenerate: Bool, currentTranslate: Bool,
                        generate: Bool?, translate: Bool?) -> Request {
        Request(generate: (generate ?? currentGenerate) && canGenerate,
                translate: (translate ?? currentTranslate) && canTranslate,
                denied: generate == true && !canGenerate || translate == true && !canTranslate)
    }
    public static func translationCandidates(generate: Bool, generated: [AISubtitleTimeline.Cue],
                                             primary: [AISubtitleTimeline.Cue], position: Double) -> [AISubtitleTimeline.Cue] {
        guard position.isFinite, position >= 0 else { return [] }
        // Keep the chosen source stable while a generated window is empty.
        return (generate ? generated : primary).filter { $0.end > position && $0.start < position + 30 }.prefix(12).map { $0 }
    }

}

public enum LocalSpeechSubtitles {
    /// The range uses UTF-16 offsets within the formatted transcript.
    public struct Segment: Sendable {
        public let text: String, timestamp: Double, duration: Double
        public let range: NSRange
        public init(text: String, timestamp: Double, duration: Double, range: NSRange) {
            self.text = text; self.timestamp = timestamp; self.duration = duration; self.range = range
        }
    }
    /// Speech timestamps are relative to the extracted audio. Preserve the formatted transcript's
    /// punctuation and spacing, then split at sentence boundaries, pauses, or short readable groups.
    public static func cues(transcript: String, segments: [Segment], position: Double, duration: Double) -> [AISubtitleTimeline.Cue] {
        guard position.isFinite, position >= 0, duration.isFinite, duration > 0, duration <= 30,
              transcript.utf8.count <= 65536, segments.count <= 1024 else { return [] }
        let string = transcript as NSString
        func validRange(_ range: NSRange) -> Bool {
            range.location >= 0 && range.location <= string.length && range.length >= 0 && range.length <= string.length - range.location
        }
        func text(_ group: [Segment]) -> String {
            guard let first = group.first, let last = group.last else { return "" }
            if group.allSatisfy({ validRange($0.range) }), last.range.location >= first.range.location {
                let range = NSRange(location: first.range.location, length: last.range.location + last.range.length - first.range.location)
                if validRange(range) { return string.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            return group.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: " ")
        }
        let valid = segments.filter {
            $0.timestamp.isFinite && $0.duration.isFinite && $0.duration > 0 && $0.timestamp + $0.duration > 0 &&
                $0.timestamp < duration && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.text.utf8.count <= 65536
        }.sorted { $0.timestamp < $1.timestamp }
        var result: [AISubtitleTimeline.Cue] = [], group: [Segment] = []
        func finish() {
            guard let first = group.first else { return }
            let start = max(0, first.timestamp), end = min(duration, group.map { $0.timestamp + $0.duration }.max() ?? start)
            let content = text(group)
            if end > start && !content.isEmpty { result.append(.init(start: position + start, end: position + end, text: content)) }
            group.removeAll(keepingCapacity: true)
        }
        for segment in valid {
            if let first = group.first, let previous = group.last,
               segment.timestamp - (previous.timestamp + previous.duration) >= 0.65 ||
                segment.timestamp + segment.duration - first.timestamp > 3.2 || text(group).count >= 64 { finish() }
            group.append(segment)
            if let last = segment.text.trimmingCharacters(in: .whitespacesAndNewlines).last, ".!?。！？".contains(last) { finish() }
        }
        finish()
        return result
    }

    /// MacCat's sherpa tokens use SentencePiece word boundaries and relative seconds.
    /// Synthetic pre-roll is excluded by `base`; every cue is clipped to real sampled audio.
    public static func tokenCues(transcript: String, tokens: [String], timestamps: [Double],
                                 base: Double, end: Double, position: Double) -> [AISubtitleTimeline.Cue] {
        guard position.isFinite, position >= 0, base.isFinite, end.isFinite, end > max(0, base), end <= 20,
              transcript.utf8.count <= 65536, tokens.count <= 2048 else { return [] }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let fallback = [AISubtitleTimeline.Cue(start: position + max(0, base), end: position + end, text: text)]
        guard !tokens.isEmpty, tokens.count == timestamps.count,
              timestamps.allSatisfy({ $0.isFinite && $0 >= 0 }),
              zip(timestamps, timestamps.dropFirst()).allSatisfy({ $0 <= $1 }) else { return fallback }
        // Byte-fallback token strings are debug spellings, not display text. The
        // native recognizer already decoded them in its formatted transcript.
        if tokens.contains(where: { $0.hasPrefix("<0x") && $0.hasSuffix(">") }) { return fallback }
        struct Word { var text: String; let start: Double; var last: Double; let cjk: Bool }
        var words: [Word] = [], boundary = false
        for (value, stamp) in zip(tokens, timestamps) {
            let token = value.replacingOccurrences(of: "▁", with: " ")
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { boundary = boundary || token.contains(" "); continue }
            let cjk = token.unicodeScalars.contains { (0x3400...0x9fff).contains($0.value) || (0x3040...0x30ff).contains($0.value) }
            if words.isEmpty || boundary || token.hasPrefix(" ") || cjk {
                words.append(Word(text: trimmed, start: base + stamp, last: base + stamp, cjk: cjk))
            } else {
                words[words.count - 1].text += trimmed; words[words.count - 1].last = base + stamp
            }
            boundary = false
        }
        var cues: [AISubtitleTimeline.Cue] = [], group: [Word] = []
        func emit(until finish: Double) {
            guard let first = group.first else { return }
            let start = max(0, first.start), finish = min(end, finish)
            if finish > start {
                var joined = ""
                for (index, word) in group.enumerated() {
                    if index > 0 && !(word.cjk && group[index - 1].cjk) { joined += " " }
                    joined += word.text
                }
                cues.append(.init(start: position + start, end: position + finish, text: joined))
            }
            group.removeAll(keepingCapacity: true)
        }
        for word in words {
            if let first = group.first,
               word.start - first.start >= 3.2 || group.reduce(0, { $0 + $1.text.count + 1 }) + word.text.count > 65 {
                emit(until: word.start)
            }
            group.append(word)
        }
        if let last = group.last { emit(until: last.last + 0.35) }
        return cues
    }
}
