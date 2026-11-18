import SwiftUI
import Perception
import TVCore

struct LocalSitePageTitle: ViewModifier {
    let title: String
    func body(content: Content) -> some View {
        #if os(iOS)
        content.navigationTitle("").navigationBarTitleDisplayMode(.inline)
        #else
        content.screenTitle(title)
        #endif
    }
}

#if os(iOS)
struct LocalSiteActionsSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let site: Site
    let origin: URL
    let refresh: () -> Void

    var body: some View {
        WithPerceptionTracking {
            RouteStack {
                ScrollView {
                    WithPerceptionTracking {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(SourceLabel(site.name).text).font(.headline).padding(.horizontal, 16).padding(.bottom, 8)
                            Button(action: refresh) { Label("刷新站点", systemImage: "arrow.clockwise") }
                                .accessibilityIdentifier("site.actions.refresh")
                            PinSourceButton(site: site, origin: origin)
                            HideSourceButton(site: site, origin: origin)
                            RouteLink { LocalSourceSettingsView(kind: store.localSourceGroup(for: site)) } label: { Label("站点设置", systemImage: "slider.horizontal.3") }
                                .accessibilityIdentifier("site.actions.settings")
                        }
                        .buttonStyle(LocalSiteActionRowStyle())
                        .padding(16)
                    }
                }
                .navigationTitle("站点操作").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("关闭") { dismiss() }.accessibilityIdentifier("site.actions.close")
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }
}

private struct LocalSiteActionRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.body)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 3)
            .contentShape(Rectangle())
            .background(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.04), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// A two-column source picker keeps the whole tile tappable, including a long source name.
struct LocalSourcePanelTile: View {
    @Environment(Store.self) private var store
    let site: Site
    var dimmed = false
    var chosen: Bool? = nil

    var body: some View {
        WithPerceptionTracking {
            HStack(spacing: 9) {
                SourceIcon(site: site, label: SourceLabel(site.name), size: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text(SourceLabel(site.name).text).font(.subheadline.weight(.semibold)).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if site.runtime == .python {
                        Text(store.health(of: site) == .failing ? "待重试" : store.health(of: site) == .healthy ? "就绪" : "待机")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if chosen == true { Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.accent) }
            }
            .padding(10).frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .opacity(dimmed ? 0.45 : 1)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("source." + site.key)
        }
    }
}

struct LocalSitePosterCard: View {
    let video: Video
    let landscape: Bool
    private var badges: SourcePosterBadges {
        SourcePosterBadges(year: video.year, category: video.category, remarks: video.remarks)
    }
    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 8) {
                Color.clear.aspectRatio(landscape ? 16.0 / 9.0 : 2.0 / 3.0, contentMode: .fit)
                    .overlay { PosterImage(url: PosterPresentation.imageURL(video.poster, excluding: [video.id]), headers: video.posterHeaders) }
                    .overlay(alignment: .topLeading) { badgeRow(Array(badges.top.prefix(2))) }
                    .overlay(alignment: .bottomLeading) {
                        badgeRow(Array(badges.bottom.prefix(3)))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text(video.name).font(.headline.weight(.semibold)).foregroundStyle(.primary)
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            }.contentShape(Rectangle())
        }
    }
    private func badgeRow(_ values: [String]) -> some View {
        Group {
            if landscape { HStack(spacing: 4) { badgeChips(values) } }
            else { LocalCatalogTagFlow(spacing: 4) { badgeChips(values) } }
        }.padding(8).allowsHitTesting(false)
    }
    private func badgeChips(_ values: [String]) -> some View {
        Group {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                Text(value).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    .foregroundStyle(.white.opacity(0.94))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Color(white: 0.07).opacity(0.72), in: RoundedRectangle(cornerRadius: 4))
            }
        }
    }
}

