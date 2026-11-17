import Foundation

/// The episode and saved progress used by a detail page's play action.
public struct DetailPlaybackSelection: Sendable {
    public let episode: Episode?
    public let history: PlaybackHistoryEntry?
    public var readingProgress: ReadingHistoryProgress? {
        guard let value = history?.context.readingProgress, value.isValid else { return nil }
        return value
    }
    public var canResume: Bool { readingProgress != nil || position(for: .resume) != nil }

    public init(episodes: [Episode], activeFlag: String, selectedEpisode: Episode? = nil,
                history: [PlaybackHistoryEntry] = []) {
        let line = episodes.filter { $0.flag == activeFlag }
        // A source can contain thousands of episodes. Resolve identities once by name instead
        // of scanning the entire line for every saved history entry on each SwiftUI update.
        let named = Dictionary(grouping: line, by: \.name)
        func match(_ name: String, id: String, flag: String) -> Episode? {
            guard flag == activeFlag, let matches = named[name] else { return nil }
            return matches.first { $0.id == id } ?? (matches.count == 1 ? matches.first : nil)
        }
        let lineHistory = history.filter { match($0.context.episodeName, id: $0.context.episodeID, flag: $0.context.episodeFlag) != nil }
        let selected = selectedEpisode.flatMap { selected -> Episode? in
            match(selected.name, id: selected.id, flag: selected.flag)
        }
        let target = selected ?? lineHistory.first?.continuation(in: line) ?? line.first
        self.episode = target
        self.history = target.flatMap { episode in
            lineHistory.first {
                match($0.context.episodeName, id: $0.context.episodeID, flag: $0.context.episodeFlag) == episode
            }
        }
    }

    public func position(for mode: PlaybackResumeMode) -> Double? {
        guard let episode else { return nil }
        if mode == .beginning { return 0 }
        if readingProgress != nil, history?.completed == true { return 0 }
        return history?.resumePosition(for: episode)
    }
}
