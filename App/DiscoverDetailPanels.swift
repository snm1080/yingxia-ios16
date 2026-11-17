import SwiftUI
import Perception
import TVCore

#if os(iOS)
struct DiscoverMetadataPill: ViewModifier {
    func body(content: Content) -> some View {
        content.font(.caption.weight(.medium)).padding(.horizontal, 11).frame(height: 32)
            .background(.primary.opacity(0.08), in: Capsule())
    }
}

/// iOS 16's Layout API lets metadata and history chips wrap without a horizontal scroll trap.
struct DiscoverMetadataFlow: SwiftUI.Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        positions(width: proposal.width ?? .infinity, subviews: subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = positions(width: bounds.width, subviews: subviews)
        for (index, point) in layout.points.enumerated() {
            subviews[index].place(at: .init(x: bounds.minX + point.x, y: bounds.minY + point.y),
                                 proposal: ProposedViewSize(width: min(bounds.width, subviews[index].sizeThatFits(.unspecified).width), height: nil))
        }
    }
    private func positions(width: CGFloat, subviews: Subviews) -> (points: [CGPoint], size: CGSize) {
        var x: CGFloat = 0, y: CGFloat = 0, height: CGFloat = 0, widest: CGFloat = 0
        var points: [CGPoint] = []
        for view in subviews {
            let natural = view.sizeThatFits(.unspecified)
            let size = view.sizeThatFits(ProposedViewSize(width: min(width, natural.width), height: nil))
            if x > 0 && x + size.width > width { x = 0; y += height + spacing; height = 0 }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing; height = max(height, size.height); widest = max(widest, x - spacing)
        }
        return (points, CGSize(width: widest, height: y + height))
    }
}

struct DiscoverInlinePersonWorks: View {
    let id: Int
    let name: String
    let close: () -> Void
    @State private var profile: TMDBCatalog.PersonProfile?
    @State private var loading = true
    @State private var failed = false
    @State private var revision = 0
    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("\(name) · 相关作品").font(.headline)
                    Spacer()
                    Button(action: close) { Image(systemName: "xmark").frame(width: 44, height: 44) }
                        .buttonStyle(.plain).accessibilityLabel("收起演员作品").accessibilityIdentifier("discover.personWorks.close")
                }
                if loading { ProgressView("正在加载相关作品…").frame(maxWidth: .infinity).padding(.vertical, 20) }
                else if failed { Button("加载失败，重试") { revision += 1 }.frame(minHeight: 44) }
                else if let profile, !profile.works.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 13) {
                            ForEach(Array(profile.works.prefix(30))) { work in
                                RouteLink { DiscoverDetailView(item: work.item) } label: {
                                    DiscoverTile(item: work.item).frame(width: 116)
                                }.tmdbCardButton().accessibilityIdentifier("discover.personWorks.item.\(work.id)")
                            }
                        }.padding(.vertical, 4)
                    }
                } else { Text("暂无相关作品").font(.subheadline).foregroundStyle(.secondary) }
            }.padding(16).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 22))

                .task(id: "\(id):\(revision)") {
                    loading = true; failed = false; profile = nil
                    do {
                        let value = try await TMDBCatalog.person(id)
                        guard !Task.isCancelled else { return }
                        profile = value; loading = false
                    } catch { if !Task.isCancelled { failed = true; loading = false } }
                }
        }
    }
}