struct LocalSiteFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    let filters: [CategoryFilter]
    let choices: [String: String]
    let choose: ([String: String]) -> Void
    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        ForEach(filters) { filter in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(filter.name).font(.headline)
                                LocalCatalogTagFlow(spacing: 8) {
                                    ForEach(filter.options, id: \.value) { option in
                                        let selected = choices[filter.key] == option.value
                                        Button {
                                            var next = choices
                                            if selected { next.removeValue(forKey: filter.key) }
                                            else { next[filter.key] = option.value }
                                            choose(next)
                                        } label: {
                                            Text(option.name)
                                        }
                                        .buttonStyle(LocalGlassButtonStyle(prominent: selected, wrapsLabel: true))
                                        .accessibilityAddTraits(selected ? .isSelected : [])
                                        .accessibilityIdentifier("site.filter." + filter.key + "." + option.value)
                                    }
                                }
                            }
                        }
                        HStack {
                            Button("重置") { choose([:]) }
                                .buttonStyle(LocalGlassButtonStyle())
                                .accessibilityIdentifier("site.filters.reset")
                            Spacer()
                            Button("完成") { dismiss() }
                                .buttonStyle(LocalGlassButtonStyle(prominent: true))
                        }
                        .padding(.top, 8)
                    }.padding(20).localDialogContentHeight()
                }
            }
        }
    }
}

enum LocalCatalogDetailArtwork {
    static func images(video: Video, details: TMDBMatch.Details?) -> [URL] {
        var seen = Set<URL>()
        // Portraits lead the carousel, matching the home detail's text-free cover.
        // Older deployed services supply heroPoster/poster but no posters array.
        let portraits = [details?.heroPoster, details?.poster].compactMap { $0 } + (details?.posters ?? [])
        let fallback = [video.poster, details?.backdrop].compactMap { $0 } + (details?.stills ?? [])
        return Array((portraits + fallback).filter { seen.insert($0).inserted }.prefix(16))
    }
}

/// Source fields sometimes contain an entire pasted metadata block. Keep that text in the overview,
/// while pills and credit labels use only the first bounded field, as MacCat does.
struct LocalCatalogSourceMetadata {
    let year: String?
    let area: String?
    let type: String?
    let remarks: String?
    let director: String?
    let actor: String?
    let overview: String

    init(_ video: Video) {
        let labels = "制片国家[/／]地区|国家[/／]地区|上映日期|首播日期|豆瓣评分|剧情简介|影片简介|资源信息|官方网站|单集片长|导演|編劇|编剧|主演|演员|类型|年份|地区|语言|語言|首播|季数|集数|片长|又名|IMDb|简介"
        func lines(_ value: String) -> String {
            value.replacingOccurrences(of: "[ \\t]+(?=(?:\(labels))\\s*[:：])", with: "\n", options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func compact(_ value: String) -> String { value.components(separatedBy: .whitespacesAndNewlines).joined() }
        var description = lines(video.synopsis)
        func field(_ value: String?, label: String, ownLabels: String, limit: Int, credit: Bool = false) -> String? {
            let original = lines(value ?? "")
            let text = original.replacingOccurrences(of: "^(?:\(ownLabels))\\s*[:：]\\s*", with: "", options: [.regularExpression, .caseInsensitive])
            let boundary = text.range(of: "\n(?:\(labels))\\s*[:：]", options: [.regularExpression, .caseInsensitive])
            let candidate = String(text[..<(boundary?.lowerBound ?? text.endIndex)]).trimmingCharacters(in: .whitespacesAndNewlines)
            let result = candidate.components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: " / ")
            let readable = result.count <= limit && (!credit || result.components(separatedBy: CharacterSet(charactersIn: ",，、/;；")).allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).count <= 96 })
            if !original.isEmpty, (boundary != nil || !readable), !compact(description).contains(compact(original)) {
                description += (description.isEmpty ? "" : "\n\n") + "\(label)：\(original)"
            }
            return readable && !result.isEmpty ? result : nil
        }
        year = field(video.year, label: "年份", ownLabels: "年份|上映日期|首播日期", limit: 32)
        area = field(video.area, label: "地区", ownLabels: "制片国家[/／]地区|国家[/／]地区|地区", limit: 80)
        type = field(video.category, label: "类型", ownLabels: "类型", limit: 80)
        remarks = field(video.remarks, label: "备注", ownLabels: "备注", limit: 80)
        director = field(video.director, label: "导演", ownLabels: "导演", limit: 1024, credit: true)
        actor = field(video.actor, label: "主演", ownLabels: "主演|演员", limit: 2048, credit: true)
        overview = description
    }
}

