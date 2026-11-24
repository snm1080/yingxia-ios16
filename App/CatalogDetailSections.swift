import SwiftUI
import Perception
import TVCore

#if os(iOS)
/// Home and source details share everything after the source's episode controls.
struct CatalogDetailSections: View {
    @Environment(Store.self) private var store
    @Environment(\.isLocalPageActive) private var pageActive
    @Environment(\.scenePhase) private var scenePhase
    let details: TMDBMatch.Details
    var presentationChanged: (Bool) -> Void = { _ in }
    @State private var still: CatalogDetailStill?
    @State private var calendarShown = false
    @State private var trailerOperation: Task<Void, Never>?
    @State private var trailerLoading = false
    @State private var trailerFailed = false

    private var item: TMDBCatalog.Item {
        TMDBCatalog.Item(id: details.id, mediaType: details.mediaType, name: details.name,
            originalName: details.originalName, year: details.year, overview: details.overview,
            poster: details.poster, backdrop: details.backdrop, rating: details.rating,
            genreIDs: details.genreItems?.map(\.id) ?? [], date: details.date)
    }
    private var credits: [TMDBMatch.Person] {
        details.cast + details.crew.filter { person in
            !details.cast.contains { actor in
                if let id = person.id, id > 0 { return actor.id == id }
                return actor.name == person.name
            }
        }
    }
    private var seasons: [TMDBMatch.SeasonSummary] { details.seasons.filter { $0.number > 0 } }
    private var presenting: Bool { still != nil || calendarShown || trailerLoading }

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 30) {
                if !credits.isEmpty { people }
                if let studios = details.studios, !studios.isEmpty { studioRail(studios) }
                if !details.genres.isEmpty || details.genreItems?.isEmpty == false { genres }
                if details.mediaType == .tv, !seasons.isEmpty || details.nextEpisode != nil { calendarAction }
                if let images = details.stills, !images.isEmpty { stillRail(images) }
                if details.playableTrailer != nil { trailer }
                facts
                if let recommendations = details.recommendations, !recommendations.isEmpty { related(recommendations) }
                Link(destination: details.link) { Label(L10n.text("View on TMDB"), systemImage: "arrow.up.right.square") }
                    .font(.system(size: 17)).frame(maxWidth: .infinity).padding(.vertical, 15)
                    .accessibilityIdentifier("discover.detail.tmdb")
            }
            .onAppear { presentationChanged(presenting) }
            .appOnChange(of: presenting) { _, value in presentationChanged(value) }
            .appOnChange(of: pageActive) { _, active in if !active { cancelTrailer() } }
            .onDisappear { cancelTrailer(); presentationChanged(false) }
            .sheet(item: $still) { selection in
                NavigationStack {
                    TMDBArtwork(url: selection.url, maxPixels: 2400, fill: false)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.black).ignoresSafeArea(edges: .bottom)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(L10n.text("Done")) { still = nil }
                            }
                        }
                }.preferredColorScheme(.dark)
            }
            .localGlassDialog(isPresented: $calendarShown, title: "播出日历", maxWidth: 510, layout: .calendar) {
                DiscoverBroadcastCalendarView(item: item, seasons: seasons, details: details)
            }
        }
    }

    private var people: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("主演与导演")
            DiscoverRail(arrowCenter: 41.5) {
                LazyHStack(alignment: .top, spacing: 13) {
                    ForEach(Array(credits.enumerated()), id: \.offset) { _, person in
                        if let id = person.id, id > 0 {
                            RouteLink { DiscoverPersonView(id: id, name: person.name, profile: person.profile) } label: { personCard(person) }
                                .buttonStyle(.plain).accessibilityIdentifier("discover.detail.person.\(id)")
                                .accessibilityLabel("查看\(person.name)的作品")
                        } else { personCard(person) }
                    }
                }.padding(.horizontal, 20)
            }
        }
    }
    private func personCard(_ person: TMDBMatch.Person) -> some View {
        VStack(spacing: 7) {
            PosterImage(url: person.profile, symbol: "person.fill").frame(width: 83, height: 83).clipShape(Circle())
            VStack(spacing: 2) {
                Text(person.name).font(.system(size: 17)).lineLimit(1)
                if let role = person.role { Text(role).font(.system(size: 15)).lineLimit(1).opacity(0.55) }
            }
        }.frame(width: 112).contentShape(Rectangle())
    }
    private func studioRail(_ studios: [TMDBMatch.Studio]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            heading(L10n.text("Studios & Networks"))
            DiscoverRail {
                HStack(spacing: 13) {
                    ForEach(Array(studios.enumerated()), id: \.offset) { _, studio in
                        if let id = studio.id, id > 0 {
                            RouteLink {
                                DiscoverBrowseView(title: studio.name, filter: .studio(id, type: studio.kind == "network" ? .tv : .movie), logo: studio.logo)
                            } label: { studioCard(studio) }
                            .buttonStyle(.plain).accessibilityIdentifier("discover.detail.studio.\(id)")
                            .accessibilityLabel("查看\(studio.name)的作品")
                        } else { studioCard(studio) }
                    }
                }.padding(.horizontal, 20)
            }
        }
    }
    private func studioCard(_ studio: TMDBMatch.Studio) -> some View {
        VStack(spacing: 10) {
            if let logo = studio.logo { TMDBArtwork(url: logo, maxPixels: 400, fill: false).frame(width: 100, height: 44) }
            else { Image(systemName: "film.stack").frame(width: 100, height: 44) }
            Text(studio.name).font(.system(size: 15)).lineLimit(1)
        }.padding(15).frame(width: 145).background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
    private var genres: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading(L10n.text("Genres"))
            DiscoverRail {
                HStack(spacing: 10) {
                    if let values = details.genreItems, !values.isEmpty {
                        ForEach(values) { genre in
                            RouteLink { DiscoverBrowseView(title: genre.name, filter: .genre(genre.id, type: details.mediaType)) } label: { genreChip(genre.name) }
                                .buttonStyle(.plain).accessibilityIdentifier("discover.detail.genre.\(genre.id)")
                                .accessibilityLabel("浏览\(genre.name)")
                        }
                    } else { ForEach(details.genres, id: \.self) { genreChip($0) } }
                }.padding(.horizontal, 20)
            }
        }
    }
    private func genreChip(_ name: String) -> some View {
        Text(name).font(.system(size: 18, weight: .medium)).padding(.horizontal, 20).padding(.vertical, 12)
            .background(.primary.opacity(0.08), in: Capsule())
    }
    private var calendarAction: some View {
        Button { calendarShown = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "calendar").font(.system(size: 20)).foregroundStyle(Brand.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("播出日历").font(.system(size: 19, weight: .semibold))
                    Text(details.nextEpisode.map { "第\($0.season)季 · 第\($0.number)集 · \($0.date)" } ?? "查看各季度的播出安排")
                        .font(.system(size: 16)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 18))
        }.buttonStyle(.plain).padding(.horizontal, 20).accessibilityIdentifier("discover.detail.calendar")
    }
    private func stillRail(_ images: [URL]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            heading(L10n.text("Stills"))
            DiscoverRail(arrowCenter: 73) {
                LazyHStack(spacing: 13) {
                    ForEach(images, id: \.self) { url in
                        DiscoverButton { still = CatalogDetailStill(url: url) } label: {
                            PosterImage(url: url).frame(width: 260, height: 146.25)
                                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                        }.buttonStyle(.plain).accessibilityLabel("查看剧照").accessibilityIdentifier("discover.detail.still")
                    }
                }.padding(.horizontal, 20)
            }
        }
    }
    private var trailer: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading(L10n.text("Trailer"))
            Button { playTrailer() } label: {
                PosterImage(url: details.backdrop ?? details.poster).frame(height: 210)
                    .overlay { Image(systemName: "play.fill").font(.system(size: 28)).frame(width: 64, height: 64).glassSurface(.regular, in: Circle()) }
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }.buttonStyle(.plain).disabled(trailerLoading).padding(.horizontal, 20)
                .accessibilityLabel("播放预告片").accessibilityIdentifier("discover.detail.trailer")
            if trailerLoading {
                HStack {
                    ProgressView(); Text("正在加载预告片…").font(.subheadline)
                    Spacer()
                    Button("取消") { cancelTrailer() }.frame(minHeight: 44)
                }.padding(.horizontal, 20)
            }
            if trailerFailed {
                HStack {
                    Text(L10n.text("Trailer Unavailable")).font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.text("Try Again")) { playTrailer() }.frame(minHeight: 44)
                }.padding(.horizontal, 20)
            }
        }
    }
    private func playTrailer() {
        guard pageActive, scenePhase == .active, !trailerLoading, let trailer = details.playableTrailer else { return }
        trailerOperation?.cancel(); trailerFailed = false; trailerLoading = true
        trailerOperation = Task {
            let stream = await DiscoverTrailerResolver.shared.resolve(trailer)
            guard !Task.isCancelled else { return }
            trailerLoading = false; trailerOperation = nil
            guard let stream else { trailerFailed = true; return }
            store.playing = Channel(name: details.name + " · " + L10n.text("Trailer"), url: stream.url, headers: stream.headers)
            PictureInPicture.shared.stop()
        }
    }
    private func cancelTrailer() {
        trailerOperation?.cancel(); trailerOperation = nil; trailerLoading = false
    }
    private var facts: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading(L10n.text("Information"))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 18) {
                fact(L10n.text("Original Title"), details.originalName)
                fact(L10n.text("Release Date"), details.date ?? "—")
                fact(L10n.text("Country / Region"), countries)
                fact(L10n.text("Status"), details.status.map { L10n.text($0) } ?? "—")
                if !details.crew.isEmpty { fact(L10n.text("Crew"), details.crew.map(\.name).joined(separator: " / ")) }
            }.padding(18).background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 20)).padding(.horizontal, 20)
        }
    }
    private var countries: String {
        let locale = Locale(identifier: TMDBMatch.language)
        return details.countries.map { locale.localizedString(forRegionCode: $0) ?? $0 }.joined(separator: " / ")
    }
    private func fact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 15)).opacity(0.55)
            Text(value.isEmpty ? "—" : value).font(.system(size: 18)).fixedSize(horizontal: false, vertical: true).selectable()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func related(_ items: [TMDBMatch.Candidate]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            heading(L10n.text("You May Like"))
            DiscoverRail(arrowCenter: 87) {
                LazyHStack(alignment: .top, spacing: 13) {
                    ForEach(items, id: \.key) { candidate in
                        RouteLink { DiscoverDetailView(item: candidate.catalogItem) } label: { DiscoverTile(item: candidate.catalogItem).frame(width: 116) }
                            .tmdbCardButton().accessibilityLabel(candidate.name)
                            .accessibilityIdentifier("discover.detail.related.\(candidate.key)")
                    }
                }.padding(.horizontal, 20)
            }
        }
    }
    private func heading(_ title: String) -> some View {
        Text(title).font(.system(size: 23, weight: .semibold)).padding(.horizontal, 20)
    }
}

private struct CatalogDetailStill: Identifiable { let url: URL; var id: URL { url } }

/// Sources without a TMDB match still retain their useful credits and metadata.
struct CatalogSourceDetailSections: View {
    let video: Video
    let sourceName: String
    private var metadata: LocalCatalogSourceMetadata { LocalCatalogSourceMetadata(video) }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if metadata.actor != nil || metadata.director != nil {
                VStack(alignment: .leading, spacing: 14) {
                    Text("主演与导演").font(.system(size: 23, weight: .semibold))
                    if let actor = metadata.actor { sourceFact("主演", actor) }
                    if let director = metadata.director { sourceFact("导演", director) }
                }
            }
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.text("Information")).font(.system(size: 23, weight: .semibold))
                sourceFact("作品", video.name)
                sourceFact("来源", SourceLabel(sourceName).text)
                if let year = metadata.year { sourceFact("年份", year) }
                if let area = metadata.area { sourceFact("地区", area) }
                if let type = metadata.type { sourceFact("类型", type) }
                if let remarks = metadata.remarks { sourceFact("资源信息", remarks) }
            }
        }
    }
    private func sourceFact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 15)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 18)).fixedSize(horizontal: false, vertical: true).selectable()
        }
    }
}
#endif