struct DiscoverBroadcastCalendarView: View {
    let item: TMDBCatalog.Item
    let seasons: [TMDBMatch.SeasonSummary]
    let details: TMDBMatch.Details?
    @State private var number: Int?
    @State private var month: Date
    @State private var episodes: [TMDBMatch.EpisodeInfo] = []
    @State private var loading = true
    @State private var failed = false
    @State private var revision = 0
    private var calendar: Calendar { Calendar(identifier: .gregorian) }
    private var today: String { LocalCatalogDetailRules.dateKey(Date()) }
    private var monthKey: String { String(LocalCatalogDetailRules.dateKey(month).prefix(7)) }
    private var year: Int { calendar.component(.year, from: month) }
    private var monthNumber: Int { calendar.component(.month, from: month) }
    private var days: Int { calendar.range(of: .day, in: .month, for: month)?.count ?? 30 }
    private var offset: Int { calendar.component(.weekday, from: month) - 1 }
    private var schedule: [String: [Int]] {
        var result = [String: [Int]]()
        for episode in episodes {
            guard let date = episode.airDate, LocalCatalogDetailRules.date(date) != nil else { continue }
            result[date, default: []].append(episode.number)
        }
        if let next = details?.nextEpisode, next.season == number, LocalCatalogDetailRules.date(next.date) != nil {
            result[next.date, default: []].append(next.number)
        }
        return result
    }
    private var networks: [TMDBMatch.Studio] {
        (details?.broadcastNetworks ?? details?.studios?.filter { $0.kind == "network" } ?? []).filter { $0.logo != nil }
    }

    init(item: TMDBCatalog.Item, seasons: [TMDBMatch.SeasonSummary], initialSeason: Int? = nil, details: TMDBMatch.Details? = nil) {
        self.item = item; self.seasons = seasons; self.details = details
        let today = LocalCatalogDetailRules.dateKey(Date())
        let next = details?.nextEpisode.flatMap { $0.date >= today && LocalCatalogDetailRules.date($0.date) != nil ? $0 : nil }
        _number = State(initialValue: next?.season ?? initialSeason ?? seasons.last?.number)
        let first = next.flatMap { LocalCatalogDetailRules.date($0.date) } ?? Date()
        _month = State(initialValue: Calendar(identifier: .gregorian).date(from: Calendar(identifier: .gregorian).dateComponents([.year, .month], from: first)) ?? first)
    }

