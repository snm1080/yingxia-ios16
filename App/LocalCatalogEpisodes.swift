import SwiftUI
import TVCore

#if os(iOS)
struct LocalCatalogDetailEpisode: Identifiable {
    let episode: Episode
    let info: TMDBMatch.EpisodeInfo?
    let title: String
    let numberLabel: String?
    let fileDetail: String?
    let key: LocalCatalogDetailRules.EpisodeKey
    var id: Episode.ID { episode.id }

    static func entries(_ episodes: [Episode], metadata: [Episode.ID: TMDBMatch.EpisodeInfo], details: TMDBMatch.Details?,
                        sourceTitle: String, flag: String, fileDetails: [Episode.ID: String]) -> [Self] {
        let titleSeason = LocalCatalogDetailRules.numbers(flag).season ?? LocalCatalogDetailRules.numbers(sourceTitle).season ?? 1
        let movieTitle = details?.mediaType == .movie ? details?.name : nil
        return episodes.enumerated().map { index, episode in
            let numbers = LocalCatalogDetailRules.numbers(episode.name)
            let info = metadata[episode.id]
            let number = info?.number ?? numbers.episode
            let season = info == nil ? numbers.season ?? titleSeason : details?.season?.number ?? numbers.season ?? titleSeason
            let extra = LocalCatalogDetailRules.isExtra(episode.name)
            let prefix = season == 0 ? "特别篇 · " : season > 1 ? "第 \(season) 季 · " : ""
            let label = movieTitle == nil && !extra ? number.map { prefix + "第 \($0) 集" } : nil
            let title = movieTitle ?? (info?.name.isEmpty == false ? info!.name : episode.name)
            return Self(episode: episode, info: info, title: title, numberLabel: label, fileDetail: fileDetails[episode.id],
                        key: .init(index: index, season: season, number: number, extra: extra))
        }
    }
}

struct LocalCatalogDetailEpisodeCard: View {
    let value: LocalCatalogDetailEpisode
    let video: Video
    let movieArtwork: URL?
    let movie: Bool
    let loading: Bool
    private var size: String? { value.fileDetail?.components(separatedBy: " · ").last.flatMap { ["M", "G", "T"].contains(where: $0.hasSuffix) ? $0 : nil } }
    private var overview: String { value.info?.overview.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    private var artwork: URL? { movieArtwork ?? value.info?.still ?? video.poster }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if artwork != nil {
                Color.clear.aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .overlay { LocalCatalogEpisodeArtwork(primary: movieArtwork ?? value.info?.still, fallback: video.poster, headers: video.posterHeaders) }
                    .overlay {
                        if loading { ProgressView().tint(.white).padding(12).background(.black.opacity(0.5), in: Circle()) }
                        else { Image(systemName: "play.fill").font(.system(size: 17)).foregroundStyle(.white).padding(11).background(.black.opacity(0.35), in: Circle()) }
                    }
                    .overlay(alignment: .top) { badges.padding(8) }
                    .overlay(alignment: .bottomTrailing) {
                        if let runtime = value.info?.runtime, runtime.isFinite, runtime > 0 {
                            badge("\(Int(runtime)) 分钟").padding(8)
                        }
                    }.clipped()
            } else { badges.padding([.top, .horizontal], 9) }
            VStack(alignment: overview.isEmpty ? .center : .leading, spacing: 6) {
                Text(value.title).font(.system(size: 13, weight: .medium)).lineLimit(overview.isEmpty ? 2 : 1)
                    .frame(maxWidth: .infinity, alignment: overview.isEmpty ? .center : .leading)
                if movie, value.title != value.episode.name {
                    Text(value.episode.name).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
                if !overview.isEmpty { Text(overview).font(.system(size: 11)).lineSpacing(4).foregroundStyle(.secondary).lineLimit(3) }
            }.padding(.horizontal, 13).padding(.top, 12).padding(.bottom, 14)
        }
        .frame(width: 216, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 10)).contentShape(Rectangle())
    }
    private var badges: some View {
        HStack(alignment: .top, spacing: 6) {
            if let number = value.numberLabel { badge(number) }
            Spacer(minLength: 0)
            if let size { badge(size) }
        }
    }
    private func badge(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .medium)).monospacedDigit().lineLimit(1).foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 3).background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 5))
    }
}

/// Keep the source poster visible if a TMDB still is missing or its download/decoding fails.
/// Source-specific headers belong only to that source's poster, never to image.tmdb.org.
struct LocalCatalogEpisodeArtwork: View {
    let primary: URL?
    let fallback: URL?
    let headers: [String: String]
    @State private var loaded: CGImage?
    var body: some View {
        ZStack {
            PosterImage(url: fallback, headers: headers, symbol: "play.rectangle")
            if let loaded { Color.clear.overlay { Image(decorative: loaded, scale: 1).resizable().scaledToFill() } }
        }.clipped()
            .task(id: primary) {
                loaded = nil
                guard let primary, primary != fallback else { return }
                let image = await TMDBArtwork.load(primary, maxPixels: 720)
                guard !Task.isCancelled else { return }
                loaded = image
            }
    }
}

struct LocalCatalogDetailEpisodeRow: View {
    let value: LocalCatalogDetailEpisode
    let movie: Bool
    let loading: Bool
    var body: some View {
        HStack(spacing: 8) {
            if loading { ProgressView().controlSize(.small) } else { Image(systemName: "play.fill").font(.system(size: 12)) }
            VStack(alignment: .leading, spacing: 4) {
                Text(movie ? value.title : value.numberLabel ?? value.episode.name).font(.system(size: 13, weight: .medium)).lineLimit(2)
                if value.episode.name != (movie ? value.title : value.numberLabel ?? value.episode.name) {
                    Text(value.episode.name).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }.padding(12).frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(.primary.opacity(0.09), lineWidth: 0.5) }
            .contentShape(Rectangle())
    }
}
#endif
