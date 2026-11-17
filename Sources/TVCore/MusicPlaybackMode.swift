import Foundation

/// The three modes exposed by the iPhone/iPad player's single mode button.
public enum MusicPlaybackMode: String, Codable, Sendable {
    case repeatOne, sequential, random

    /// Catalog/Python listening shares the audio engine but has its own preference.
    public enum Domain: Sendable {
        case music, listening
        var key: String { self == .music ? "musicPlaybackMode" : "listeningPlaybackMode" }
        public var repeatKey: String { self == .music ? "musicRepeat" : "listeningRepeat" }
    }

    public var next: MusicPlaybackMode {
        switch self {
        case .repeatOne: .sequential
        case .sequential: .random
        case .random: .repeatOne
        }
    }

    public var symbol: String {
        switch self {
        case .repeatOne: "repeat.1"
        case .sequential: "text.line.first.and.arrowtriangle.forward"
        case .random: "shuffle"
        }
    }

    public var label: String {
        switch self {
        case .repeatOne: "单曲循环"
        case .sequential: "顺序播放"
        case .random: "随机播放"
        }
    }

    public static func load(_ defaults: UserDefaults = .standard, domain: Domain = .music) -> MusicPlaybackMode {
        if let raw = defaults.string(forKey: domain.key), let mode = Self(rawValue: raw) { return mode }
        // Older music preferences must never migrate into a listening queue.
        return defaults.string(forKey: domain.repeatKey) == "one" ? .repeatOne : .sequential
    }

    public func save(_ defaults: UserDefaults = .standard, domain: Domain = .music) {
        defaults.set(rawValue, forKey: domain.key)
    }
}
