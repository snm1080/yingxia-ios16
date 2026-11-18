import SwiftUI
import Perception
import TVCore

/// The week page behind Discover's Airing Today shelves (TMDBCalendar): anime, or series by region, one day at a
/// time, as Discover's own poster grid with the air time and episode under each cover. On the TV it is laid out as
/// the See All pages there are, with the filters as menu chips.
struct DiscoverCalendarView: View {
    #if os(iOS)
    @Environment(\.isLocalGlassDialog) private var glassDialog
    #endif
    @State private var weeks: [String: TMDBCalendar.Week]
    @State private var failed = Set<String>()
    @State private var kind: TMDBCalendar.Kind
    @State private var region = TMDBCalendar.Region.preferred
    /// The day picked, by date; today until the viewer picks another.
    @State private var picked: [String: String] = [:]

    init(initial: [TMDBCalendar.Kind: TMDBCalendar.Week] = [:], kind: TMDBCalendar.Kind = .anime) {
        var weeks: [String: TMDBCalendar.Week] = [:]
        if let anime = initial[.anime] { weeks[Self.key(.anime, .preferred)] = anime }
        if let series = initial[.tv] { weeks[Self.key(.tv, .preferred)] = series }
        _weeks = State(initialValue: weeks)
        _kind = State(initialValue: kind)
    }

    private static func key(_ kind: TMDBCalendar.Kind, _ region: TMDBCalendar.Region) -> String { kind == .anime ? "anime" : "tv|\(region.rawValue)" }
    private var key: String { Self.key(kind, region) }
    private var week: TMDBCalendar.Week? { weeks[key] }
    private var date: String? { picked[key] ?? week?.today()?.date ?? week?.days.first?.date }
    private var day: TMDBCalendar.Day? { week?.days.first { $0.date == date } }
    private var isToday: Bool { day != nil && day?.date == week?.today()?.date }
    private var next: String? { isToday ? day.flatMap { DiscoverAiring.next($0.items) } : nil }
    private var dateBinding: Binding<String> { Binding(get: { date ?? "" }, set: { picked[key] = $0 }) }

    var body: some View {
        WithPerceptionTracking {
            content
                #if os(iOS)
                .localGlassBackdrop()
                .foregroundStyle(.primary)
                #else
                .background { WithPerceptionTracking { DiscoverCanvas(poster: day?.items.first?.cover) } }
                .foregroundStyle(.white).preferredColorScheme(.dark)
                #endif
                .task(id: key) { if weeks[key] == nil { await load() } }
        }
    }