/// The same portrait paint as Discover's home detail; image rotation never starts a trailer or playback.
struct LocalCatalogArtworkCarousel: View {
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isLocalPageActive) private var pageActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let video: Video
    let images: [URL]
    var presented = true
    @Binding var selection: Int
    @Binding var paused: Bool
    @Binding var paint: DiscoverPaint?
    @State private var visible = false

    private var current: Int { images.isEmpty ? 0 : max(0, selection) % images.count }
    private var address: URL? { images.isEmpty ? nil : images[current] }
    private var active: Bool { visible && presented && pageActive && scenePhase == .active && store.playing == nil && store.music.track == nil }
    private var rotation: String { "\(active)|\(paused)|\(reduceMotion)|\(current)|\(images)" }

    var body: some View {
        WithPerceptionTracking {
            GeometryReader { geometry in
                WithPerceptionTracking {
                    DiscoverBackdrop(paint: paint, width: geometry.size.width, heroHeight: geometry.size.height,
                                     scrollY: 0, trailer: nil, playsTrailer: false)
                        .allowsHitTesting(false)
                }
            }
            .onAppear { visible = true }
            .onDisappear { visible = false }
            .appOnChange(of: images) { _, _ in selection = 0 }
            .task(id: address) {
                guard let address else { paint = nil; return }
                let headers = address == video.poster ? video.posterHeaders : [:]
                let requested = await DiscoverPainter.shared.paint(address, headers: headers)
                guard !Task.isCancelled else { return }
                let loaded: DiscoverPaint?
                if let requested { loaded = requested }
                else if let source = video.poster, source != address { loaded = await DiscoverPainter.shared.paint(source, headers: video.posterHeaders) }
                else { loaded = nil }
                guard let loaded, !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) { paint = loaded }
            }
            .task(id: rotation) {
                guard active, !paused, !reduceMotion, images.count > 1 else { return }
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                selection = (current + 1) % images.count
            }
        }
    }
}

struct LocalCatalogArtworkControls: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let count: Int
    @Binding var selection: Int
    @Binding var paused: Bool
    let choose: () -> Void
    private var current: Int { count > 0 ? max(0, selection) % count : 0 }
    var body: some View {
        HStack(spacing: 0) {
            if count > 1 {
                Button { selection = (current + count - 1) % count } label: { Image(systemName: "chevron.left").frame(width: 40, height: 44).iosTouchTarget() }
                    .accessibilityLabel("上一张海报")
                Button(action: choose) { Text("\(current + 1)/\(count)").font(.caption.monospacedDigit()).frame(minWidth: 44, minHeight: 44) }
                    .accessibilityLabel("手动切换海报，第 \(current + 1) 张，共 \(count) 张").accessibilityIdentifier("detail.artwork.choose")
                Button { selection = (current + 1) % count } label: { Image(systemName: "chevron.right").frame(width: 40, height: 44).iosTouchTarget() }
                    .accessibilityLabel("下一张海报")
                if !reduceMotion {
                    Button { paused.toggle() } label: { Image(systemName: paused ? "play.fill" : "pause.fill").frame(width: 40, height: 44).iosTouchTarget() }
                        .accessibilityLabel(paused ? "播放海报轮播" : "暂停海报轮播")
                }
            } else {
                Button(action: choose) { Image(systemName: "photo.on.rectangle.angled").frame(width: 44, height: 44) }
                    .accessibilityLabel("手动切换海报").accessibilityIdentifier("detail.artwork.choose").disabled(count == 0)
            }
        }
        .font(.caption.weight(.semibold)).buttonStyle(.plain)
    }
}

struct LocalCatalogPosterPicker: View {
    @Environment(\.dismiss) private var dismiss
    let images: [URL]
    let video: Video
    @Binding var selection: Int
    @Binding var paused: Bool
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 115), spacing: 12)], spacing: 12) {
                    ForEach(Array(images.enumerated()), id: \.element) { index, address in
                        Button {
                            selection = index
                            paused = true
                            dismiss()
                        } label: {
                            Color.clear.aspectRatio(2.0 / 3.0, contentMode: .fit)
                                .overlay { PosterImage(url: address, headers: address == video.poster ? video.posterHeaders : [:]) }
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(alignment: .topTrailing) {
                                    if selection == index { Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, Brand.accent).padding(8) }
                                }
                        }.buttonStyle(.plain).accessibilityLabel("使用第 \(index + 1) 张海报")
                    }
                }.padding(20)
            }
            .navigationTitle("手动切换海报").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.presentationDetents([.medium, .large])
    }
}

