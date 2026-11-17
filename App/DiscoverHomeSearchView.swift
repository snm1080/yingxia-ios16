import SwiftUI
import Perception
import TVCore

#if os(iOS)
/// A home-only catalog search: typing suggests titles, submitting shows movies and series.
struct DiscoverHomeSearchView: View {
    var featured: [TMDBCatalog.Item] = []
    var select: ((TMDBCatalog.Item) -> Void)? = nil
    @Environment(\.openRoute) private var openRoute
    @State private var model = DiscoverHomeSearchModel()
    @State private var query = ""
    @State private var operation: Task<Void, Never>?
    @FocusState private var focused: Bool
    private var keyword: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var showingResults: Bool { !model.submittedQuery.isEmpty && keyword == model.submittedQuery }

    var body: some View {
        WithPerceptionTracking {
            ScrollView {
                WithPerceptionTracking {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if showingResults { results }
                        else if !keyword.isEmpty { suggestions }
                        else { discovery }
                    }.padding(20)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .top, spacing: 0) { WithPerceptionTracking { searchBar } }
            .task(id: keyword) { await model.suggest(keyword) }
            .onAppear { if model.submittedQuery.isEmpty { focused = true } }
            .onDisappear { focused = false; operation?.cancel(); model.cancel() }
            .onReceive(NotificationCenter.default.publisher(for: TMDBServiceSettings.changed)) { _ in
                operation?.cancel(); model.cancel(); model = DiscoverHomeSearchModel()
                if !keyword.isEmpty { submit(keyword) }
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索电影、剧集…", text: $query)
                .focused($focused).submitLabel(.search).autocorrectionDisabled()
                .onSubmit { submit(keyword) }.accessibilityIdentifier("discover.homeSearch.input")
            if !query.isEmpty {
                Button { query = ""; focused = true } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).frame(width: 44, height: 44) }
                    .buttonStyle(.plain).accessibilityLabel("清除关键词")
            }
            Button("搜索") { submit(keyword) }.buttonStyle(.borderedProminent)
                .disabled(keyword.isEmpty).frame(minHeight: 44).accessibilityIdentifier("discover.homeSearch.submit")
        }.padding(.horizontal, 14).padding(.vertical, 8)
            .localGlassSurface(cornerRadius: 16)
            .padding(.horizontal, 16).padding(.bottom, 8)
    }

    private var discovery: some View {
        VStack(alignment: .leading, spacing: 24) {
            if !model.history.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("最近搜索").font(.headline); Spacer()
                        Button("全部清除") { model.clearHistory() }.font(.subheadline).frame(minHeight: 44)
                            .accessibilityIdentifier("discover.homeSearch.clearHistory")
                    }
                    DiscoverMetadataFlow(spacing: 8) {
                        ForEach(model.history, id: \.self) { title in
                            HStack(spacing: 0) {
                                Button { submit(title) } label: { Text(title).lineLimit(1).padding(.leading, 14).padding(.trailing, 4).frame(minHeight: 44) }
                                Button { model.removeHistory(title) } label: { Image(systemName: "xmark").font(.caption).frame(width: 44, height: 44) }
                                    .accessibilityLabel("删除首页搜索记录 \(title)")
                            }.font(.subheadline).buttonStyle(.plain).background(.primary.opacity(0.06), in: Capsule())
                        }
                    }
                }
            }
            if !featured.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("热门搜索").font(.headline)
                    DiscoverMetadataFlow(spacing: 8) {
                        ForEach(Array(featured.prefix(8)), id: \.key) { item in
                            Button { submit(item.name) } label: {
                                Label(item.name, systemImage: "magnifyingglass").font(.subheadline)
                                    .padding(.horizontal, 14).frame(minHeight: 44).background(.primary.opacity(0.06), in: Capsule())
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
            if model.history.isEmpty && featured.isEmpty {
                Text("输入片名，搜索首页电影和剧集资料。").font(.subheadline).foregroundStyle(.secondary).padding(.top, 16)
            }
        }
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("搜索联想").font(.headline)
            if model.suggesting { ProgressView("正在查找相关片名…") }
            ForEach(model.suggestions, id: \.self) { title in
                Button { submit(title) } label: {
                    HStack { Image(systemName: "magnifyingglass"); Text(title); Spacer(); Image(systemName: "arrow.up.left") }
                        .font(.subheadline).frame(minHeight: 48).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            if !model.suggesting && model.suggestions.isEmpty {
                Text("点击搜索，查找「\(keyword)」").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private var results: some View {
        Group {
            HStack {
                Text("「\(model.submittedQuery)」").font(.headline)
                Spacer()
                if !model.loading { Text("\(model.items.count) 个结果").font(.caption).foregroundStyle(.secondary) }
            }
            if model.loading { ProgressView("正在搜索…").frame(maxWidth: .infinity).padding(30) }
            if let error = model.error {
                Text(error).font(.subheadline).foregroundStyle(.secondary)
                Button("重试") { submit(model.submittedQuery) }.frame(minHeight: 44)
            } else if !model.loading && model.items.isEmpty {
                EmptyResults(symbol: "magnifyingglass", title: "暂无搜索结果", message: "试试其他电影或剧集名称。")
            }
            ForEach(model.items, id: \.key) { item in
                Button {
                    focused = false
                    if let select { select(item) }
                    else { openRoute?(Route { AnyView(DiscoverDetailView(item: item)) }) }
                } label: { DiscoverSearchRow(item: item) }
                    .buttonStyle(.plain).accessibilityIdentifier("discover.homeSearch.result.\(item.key)")
            }
        }
    }

    private func submit(_ value: String) {
        let value = String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard !value.isEmpty else { return }
        query = value; focused = false; operation?.cancel()
        operation = Task { await model.submit(value) }
    }
}

struct DiscoverHomeSearchPresentation: ViewModifier {
    @Binding var isPresented: Bool
    var featured: [TMDBCatalog.Item] = []
    @Environment(\.openRoute) private var openRoute
    func body(content: Content) -> some View {
        content.localGlassDialog(isPresented: $isPresented, title: "搜索电影、剧集", maxWidth: 560, maxHeight: 600, layout: .centered) {
            WithPerceptionTracking {
                DiscoverHomeSearchView(featured: featured, select: { item in
                    isPresented = false
                    openRoute?(Route { AnyView(DiscoverDetailView(item: item)) })
                })
            }
        }
    }
}
#endif