    #if os(tvOS)
    private static var width: CGFloat { 6 * 224 + 5 * 51 }
    private var content: some View {
        GeometryReader { proxy in
            WithPerceptionTracking {
            ScrollView {
                WithPerceptionTracking {
                    VStack(spacing: 0) {
                        Text(L10n.text("Airing Schedule")).font(.system(size: 52, weight: .semibold)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                            .frame(maxWidth: .infinity).padding(.top, 60)
                        HStack(spacing: 20) {
                            chip(L10n.text("Content Type"), value: $kind, options: TMDBCalendar.Kind.allCases, title: \.title)
                            if kind == .tv {
                                chip(L10n.text("Region"), value: $region, options: TMDBCalendar.Region.allCases, title: \.title)
                            }
                            if let week {
                                chip(L10n.text("Day"), value: dateBinding, options: week.days.map(\.date)) { DiscoverAiring.dayName($0, in: week) }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 56).focusSection()
                        if let day, !day.items.isEmpty {
                            LazyVGrid(columns: Array(repeating: GridItem(.fixed(224), spacing: 51, alignment: .top), count: 6), spacing: 66) {
                                WithPerceptionTracking {
                                    ForEach(day.items) { item in
                                        WithPerceptionTracking {
                                            DiscoverAiringLink(item: item) { DiscoverAiringTile(item: item, next: item.id == next, width: 224) }
                                                .accessibilityIdentifier("calendar.item.\(item.id)")
                                        }
                                    }
                                }
                            }.padding(.top, 54)
                        }
                        status.padding(40)
                        // At the foot of the page however few titles the day has.
                        Spacer(minLength: 0)
                        if let week { DiscoverCalendarCredits(week: week) }
                    }
                    .frame(width: Self.width).frame(maxWidth: .infinity)
                    .padding(.bottom, 80)
                    .frame(minHeight: proxy.size.height, alignment: .top)
                }
            }
            .appScrollClipDisabled()
            }
        }
        .ignoresSafeArea(edges: .top)
        .toolbar(.hidden, for: .navigationBar)
    }

    /// A filter as a chip that opens a menu, as on Browse and the person page.
    private func chip<Value: Hashable>(_ title: String, value: Binding<Value>, options: [Value], title name: @escaping (Value) -> String) -> some View {
        Menu {
            WithPerceptionTracking {
                Picker(title, selection: value) { ForEach(options, id: \.self) { perceptionArgument0 in WithPerceptionTracking { Text(name(perceptionArgument0)).tag(perceptionArgument0) } } }
            }
        } label: {
            WithPerceptionTracking {
                let shown = name(value.wrappedValue)
                Text(TMDBMatch.language.hasPrefix("zh") ? "\(title)：\(shown)" : "\(title): \(shown)")
            }
        }
        .menuStyle(.button)
        .buttonStyle(DiscoverTVChipStyle(active: false))
    }
    private func chip<Value: Hashable>(_ title: String, value: Binding<Value>, options: [Value], title name: KeyPath<Value, String>) -> some View {
        chip(title, value: value, options: options) { $0[keyPath: name] }
    }
    #else
    private var content: some View {
        GeometryReader { proxy in
            WithPerceptionTracking {
            ScrollView {
                WithPerceptionTracking {
                    VStack(alignment: .leading, spacing: 12) {
                        kindRegionStrip
                        dayStrip
                        itemsGrid
                        status.frame(maxWidth: .infinity)
                        if let week { DiscoverCalendarCredits(week: week).padding(.horizontal, DiscoverLayout.gutter) }
                    }
                    .padding(.vertical, DiscoverLayout.gutter)
                    #if os(iOS)
                    .frame(minHeight: glassDialog ? nil : proxy.size.height, alignment: .top)
                    .localDialogContentHeight()
                    #else
                    .frame(minHeight: proxy.size.height, alignment: .top)
                    #endif
                }
            }
            }
        }
        .navigationTitle(L10n.text("Airing Schedule"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar(glassDialog ? .hidden : .visible, for: .navigationBar)
        #endif
    }

    // The three strips below were extracted verbatim from `content` — as one
    // expression the iOS branch exceeded the Swift 6.1 type-checker budget.
    private var kindRegionStrip: some View {
        ScrollView(.horizontal) {
            WithPerceptionTracking {
                HStack(spacing: 8) {
                    ForEach(TMDBCalendar.Kind.allCases, id: \.self) { value in
                        WithPerceptionTracking {
                            calendarChip(value.title, selected: kind == value) { kind = value }
                                .accessibilityIdentifier("calendar.kind.\(value.rawValue)")
                        }
                    }
                    if kind == .tv {
                        Divider().frame(height: 18).padding(.horizontal, 4)
                        ForEach(TMDBCalendar.Region.allCases, id: \.self) { value in
                            WithPerceptionTracking {
                                calendarChip(value.title, selected: region == value) { region = value }
                                    .accessibilityIdentifier("calendar.region.\(value.rawValue)")
                            }
                        }
                    }
                }.padding(.horizontal, DiscoverLayout.gutter)
            }
        }.scrollIndicators(.hidden)
    }

    @ViewBuilder private var dayStrip: some View {
        if let week {
            ScrollView(.horizontal) {
                WithPerceptionTracking {
                    HStack(spacing: 8) {
                        ForEach(week.days) { value in
                            WithPerceptionTracking {
                                calendarChip(DiscoverAiring.dayName(value.date, in: week), selected: value.date == date) { picked[key] = value.date }
                                    .accessibilityIdentifier("calendar.day.\(value.weekday)")
                            }
                        }
                    }.padding(.horizontal, DiscoverLayout.gutter)
                }
            }.scrollIndicators(.hidden)
        }
    }

    @ViewBuilder private var itemsGrid: some View {
        if let day, !day.items.isEmpty {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: DiscoverLayout.posterWidth), spacing: DiscoverLayout.spacing)], alignment: .leading, spacing: 22) {
                WithPerceptionTracking {
                    ForEach(day.items) { item in
                        WithPerceptionTracking {
                            DiscoverAiringLink(item: item) { DiscoverAiringTile(item: item, next: item.id == next) }
                                .accessibilityIdentifier("calendar.item.\(item.id)")
                        }
                    }
                }
            }
            .padding(.horizontal, DiscoverLayout.gutter).padding(.top, 8)
        }
    }
    #endif