/// Both detail entry points use the home detail's logo slot and its text fallback.
struct LocalCatalogDetailTitle: View {
    let title: String
    let logo: URL?
    let width: CGFloat
    @State private var logoAspect: CGFloat?
    var body: some View {
        Group {
            if let logo {
                TMDBArtwork(url: logo, maxPixels: 1000, fill: false, aspect: $logoAspect)
                    .frame(width: min(width * 0.82, 440), height: 116)
                    .overlay { if logoAspect == nil { titleText } }
                    .id(logo).accessibilityLabel(title)
            } else { titleText }
        }.frame(maxWidth: .infinity)
    }
    private var titleText: some View {
        Text(title).font(.system(size: 38, weight: .semibold))
            .multilineTextAlignment(.center).lineLimit(3).minimumScaleFactor(0.6)
            .frame(minHeight: 70).accessibilityAddTraits(.isHeader)
    }
}

/// Mirrors MacCat's FilmMetadataPills: source year/area win, values deduplicate, language stays visible.
struct LocalCatalogMetadataPills: View {
    let details: TMDBMatch.Details?
    var item: TMDBCatalog.Item? = nil
    var year: String? = nil
    var area: String? = nil
    var remarks: String? = nil
    var calendar: (() -> Void)? = nil
    private var releaseYear: String? { clean(year) ?? details?.year.map(String.init) ?? item?.year.map(String.init) }
    private var tags: [String] {
        let seasons = details?.seasons.filter { $0.number > 0 } ?? []
        let episodeCount = details?.episodeCount.flatMap { $0 > 0 ? $0 : nil } ?? seasons.reduce(0) { $0 + $1.episodeCount }
        let count = seasons.isEmpty ? nil : "\(seasons.count)季" + (episodeCount > 0 ? " \(episodeCount)集" : "")
        let locale = Locale(identifier: TMDBMatch.language)
        let countries = details?.countries.map { locale.localizedString(forRegionCode: $0) ?? $0 }.joined(separator: " / ")
        let runtime = details?.runtime.flatMap { $0 > 0 && $0.isFinite ? "\(NSNumber(value: $0).stringValue) min" : nil }
        let values: [String?] = [releaseYear, runtime, count, clean(area) ?? clean(countries), clean(details?.originalLanguage)?.uppercased()]
            + (details?.genres ?? []).map(Optional.some) + [remarks]
        var seen = Set<String>()
        return values.compactMap(clean).filter { seen.insert($0).inserted }
    }
    var body: some View {
        LocalCatalogTagFlow(spacing: 6) {
            if let rating = details?.rating ?? item?.rating, rating > 0, rating.isFinite {
                Label(rating.formatted(.number.precision(.fractionLength(1))), systemImage: "star.fill")
                    .foregroundStyle(Brand.amber).modifier(LocalCatalogFilmPill(highlight: true))
            }
            if let type = details?.mediaType ?? item?.mediaType, let id = details?.id ?? item?.id {
                LocalDoubanRatingPill(mediaType: type, id: id)
            }
            ForEach(tags, id: \.self) { tag in
                Text(tag).fontWeight(tag == releaseYear ? .semibold : .regular).modifier(LocalCatalogFilmPill())
            }
            if details?.mediaType == .tv, let calendar {
                Button(action: calendar) {
                    HStack(spacing: 5) { Image(systemName: "calendar"); Text(calendarLabel); Image(systemName: "chevron.right").font(.system(size: 10)) }
                        .lineLimit(1).fixedSize(horizontal: true, vertical: true)
                        .modifier(LocalCatalogFilmPill())
                        .frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityIdentifier("detail.calendar")
                .accessibilityLabel("播出日历：\(calendarLabel)")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var calendarLabel: String {
        guard let next = details?.nextEpisode, LocalCatalogDetailRules.date(next.date) != nil,
              next.date >= LocalCatalogDetailRules.dateKey(Date()) else { return "暂无排期" }
        return "\(next.date.suffix(5)) · 第\(next.number)集"
    }
    private func clean(_ value: String?) -> String? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

/// Optional metadata is loaded independently; failure never blocks details or playback.
private struct LocalDoubanRatingPill: View {
    let mediaType: TMDBMatch.MediaType
    let id: Int
    @State private var score: DoubanRating.Score?
    @State private var scoreKey = ""
    private var key: String { "\(mediaType.rawValue):\(id)" }
    var body: some View {
        Group {
            if scoreKey == key, let score {
                Text(L10n.text("Douban") + " " + score.value.formatted(.number.precision(.fractionLength(1))))
                    .foregroundStyle(.green).modifier(LocalCatalogFilmPill(highlight: true))
                    .accessibilityLabel("豆瓣评分 \(score.value.formatted(.number.precision(.fractionLength(1))))，\(score.count) 人评价")
            } else { Color.clear.frame(width: 0, height: 0).accessibilityHidden(true) }
        }
        .task(id: key) {
            score = nil; scoreKey = key
            let value = await DoubanRating.score(tmdbID: id, mediaType: mediaType)
            guard !Task.isCancelled else { return }
            score = value
        }
    }
}

private struct LocalCatalogFilmPill: ViewModifier {
    var highlight = false
    func body(content: Content) -> some View {
        content.font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background((highlight ? Brand.amber : Color.primary).opacity(highlight ? 0.12 : 0.08), in: Capsule())
            .overlay { Capsule().strokeBorder((highlight ? Brand.amber : Color.primary).opacity(highlight ? 0.45 : 0.22), lineWidth: 1) }
    }
}

struct LocalCatalogSynopsisButton: View {
    let overview: String
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            HStack(alignment: .center, spacing: 12) {
                Text(overview).font(.system(size: 14)).lineSpacing(5).lineLimit(3)
                    .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.system(size: 16)).foregroundStyle(Brand.accent)
            }.foregroundStyle(Color.primary.opacity(0.78)).frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("查看完整简介").accessibilityIdentifier("detail.overview")
    }
}

struct LocalCatalogSynopsisSheet: View {
    let title: String
    let overview: String
    var sourceOverview = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(title).font(.title2.bold())
                Text(overview).lineSpacing(5).selectable()
                if !sourceOverview.isEmpty {
                    Text("来源资料").font(.headline)
                    Text(sourceOverview).foregroundStyle(.secondary).lineSpacing(5).selectable()
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                .localDialogContentHeight()
        }.accessibilityIdentifier("detail.synopsis.content")
    }
}

struct LocalCatalogEpisodePoster: View {
    let name: String
    let sourceName: String
    let info: TMDBMatch.EpisodeInfo?
    let fileDetail: String?
    let video: Video
    let loading: Bool
    private var size: String? {
        fileDetail?.components(separatedBy: " · ").last.flatMap { value in
            ["M", "G", "T"].contains(where: value.hasSuffix) ? value : nil
        }
    }
    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 7) {
                Color.clear.aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .overlay {
                        PosterImage(url: info?.still ?? video.poster, headers: info?.still == nil ? video.posterHeaders : [:], symbol: "play.rectangle")
                    }
                    .overlay {
                        if loading { ProgressView().tint(.white).padding(12).background(.black.opacity(0.5), in: Circle()) }
                        else { Image(systemName: "play.fill").font(.title3).foregroundStyle(.white).padding(12).background(.black.opacity(0.35), in: Circle()) }
                    }
                    .overlay(alignment: .top) {
                        HStack(alignment: .top, spacing: 5) {
                            badge(name)
                            Spacer(minLength: 0)
                            if let size { badge(size) }
                        }.padding(6)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if let runtime = info?.runtime, runtime > 0 { badge("\(Int(runtime)) 分钟").padding(6) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text(info?.name.isEmpty == false ? info!.name : name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(fileDetail ?? (sourceName != name ? sourceName : " ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
    }
    private func badge(_ text: String) -> some View {
        Text(text).font(.caption2.weight(.semibold)).lineLimit(1).foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 4).background(.black.opacity(0.65), in: Capsule())
    }
}

struct LocalCatalogMetadataSections: View {
    let details: TMDBMatch.Details
    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 24) {
                if !details.cast.isEmpty { people(details.cast, title: "演员") }
                if !details.crew.isEmpty { people(details.crew, title: "导演与主创") }
                if let studios = details.studios, !studios.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("制作公司").font(.headline)
                        LocalCatalogTagFlow(spacing: 8) {
                            ForEach(Array(studios.enumerated()), id: \.offset) { _, studio in
                                if let id = studio.id, id > 0 {
                                    RouteLink {
                                        WithPerceptionTracking { DiscoverBrowseView(title: studio.name, filter: .studio(id, type: studio.kind == "network" ? .tv : .movie), logo: studio.logo) }
                                    } label: { Text(studio.name).modifier(LocalCatalogFilmPill()).frame(minHeight: 44).contentShape(Rectangle()) }
                                    .buttonStyle(.plain).accessibilityLabel("查看\(studio.name)的作品")
                                } else { Text(studio.name).modifier(LocalCatalogFilmPill()) }
                            }
                        }
                    }
                }
                if let genres = details.genreItems, !genres.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("类型").font(.headline)
                        LocalCatalogTagFlow(spacing: 8) {
                            ForEach(genres) { genre in
                                RouteLink {
                                    WithPerceptionTracking { DiscoverBrowseView(title: genre.name, filter: .genre(genre.id, type: details.mediaType)) }
                                } label: { Text(genre.name).modifier(LocalCatalogFilmPill()).frame(minHeight: 44).contentShape(Rectangle()) }
                                .buttonStyle(.plain).accessibilityLabel("浏览\(genre.name)")
                            }
                        }
                    }
                }
                TMDBInfoGrid(details: details)
                if let related = details.recommendations, !related.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("猜你喜欢").font(.headline)
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top, spacing: 12) {
                                ForEach(related, id: \.key) { title in
                                    RouteLink { DiscoverDetailView(item: item(title)) } label: { TMDBCandidateTile(candidate: title) }
                                        .buttonStyle(.plain).accessibilityLabel(title.name)
                                }
                            }
                        }.scrollIndicators(.hidden)
                    }
                }
            }
        }
    }
    private func people(_ values: [TMDBMatch.Person], title: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(Array(values.enumerated()), id: \.offset) { _, person in
                        if let id = person.id, id > 0 {
                            RouteLink { WithPerceptionTracking { DiscoverPersonView(id: id, name: person.name, profile: person.profile) } } label: { castCard(person) }
                                .buttonStyle(.plain).accessibilityLabel("查看\(person.name)的作品")
                        } else { castCard(person) }
                    }
                }
            }.scrollIndicators(.hidden)
        }
    }
    private func castCard(_ person: TMDBMatch.Person) -> some View {
        VStack(spacing: 6) {
            PosterImage(url: person.profile, symbol: "person.fill").frame(width: 74, height: 74).clipShape(Circle())
            Text(person.name).font(.caption.weight(.semibold)).lineLimit(1)
            Text(person.role ?? " ").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }.frame(width: 86).contentShape(Rectangle())
    }
    private func item(_ candidate: TMDBMatch.Candidate) -> TMDBCatalog.Item {
        TMDBCatalog.Item(id: candidate.id, mediaType: candidate.mediaType, name: candidate.name,
                         originalName: candidate.originalName ?? candidate.name, year: candidate.year,
                         overview: candidate.overview ?? "", poster: candidate.poster, backdrop: nil, rating: nil, genreIDs: [])
    }
}