    var body: some View {
        WithPerceptionTracking {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .center, spacing: 12) {
                        Text(item.name).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if !networks.isEmpty {
                            LocalCatalogTagFlow(spacing: 6, alignment: .trailing) {
                                ForEach(Array(networks.enumerated()), id: \.offset) { _, network in
                                    if let logo = network.logo {
                                        DiscoverBroadcastNetworkLogo(url: logo, name: network.name, id: network.id)
                                    }
                                }
                            }.frame(maxWidth: 180, alignment: .trailing)
                                .accessibilityElement(children: .contain).accessibilityLabel("播出平台")
                                .accessibilityIdentifier("discover.calendar.networks")
                        }
                    }
                    HStack(spacing: 12) {
                        Button { changeMonth(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                            .accessibilityLabel("上个月").disabled(year <= 1900 && monthNumber == 1)
                        Spacer(minLength: 0)
                        Text("\(String(year))年\(monthNumber)月").font(.system(size: 21, weight: .semibold)).lineLimit(1)
                            .accessibilityIdentifier("discover.calendar.month")
                        Spacer(minLength: 0)
                        Button { changeMonth(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                            .accessibilityLabel("下个月").disabled(year >= 2200 && monthNumber == 12)
                    }.buttonStyle(.plain)
                    HStack(spacing: 12) {
                        if seasons.count > 1 {
                            Picker("播出季度", selection: $number) {
                                ForEach(seasons, id: \.number) { season in Text(season.name.isEmpty ? "第\(season.number)季" : season.name).tag(Optional(season.number)) }
                            }.pickerStyle(.menu).labelsHidden().accessibilityIdentifier("discover.calendar.season")
                        } else {
                            Text(seasons.first?.name.isEmpty == false ? seasons.first!.name : number.map { "第\($0)季" } ?? "尚未公布季度")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Button("回到本月") { month = calendar.date(from: calendar.dateComponents([.year, .month], from: Date())) ?? Date() }
                            .font(.system(size: 12)).frame(minHeight: 44).accessibilityIdentifier("discover.calendar.today")
                    }.padding(.top, -8)
                    if loading { ProgressView("正在读取播出安排…").frame(maxWidth: .infinity).padding(.vertical, 20) }
                    else if failed {
                        VStack(spacing: 8) {
                            Text("播出安排暂时不可用").font(.subheadline).foregroundStyle(.secondary)
                            Button("重试") { revision += 1 }.frame(minHeight: 44)
                        }.frame(maxWidth: .infinity)
                    } else { calendarGrid }
                    Text("按 TMDB 公布的播出日期显示，实际资源更新时间可能不同。")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
                }.padding(18).frame(maxWidth: 470)
                    .frame(maxWidth: .infinity)
                    .localDialogContentHeight()
            }
            .accessibilityIdentifier("discover.calendar")
            .task(id: "\(number ?? -1):\(revision)") { await load() }
        }
    }
    private var calendarGrid: some View {
        let dates = schedule
        return VStack(spacing: 12) {
            HStack(spacing: 4) {
                ForEach(["日", "一", "二", "三", "四", "五", "六"], id: \.self) { day in
                    Text("周\(day)").font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }.accessibilityHidden(true)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2, alignment: .top), count: 7), spacing: 4) {
                ForEach(0..<offset, id: \.self) { _ in Color.clear.frame(height: 58) }
                ForEach(1...days, id: \.self) { day in dayCell(day, schedule: dates) }
            }.accessibilityLabel("\(String(year))年\(monthNumber)月播出安排")
            if !dates.keys.contains(where: { $0.hasPrefix(monthKey) }) {
                Text("本月暂无已公布的播出安排").font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
        }
    }
    private func dayCell(_ day: Int, schedule: [String: [Int]]) -> some View {
        let date = "\(monthKey)-\(String(format: "%02d", day))"
        let values = schedule[date] ?? []
        let label = LocalCatalogDetailRules.episodeRange(values)
        return VStack(spacing: 5) {
            Text("\(day)").font(.system(size: 16, weight: .semibold)).frame(width: 34, height: 30)
                .background(values.isEmpty ? Color.clear : Brand.accent.opacity(0.28), in: RoundedRectangle(cornerRadius: 9))
                .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(values.isEmpty ? Color.clear : Brand.accent.opacity(0.35), lineWidth: 1) }
                .overlay(alignment: .topTrailing) { if date == today { Circle().fill(Color(red: 0.27, green: 0.79, blue: 0.46)).frame(width: 5, height: 5).offset(x: 2, y: 1) } }
            if !label.isEmpty { Text(label).font(.system(size: 10)).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true) }
        }.padding(.top, 4).frame(maxWidth: .infinity, minHeight: 58, alignment: .top)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(date + (label.isEmpty ? "" : " 第\(label)集") + (date == today ? " 今天" : ""))
    }
    private func changeMonth(_ value: Int) {
        guard let next = calendar.date(byAdding: .month, value: value, to: month), (1900...2200).contains(calendar.component(.year, from: next)) else { return }
        month = next
    }
    private func load() async {
        guard let number else { loading = false; episodes = []; return }
        loading = true; failed = false; episodes = []
        do {
            let value = try await TMDBMatch.details(item.mediaType, id: item.id, season: number)
            guard !Task.isCancelled, self.number == number else { return }
            episodes = value.season?.episodes ?? []; loading = false
        } catch { if !Task.isCancelled, self.number == number { failed = true; loading = false } }
    }
}

private struct DiscoverBroadcastNetworkLogo: View {
    let url: URL
    let name: String
    let id: Int?
    @AppStorage("local.tmdb.custom.v1") private var settings = Data()
    @State private var image: CGImage?
    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
                    .frame(width: 52, height: 18)
                    .padding(.horizontal, 5).padding(.vertical, 3)
                    .background(.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 4))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(name).accessibilityAddTraits(.isImage)
                    .accessibilityIdentifier("discover.calendar.network.\(id ?? 0)")
            }
        }
        .task(id: url.absoluteString + "|" + settings.base64EncodedString()) {
            let loaded = await TMDBArtwork.load(url, maxPixels: 208)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}

#endif