    #if !os(tvOS)
    @ViewBuilder private func calendarChip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        #if os(iOS)
        Button(action: action) {
            Text(title).font(.subheadline.weight(selected ? .semibold : .medium))
                .lineLimit(1).padding(.horizontal, 14).frame(minHeight: 44)
                .foregroundStyle(selected ? Brand.onAccent : .primary)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(LinearGradient(colors: [Brand.accent, Brand.accent.opacity(0.78)], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .shadow(color: Brand.accent.opacity(0.22), radius: 5, x: 2, y: 3)
                    }
                }
                .localGlassInputSurface(cornerRadius: 14)
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        #else
        DiscoverChip(title: title, selected: selected, action: action)
        #endif
    }
    #endif

    @ViewBuilder private var status: some View {
        if let week {
            if week.stale {
                Label(L10n.text("The schedule sources can't be reached right now, so this is an older copy."), systemImage: "clock.arrow.circlepath")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if day?.items.isEmpty ?? true { EmptyResults(symbol: "calendar", title: L10n.text("Nothing Airing")) }
        } else if failed.contains(key) {
            EmptyResults(symbol: "calendar.badge.exclamationmark", title: L10n.text("Couldn't load the airing schedule."),
                         message: L10n.text("Please try again later."), action: L10n.text("Try Again")) { Task { await load() } }
        } else {
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 80)
        }
    }

    private func load() async {
        let (key, kind, region) = (key, kind, region)
        failed.remove(key)
        do { weeks[key] = try await TMDBCalendar.week(kind, region: region) } catch {
            guard !(error is CancellationError) else { return }
            Diagnostics.shared.record(.warning, "calendar", "calendar=\(key) failed=\(String(reflecting: error))")
            failed.insert(key)
        }
    }
}

/// Where an item of today stands against now, and how its time and day read.
enum DiscoverAiring {
    static func next(_ items: [TMDBCalendar.Item], now: Date = Date()) -> String? {
        items.filter { ($0.airDate ?? .distantPast) > now }.min { $0.airDate! < $1.airDate! }?.id
    }

    /// For a shelf: from the last one that aired, so it opens on what's next; all of it once everything has aired.
    static func fromNow(_ items: [TMDBCalendar.Item], now: Date = Date()) -> [TMDBCalendar.Item] {
        guard let next = next(items, now: now), let index = items.firstIndex(where: { $0.id == next }) else { return items }
        return Array(items[max(0, index - 1)...])
    }

    /// 24-hour in every language: a 12-hour clock without AM/PM put midnight (12:00) before 01:00.
    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
    static func time(_ item: TMDBCalendar.Item) -> String? { item.airDate.map { clock.string(from: $0) } }

    /// The line under a cover: the time and episode, else the network, else the rating.
    static func caption(_ item: TMDBCalendar.Item) -> String {
        let parts = [time(item), item.episode.map { L10n.text("Episode %@", String($0)) }].compactMap { $0 }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        if let network = item.network ?? item.links.first?.name { return network }
        return item.rating.map { "★ " + $0.formatted(.number.precision(.fractionLength(1))) } ?? " "
    }

    /// The page an airing title opens: its TMDB detail page, or for an anime TMDB's list doesn't name, the TMDB title
    /// found by its name.
    @MainActor @ViewBuilder static func destination(_ item: TMDBCalendar.Item) -> some View {
        if let work = item.tmdb { DiscoverDetailView(item: item.catalogItem(work)) } else { DiscoverAiringTitleView(item: item) }
    }

    #if os(tvOS)
    /// A title for the TV's native shelf.
    static func entry(_ item: TMDBCalendar.Item, next: Bool) -> DiscoverTVNativeShelf.Entry {
        DiscoverTVNativeShelf.Entry(key: item.id, title: item.title, detail: caption(item), image: item.cover, highlight: next)
    }
    #endif

    /// "Today", else the weekday and day of the month ("Sun 8", "周日 8").
    static func dayName(_ date: String, in week: TMDBCalendar.Week) -> String {
        if date == week.today()?.date { return L10n.text("Today") }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: week.timeZone) ?? .current
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let value = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)) else { return date }
        var style = Date.FormatStyle(locale: Locale(identifier: L10n.resolvedLanguage())).weekday(.abbreviated)
        style.timeZone = calendar.timeZone
        return "\(value.formatted(style)) \(parts[2])"
    }
}

