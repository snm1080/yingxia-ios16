import SwiftUI
import Perception
import TVCore

/// The same fixed artwork placeholder appears for missing and failed images. The readable title
/// stays outside the image, as on MacCat, including records whose old title was a share URL.
struct HistoryPoster: View {
    @Environment(Store.self) private var store
    let entry: PlaybackHistoryEntry
    private var image: URL? {
        PosterPresentation.imageURL(entry.context.poster,
                                    excluding: [entry.context.origin.absoluteString, entry.context.videoID, entry.context.episodeID])
    }
    var body: some View {
        WithPerceptionTracking {
            PosterImage(url: image, headers: image == nil ? [:] : entry.context.posterHeaders ?? [:], symbol: "pawprint.fill")
                .accessibilityHidden(true)
                .task(id: entry.context) {
                    await HistoryArtworkRecovery.restore(entry, store: store)
                }
        }
    }
}

@MainActor private enum HistoryArtworkRecovery {
    /// This path only reads artwork retained for the exact original origin/source/video identity.
    /// The general TMDB cache uses merged display keys, which can change owners after subscription
    /// reordering. It cannot safely repair history that has no retained work identity.
    static func restore(_ entry: PlaybackHistoryEntry, store: Store) async {
        let context = entry.context
        let push = await Task.detached(priority: .utility) {
            PushMediaLibrary.shared.record(origin: context.origin, sourceKey: context.sourceKey, videoID: context.videoID)
        }.value
        guard !Task.isCancelled else { return }
        if let artwork = push?.artwork {
            let decidedAt = artwork.confirmedAt ?? .distantPast
            if let current = context.artworkDecisionDate, current >= decidedAt { return }
            if artwork.isConfirmed == false {
                store.playbackHistory.resetArtwork(for: context, poster: artwork.poster, headers: artwork.headers,
                                                   onlyIfUnchanged: true, decidedAt: decidedAt)
            } else if let poster = artwork.poster {
                store.playbackHistory.updateArtwork(for: context, poster: poster, headers: artwork.headers,
                                                    onlyIfUnchanged: true, decidedAt: decidedAt)
            }
            return
        }
        if context.artworkDecisionDate == nil, let hint = push?.metadataHint, hint.id > 0,
           let poster = PosterPresentation.imageURL(hint.poster, excluding: [context.videoID, context.episodeID]) {
            store.playbackHistory.updateArtwork(for: context, poster: poster, headers: hint.posterHeaders ?? [:], onlyIfUnchanged: true)
            return
        }
    }
}
