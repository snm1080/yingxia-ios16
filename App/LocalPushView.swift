import SwiftUI
import Perception
import UniformTypeIdentifiers
import TVCore

#if os(iOS)
struct LocalPushView: View {
    @Environment(Store.self) private var store
    @Environment(\.openRoute) private var openRoute
    @Environment(\.isLocalPageActive) private var pageActive
    private let initialInput: String
    private let initialTitle: String
    private let initialHint: MediaMetadataHint?
    private let routesInStack: Bool
    @State private var input = ""
    @State private var title = ""
    @State private var headers = ""
    @State private var mode = "push"
    @State private var selectedSource = ""
    @State private var model = MediaPushModel()
    @State private var operation: Task<Void, Never>?
    @State private var filePicker = false
    @State private var fileImportWork: Task<Void, Never>?
    @State private var fileImportID = UUID()
    @State private var readingFile = false
    @State private var localFile: URL?
    @State private var localError: String?
    @State private var destination: PushDestination?
    @State private var prepared = false
    init(input: String = "", title: String = "", metadataHint: MediaMetadataHint? = nil, routesInStack: Bool = true) {
        initialInput = input; initialTitle = title; initialHint = metadataHint; self.routesInStack = routesInStack
    }
    private var sources: [Site] { store.subscription.map { config in MediaPush.sources(config.sites).filter { $0.canBrowse(jarURL: config.spiderURL) } } ?? [] }
    var body: some View {
        WithPerceptionTracking {
            Form {
                Section {
                    Picker("方式", selection: $mode) {
                        Text("推送").tag("push"); Text("直链").tag("direct"); Text("嗅探").tag("sniff"); Text("文件").tag("file")
                    }.pickerStyle(.segmented)
                    if mode == "file" {
                        Button("选择本地视频文件") { localError = nil; filePicker = true }.disabled(readingFile)
                        if readingFile { ProgressView("正在复制所选视频…") }
                        if let localFile { Text(localFile.lastPathComponent).font(.footnote) }
                    } else { TextField(mode == "push" ? "分享 / 磁力链接" : mode == "sniff" ? "网页地址" : "视频地址", text: $input, axis: .vertical).autocorrectionDisabled().textInputAutocapitalization(.never) }
                    TextField("影片名称（可选）", text: $title)
                    if mode != "push" && mode != "file" {
                        TextField("请求头（JSON 对象，可选）", text: $headers, axis: .vertical).autocorrectionDisabled().textInputAutocapitalization(.never)
                    }
                }
                if mode == "push" {
                    Section("推送站点") {
                        if sources.isEmpty {
                            Text("当前订阅没有推送/push 站点。请导入包含推送站点的接口。").foregroundStyle(.secondary)
                            RouteLink { LocalSourceSettingsView() } label: { Label("管理订阅", systemImage: "list.bullet.rectangle") }
                        } else {
                            Picker("选择站点", selection: $selectedSource) {
                                ForEach(sources) { Text($0.name).tag($0.id) }
                            }
                            Text("先检查所选站点是否支持，再读取真实资源和播放线路。").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    if model.busy { HStack { ProgressView(); Text(model.phase); Spacer(); Button("取消") { cancel() } } }
                    Button(mode == "push" ? "解析资源详情" : "打开视频") { open() }
                        .disabled(model.busy || readingFile || (mode == "push" && sources.isEmpty))
                    if let error = localError ?? model.error { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("推送")
            .onAppear {
                guard !prepared else { return }; prepared = true
                input = initialInput; title = initialTitle
                selectedSource = sources.first(where: { $0.provenance?.origin.absoluteString == store.historyScope })?.id ?? sources.first?.id ?? ""
            }
            .appOnChange(of: input) { _, _ in cancel() }
            .appOnChange(of: title) { _, _ in cancel() }
            .appOnChange(of: selectedSource) { _, _ in cancel() }
            .appOnChange(of: mode) { _, _ in cancel() }
            .appOnChange(of: pageActive) { _, active in if !active { cancel() } }
            .appOnChange(of: sources) { _, _ in
                cancel()
                if !sources.contains(where: { $0.id == selectedSource }) {
                    selectedSource = sources.first(where: { $0.provenance?.origin.absoluteString == store.historyScope })?.id ?? sources.first?.id ?? ""
                }
            }
            .onDisappear { cancel() }
            .localDocumentImporter(isPresented: $filePicker, kind: .mediaFile) { result in
                switch result {
                case .success(let selection): importMedia(selection)
                case .failure(let error): localError = error.localizedDescription
                }
            } cancelled: { localError = "已取消文件选择" }
            .sheet(item: $destination) { selection in
                RouteStack {
                    if selection.video.isFolder {
                        SiteView(site: selection.client.site, origin: selection.client.origin, jarURL: selection.client.jarURL, folder: selection.video)
                    } else {
                        VideoDetailView(video: selection.video, client: selection.client, preloaded: selection.video, metadataHint: selection.hint)
                    }
                }.environment(store)
            }
        }
    }
    private func cancel() {
        operation?.cancel(); operation = nil; model.cancel(); localError = nil
        fileImportID = UUID()
        fileImportWork?.cancel(); fileImportWork = nil; readingFile = false
    }
    private func importMedia(_ selection: LocalDocumentSelection) {
        fileImportWork?.cancel(); readingFile = true
        let active = UUID(); fileImportID = active
        fileImportWork = Task {
            defer {
                selection.release()
                if fileImportID == active { readingFile = false; fileImportWork = nil }
            }
            do {
                let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("LocalMedia", isDirectory: true)
                let file = try await selection.copyFile(to: directory)
                guard !Task.isCancelled, fileImportID == active else {
                    try? FileManager.default.removeItem(at: file)
                    throw CancellationError()
                }
                localFile = file
                title = selection.urls[0].deletingPathExtension().lastPathComponent
                localError = nil
            } catch { if !Task.isCancelled, fileImportID == active, !(error is CancellationError) { localError = error.localizedDescription } }
        }
    }
    private func open() {
        cancel()
        do {
            let headerValues: [String: String] = headers.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [:] : try JSONDecoder().decode([String: String].self, from: Data(headers.utf8))
            let value = MediaPushRequest(input: mode == "file" ? localFile?.absoluteString ?? "" : input, title: title, headers: headerValues,
                                         metadataHint: input == initialInput && title == initialTitle ? initialHint : nil)
            if mode == "push" {
                guard let source = sources.first(where: { $0.id == selectedSource }), let subscription = store.subscription else {
                    throw TVError.unsupported("请选择可用的推送站点")
                }
                let client = CatalogClient(site: source, origin: subscription.origin, jarURL: subscription.spiderURL).applying(subscription)
                operation = Task {
                    await model.resolve(value, client: client)
                    guard !Task.isCancelled, pageActive, let video = model.video else { return }
                    do {
                        try PushMediaLibrary.shared.register(value, video: video, client: client)
                        var seen = Set<String>()
                        let flags = video.episodes.map(\.flag).filter { seen.insert($0).inserted }
                        show(PushDestination(video: video, client: client.withPushInput(value.input, flags: flags), hint: value.metadataHint))
                    } catch { if !Task.isCancelled { localError = error.localizedDescription } }
                }
            } else {
                let record = try LocalMediaLibrary.shared.register(value, mode: mode == "file" ? .file : mode == "sniff" ? .sniff : .direct)
                var client = CatalogClient(site: record.site, origin: LocalMediaLibrary.origin)
                if let subscription = store.subscription { client = client.applying(subscription) }
                show(PushDestination(video: record.video, client: client, hint: value.metadataHint))
            }
        } catch { localError = error.localizedDescription }
    }
    /// Keep resource detail on the page's route stack so the root can present its one video player.
    private func show(_ selection: PushDestination) {
        guard routesInStack, let openRoute else { destination = selection; return }
        openRoute(Route {
            if selection.video.isFolder {
                return AnyView(SiteView(site: selection.client.site, origin: selection.client.origin, jarURL: selection.client.jarURL, folder: selection.video))
            }
            return AnyView(VideoDetailView(video: selection.video, client: selection.client, preloaded: selection.video, metadataHint: selection.hint))
        })
    }

}

private struct PushDestination: Identifiable {
    let id = UUID()
    let video: Video
    let client: CatalogClient
    let hint: MediaMetadataHint?
}

/// A search result opens its resources first; playback begins only after selection in detail.
struct PanShareResolveView: View {
    let request: MediaPushRequest
    @Environment(Store.self) private var store
    @Environment(\.isLocalPageActive) private var pageActive
    @State private var model = MediaPushModel()
    @State private var destination: PushDestination?
    @State private var localError: String?
    @State private var retry = 0

    var body: some View {
        WithPerceptionTracking {
            Group {
                if let selection = destination {
                    VStack(spacing: 0) {
                        if let localError { Text(localError).font(.footnote).foregroundStyle(.red).padding() }
                        if selection.video.isFolder {
                            SiteView(site: selection.client.site, origin: selection.client.origin, jarURL: selection.client.jarURL, folder: selection.video)
                        } else {
                            VideoDetailView(video: selection.video, client: selection.client, preloaded: selection.video, metadataHint: selection.hint)
                        }
                    }
                } else {
                    VStack(spacing: 18) {
                        if model.busy { ProgressView(model.phase).accessibilityIdentifier("discover.pan.resolving") }
                        if let error = localError ?? model.error {
                            Text(error).multilineTextAlignment(.center).foregroundStyle(.secondary)
                            Button("重试") { retry += 1 }.buttonStyle(.borderedProminent)
                            RouteLink { LocalSourceSettingsView() } label: { Label("管理订阅", systemImage: "list.bullet.rectangle") }
                        }
                    }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(request.title.isEmpty ? "解析资源" : request.title)
            .task(id: pageActive ? retry : -1) {
                if pageActive { await resolve() } else { model.cancel() }
            }
            .onDisappear { model.cancel() }
        }
    }

    @MainActor private func resolve() async {
        guard pageActive, destination == nil else { return }
        localError = nil
        do {
            guard let subscription = store.subscription else { throw TVError.unsupported("请先导入包含网盘推送站点的订阅") }
            let sources = MediaPush.sources(subscription.sites).filter { $0.canBrowse(jarURL: subscription.spiderURL) }
            guard let source = sources.first(where: { $0.origin(or: subscription.origin).absoluteString == store.historyScope }) ?? sources.first else {
                throw TVError.unsupported("当前订阅没有此设备可用的网盘推送站点，请检查订阅配置")
            }
            let base = CatalogClient(site: source, origin: subscription.origin, jarURL: subscription.spiderURL).applying(subscription)
            await model.resolve(request, client: base)
            try Task.checkCancellation()
            guard pageActive else { return }
            guard let video = model.video else { return }
            try PushMediaLibrary.shared.register(request, video: video, client: base)
            var seen = Set<String>()
            let flags = video.episodes.map(\.flag).filter { seen.insert($0).inserted }
            let client = base.withPushInput(request.input, flags: flags)
            destination = PushDestination(video: video, client: client, hint: request.metadataHint)
        } catch {
            if !Task.isCancelled, !(error is CancellationError) { localError = error.localizedDescription }
        }
    }
}
#endif