/// A cover as Discover draws its titles, with the air time and episode as the caption and a badge on the next one
/// to air.
struct DiscoverAiringTile: View {
    let item: TMDBCalendar.Item
    var next = false
    var width: CGFloat = DiscoverLayout.posterWidth
    var body: some View {
        WithPerceptionTracking {
            #if os(tvOS)
            VStack(spacing: 5) {
                // The badge is painted into the cover, so it lifts with it.
                PosterImage(url: item.cover, symbol: "tv").frame(width: width, height: width * 1.5)
                    .coverOverlay(alignment: .topLeading) { WithPerceptionTracking { badge.padding(12) } }
                VStack(spacing: 0) {
                    Text(item.title).font(.system(size: DiscoverLayout.caption))
                    Text(DiscoverAiring.caption(item)).font(.system(size: DiscoverLayout.secondary, weight: .medium))
                        .foregroundStyle(next ? Brand.accent : Color.secondary)
                }.lineLimit(1).cardCaption()
            }.frame(width: width)
            #else
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.aspectRatio(2.0 / 3, contentMode: .fit)
                    .overlay { WithPerceptionTracking { PosterImage(url: item.cover, symbol: "tv") } }
                    .posterClip(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay { WithPerceptionTracking { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5) } }
                    .overlay(alignment: .topLeading) { WithPerceptionTracking { badge.padding(6) } }
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(.system(size: DiscoverLayout.caption)).lineLimit(1)
                    Text(DiscoverAiring.caption(item)).lineLimit(1)
                        .font(.system(size: DiscoverLayout.secondary, design: .rounded)).monospacedDigit()
                        .foregroundStyle(next ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(.primary.opacity(0.56)))
                }.frame(maxWidth: .infinity, alignment: .leading).frame(height: DiscoverLayout.captionHeight)
            }
            .accessibilityElement(children: .combine)
            #endif
        }
    }

    @ViewBuilder private var badge: some View {
        if next {
            Text(L10n.text("Airs Next"))
                #if os(tvOS)
                .font(.system(size: 20, weight: .bold)).padding(.horizontal, 12).padding(.vertical, 5)
                #else
                .font(.system(size: 10, weight: .bold)).padding(.horizontal, 6).padding(.vertical, 2)
                #endif
                .foregroundStyle(Brand.onAccent).background(Brand.accent, in: Capsule())
        }
    }
}

/// Opens an airing title: its TMDB detail page, or for an anime TMDB's list doesn't name, the TMDB title found by
/// its name.
struct DiscoverAiringLink<Label: View>: View {
    #if os(iOS)
    @Environment(\.isLocalGlassDialog) private var glassDialog
    @Environment(\.openRoute) private var openRoute
    #endif
    let item: TMDBCalendar.Item
    @ViewBuilder let label: Label
    var body: some View {
        WithPerceptionTracking {
            #if os(iOS)
            if glassDialog {
                Button {
                    openRoute?(Route { AnyView(DiscoverAiring.destination(item)) })
                } label: { WithPerceptionTracking { label } }
                    .tmdbCardButton()
            } else { navigationLink }
            #else
            navigationLink
            #endif
        }
    }

    private var navigationLink: some View {
        RouteLink { WithPerceptionTracking { DiscoverAiring.destination(item) } } label: { WithPerceptionTracking { label } }
        #if os(tvOS)
        .cardButton()
        #else
        .tmdbCardButton()
        #endif
    }
}

/// An anime without a TMDB ID opens as the TMDB series of the same name. Without one it keeps the calendar's
/// card, and Search Sources looks for it by name.
struct DiscoverAiringTitleView: View {
    @Environment(Store.self) private var store
    let item: TMDBCalendar.Item
    @State private var match: TMDBCatalog.Item?
    @State private var looked = false
    var body: some View {
        WithPerceptionTracking {
            Group {
                if let match { DiscoverDetailView(item: match) }
                else if looked { card }
                else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
            .task(id: item.id) {
                guard !looked else { return }
                match = await find()
                looked = true
            }
        }
    }

    private func find() async -> TMDBCatalog.Item? {
        let names = Set([item.title, item.originalTitle].map(Self.normal).filter { !$0.isEmpty })
        for query in [item.originalTitle, item.title] where !query.isEmpty {
            guard let results = try? await TMDBMatch.search(query), !Task.isCancelled else { continue }
            let series = results.filter { $0.mediaType == .tv }
            if let exact = series.first(where: { names.contains(Self.normal($0.name)) || names.contains(Self.normal($0.originalName ?? "")) }) {
                return exact.catalogItem
            }
        }
        return nil
    }
    private static func normal(_ name: String) -> String { name.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation } }

    private var card: some View {
        ScrollView {
            WithPerceptionTracking {
                VStack(spacing: 16) {
                    PosterImage(url: item.cover, symbol: "tv").frame(width: 220, height: 330).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    Text(item.title).font(.title2.weight(.semibold)).multilineTextAlignment(.center)
                    if item.originalTitle != item.title { Text(item.originalTitle).font(.headline).opacity(0.7) }
                    Text(DiscoverAiring.caption(item)).font(.subheadline).opacity(0.6)
                    DiscoverFindSourcesButton(title: item.title).padding(.top, 8).accessibilityIdentifier("calendar.findSources")
                }.padding(40).frame(maxWidth: .infinity)
            }
        }
        .background { WithPerceptionTracking { DiscoverCanvas(poster: item.cover) } }
        .foregroundStyle(.white).preferredColorScheme(.dark)
    }
}

/// Search Sources (Add Subscription without one) as the detail page draws it: a white capsule, or the TV's
/// action button.
struct DiscoverFindSourcesButton: View {
    @Environment(Store.self) private var store
    let title: String
    var body: some View {
        WithPerceptionTracking {
            Button {
                if store.subscription == nil { store.section = .settings } else { store.searchVideos(title) }
            } label: {
                Label(L10n.text(store.subscription == nil ? "Add Subscription" : "Search Sources"), systemImage: "magnifyingglass")
                    #if os(tvOS)
                    .frame(width: 380)
                    #else
                    .font(.system(size: 15, weight: .semibold)).frame(width: 260).frame(height: 50)
                    .foregroundStyle(Color.black).background(Color.white, in: Capsule()).contentShape(Capsule())
                    #endif
            }
            #if os(tvOS)
            .buttonStyle(DiscoverTVActionStyle(height: 86, font: 30))
            #else
            .buttonStyle(.plain)
            #endif
        }
    }
}

#if !os(tvOS)
/// A filter pill as Discover's search filters draw them.
struct DiscoverChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        WithPerceptionTracking {
            #if os(macOS)
            Button(action: action) {
                Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular)).lineLimit(1)
                    .padding(.horizontal, 14).frame(height: 28)
                    .foregroundStyle(selected ? Brand.onAccent : Color.primary)
                    .background(selected ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(.primary.opacity(0.08)), in: Capsule())
                    .contentShape(Capsule())
            }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
            #else
            Button(action: action) {
                Text(title).font(.system(size: 15)).lineLimit(1)
                    .padding(.horizontal, 16).frame(height: 36)
                    .foregroundStyle(selected ? Color.black : Color.primary)
                    .background { WithPerceptionTracking { if selected { Capsule().fill(Color.white) } } }
                    .glassSurface(selected ? .identity : .regular, in: Capsule())
            }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
            #endif
        }
    }
}
#endif

/// Whom the data comes from, as their licenses ask.
private struct DiscoverCalendarCredits: View {
    let week: TMDBCalendar.Week
    var body: some View {
        WithPerceptionTracking {
            if !week.attribution.isEmpty {
                HStack(spacing: 4) {
                    Text(L10n.text("Data:"))
                    ForEach(Array(week.attribution.enumerated()), id: \.offset) { index, credit in
                        WithPerceptionTracking {
                            if index > 0 { Text("·") }
                            #if os(tvOS)
                            Text(credit.name)
                            #else
                            Link(credit.name, destination: credit.url)
                            #endif
                        }
                    }
                }
                #if os(tvOS)
                .font(.system(size: 22))
                #else
                .font(.caption2)
                #endif
                .foregroundStyle(.secondary).padding(.top, 12)
            }
        }
    }
}

extension TMDBCalendar.Kind {
    var title: String { self == .anime ? L10n.text("Anime") : L10n.text("TV Series") }
    /// Discover's shelf of today's titles.
    var shelfTitle: String { self == .anime ? L10n.text("Anime Airing Today") : L10n.text("Series Airing Today") }
}

extension TMDBCalendar.Region {
    var title: String {
        switch self {
        case .cn: L10n.text("Chinese Series")
        case .hktw: L10n.text("Hong Kong & Taiwan Series")
        case .us: L10n.text("American Series")
        case .jp: L10n.text("Japanese Series")
        case .kr: L10n.text("Korean Series")
        case .gb: L10n.text("British Series")
        }
    }
}

extension TMDBCalendar.Item {
    /// Enough of a catalog card for the detail page, which loads the rest itself.
    func catalogItem(_ work: TMDBCalendar.Work) -> TMDBCatalog.Item {
        TMDBCatalog.Item(id: work.id, mediaType: work.type, name: title, originalName: originalTitle, year: nil, overview: overview ?? "",
                         poster: cover, backdrop: nil, rating: rating, genreIDs: [])
    }
}