struct LocalCatalogTag: ViewModifier {
    func body(content: Content) -> some View {
        content.font(.caption.weight(.medium)).lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.primary.opacity(0.06), in: Capsule())
    }
}

/// Tags retain their natural width and wrap without a horizontal scrolling strip.
struct LocalCatalogTagFlow: SwiftUI.Layout {
    let spacing: CGFloat
    var alignment: HorizontalAlignment = .leading
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(subviews, width: proposal.width ?? 320).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(subviews, width: bounds.width)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                                 anchor: .topLeading,
                                 proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }
    private func layout(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, frames: [CGRect]) {
        let available = max(width, 1)
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        var frames: [CGRect] = []
        var rowStart = 0
        func finishRow() {
            let rowWidth = max(0, x - spacing)
            let inset = alignment == .trailing ? available - rowWidth : alignment == .center ? (available - rowWidth) / 2 : 0
            for index in rowStart..<frames.count {
                frames[index].origin.x += inset
                frames[index].origin.y += (rowHeight - frames[index].height) / 2
            }
        }
        for view in subviews {
            let natural = view.sizeThatFits(.unspecified)
            let itemWidth = min(natural.width, available)
            let size = view.sizeThatFits(ProposedViewSize(width: itemWidth, height: nil))
            if x > 0 && x + itemWidth > available {
                finishRow()
                x = 0; y += rowHeight + spacing; rowHeight = 0; rowStart = frames.count
            }
            frames.append(CGRect(x: x, y: y, width: itemWidth, height: size.height))
            x += itemWidth + spacing; rowHeight = max(rowHeight, size.height)
        }
        finishRow()
        return (CGSize(width: available, height: y + rowHeight), frames)
    }
}
#endif
