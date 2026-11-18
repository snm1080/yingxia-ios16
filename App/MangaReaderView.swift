import SwiftUI
import Perception
import TVCore

/// The reading state: loaded chapters (vertical mode reads on from one into the next), where the viewer is,
/// prefetching ahead, and the saved progress.
@MainActor @Perceptible final class MangaReaderModel {
    struct Chapter: Identifiable {
        let index: Int
        let pages: [String]
        var id: Int { index }
    }
    struct Position: Hashable { var chapter: Int; var page: Int }

    let comic: MangaComic
    let chapters: [MangaChapter]
    private(set) var loaded: [Chapter] = []
    var position: Position
    /// Where to scroll or page to; the views clear it once there.
    var target: Position?
    private(set) var pageRequest: Position?
    private(set) var pageRequestID = UUID()
    private(set) var failure: String?
    private(set) var nextFailure: String?
    private(set) var loadingNext = false
    /// Shared by footer buttons, chapter picker and page gestures until the destination commits.
    private(set) var chapterRequest: ReaderPageIntent?
    private(set) var chapterFailure: String?
    private(set) var opening = false
    var rotation: ReaderPageRotation = .upright
    var mode: MangaReaderMode {
        didSet {
            if let catalog { catalog.setMode(mode) }
            else { MangaStore.shared.setMode(mode, for: comic) }
        }
    }
    /// Page shapes (width / height) once known, so the column doesn't jump as pages load.
    var aspects: [Position: CGFloat] = [:]
    private let bitmaps = ReaderBitmapCache()
    private var preparedBitmap: (key: ReaderBitmapKey, image: CGImage)?
    private var decodeWidth: CGFloat = 0
    private var imagePrefetch: [ReaderBitmapKey: (id: UUID, task: Task<Void, Never>)] = [:]
    private var chapterPrefetch: (id: UUID, task: Task<Void, Never>)?
    private var closed = false
    private var saved = Date.distantPast
    private let catalog: LocalReadingSession?
    private var requestID = UUID()
    private var chapterCrossesPages = false

    init(_ reading: MangaReading, catalog: LocalReadingSession? = nil) {
        self.catalog = catalog
        comic = reading.comic
        chapters = reading.chapters
        position = Position(chapter: reading.chapter, page: reading.page)
        mode = catalog?.defaultMode ?? MangaStore.shared.mode(for: reading.comic)
    }

    var single: Bool { chapters.isEmpty }
    func pages(_ chapter: Int) -> [String] { loaded.first { $0.index == chapter }?.pages ?? [] }
    var currentPages: [String] { pages(position.chapter) }
    func title(_ chapter: Int) -> String { chapters.indices.contains(chapter) ? chapters[chapter].title : "" }
    var hasNext: Bool { position.chapter + 1 < chapters.count }
    var hasPrevious: Bool { position.chapter > 0 }

    /// Opens `chapter` alone, at `page` (negative counts from the end).
    func open(_ chapter: Int, page: Int = 0) async {
        await open(ReaderPageIntent(chapter: chapter, page: page, fromEnd: page < 0), crossingPages: false)
    }

    /// Page gestures carry overflow across even a one-page chapter instead of clamping away
    /// fast repeated next/previous actions while the chapter is still loading.
    func openPage(_ intent: ReaderPageIntent) async { await open(intent, crossingPages: true) }

    /// Publish gesture intent synchronously, before the load task gets its first turn. Two
    /// rapid taps therefore accumulate against one shared target without a copied view state.
    func beginPageOpening(_ intent: ReaderPageIntent) -> Task<Void, Never> {
        guard !closed else { return Task {} }
        requestID = UUID()
        chapterRequest = intent
        target = nil
        pageRequest = nil
        chapterCrossesPages = true
        chapterFailure = nil
        nextFailure = nil
        opening = true
        let request = requestID
        return Task {
            guard request == requestID else { return }
            await openPage(intent)
        }
    }

    func retryChapter() async {
        guard let request = chapterRequest else { return }
        await open(request, crossingPages: chapterCrossesPages)
    }

    /// Explicit slider intent has a separate identity from a chapter's post-commit scroll.
    /// An old SwiftUI onChange callback cannot cancel a more recent chapter request.
    func requestPage(_ position: Position) {
        cancelOpening()
        target = nil
        pageRequest = position
        pageRequestID = UUID()
    }

    func consumePageRequest(_ id: UUID) -> Position? {
        guard id == pageRequestID, chapterRequest == nil else { return nil }
        defer { pageRequest = nil }
        return pageRequest
    }

    private func open(_ intent: ReaderPageIntent, crossingPages: Bool) async {
        guard !closed, !Task.isCancelled else { return }
        chapterRequest = intent
        target = nil
        pageRequest = nil
        chapterCrossesPages = crossingPages
        chapterFailure = nil
        chapterPrefetch?.task.cancel(); chapterPrefetch = nil
        let request = UUID(); requestID = request
        loadingNext = false
        opening = true
        defer { if request == requestID { opening = false } }
        failure = nil
        nextFailure = nil
        do {
            var destination = intent
            var pages: [String] = []
            var start = 0
            while true {
                pages = try await fetch(destination.chapter)
                try Task.checkCancellation()
                guard request == requestID else { return }
                if crossingPages, case .chapter(let next) = destination.resolve(pageCount: pages.count),
                   chapters.indices.contains(next.chapter) {
                    destination = next
                    continue
                }
                start = destination.clampedPage(pageCount: pages.count)
                break
            }
            let chapter = destination.chapter
            try Task.checkCancellation()
            guard request == requestID else { return }
            // Keep the existing chapter and progress on screen until its replacement can be
            // presented. A chapter's URL list resolving does not mean its first image is ready.
            if decodeWidth > 0, !loaded.isEmpty, pages.indices.contains(start) {
                let width = decodeWidth
                let image = try await bitmap(chapter: chapter, page: start, url: pages[start], pixelWidth: width)
                try Task.checkCancellation()
                guard request == requestID, !closed else { return }
                preparedBitmap = (bitmapKey(chapter: chapter, page: start, url: pages[start], pixelWidth: width), image)
            }
            loaded = [Chapter(index: chapter, pages: pages)]
            position = Position(chapter: chapter, page: start)
            target = position
            chapterRequest = nil
            chapterFailure = nil
            save(force: true)
            opening = false
            prefetch()
        } catch {
            guard request == requestID, !Task.isCancelled, !(error is CancellationError) else { return }
            if loaded.isEmpty { failure = error.mangaMessage } else { nextFailure = error.mangaMessage }
            chapterFailure = error.mangaMessage
        }
    }

    /// A page turn supersedes a chapter jump whose image has not appeared yet.
    func cancelOpening() {
        guard opening || chapterRequest != nil else { return }
        requestID = UUID()
        opening = false
        loadingNext = false
        nextFailure = nil
        chapterRequest = nil
        chapterFailure = nil
    }

    /// Appends the next chapter, for reading on without a break.
    func loadNext() async {
        guard !opening, let last = loaded.last, last.index + 1 < chapters.count, !loadingNext else { return }
        loadingNext = true
        nextFailure = nil
        let request = requestID
        defer { if request == requestID { loadingNext = false } }
        do {
            let pages = try await fetch(last.index + 1)
            try Task.checkCancellation()
            guard request == requestID, loaded.last?.index == last.index else { return }
            loaded.append(Chapter(index: last.index + 1, pages: pages))
            // Long reads keep a few chapters, not every image of the comic.
            if loaded.count > 3, loaded.first!.index < position.chapter { loaded.removeFirst() }
        } catch {
            if request == requestID, !Task.isCancelled, !(error is CancellationError) { nextFailure = error.mangaMessage }
        }
    }

    private func fetch(_ chapter: Int) async throws -> [String] {
        if let catalog { return try await catalog.pages(chapter) }
        return try await MangaRuntime.shared.pages(comic.sourceKey, comic: comic.id, chapter: chapters.indices.contains(chapter) ? chapters[chapter].id : nil)
    }

    func imageData(chapter: Int, page: Int, url: String) async throws -> Data {
        guard !closed else { throw CancellationError() }
        if let catalog { return try await catalog.imageData(chapter: chapter, page: page) }
        return try await MangaImages.shared.data(source: comic.sourceKey, url: url, kind: .page, comic: comic.id, chapter: chapterID(chapter))
    }

    func bitmapKey(chapter: Int, page: Int, url: String, pixelWidth: CGFloat) -> ReaderBitmapKey {
        ReaderBitmapKey(chapter: chapter, page: page, url: url, pixelWidth: pixelWidth)
    }

    func cachedBitmap(_ key: ReaderBitmapKey) -> CGImage? {
        if let preparedBitmap, preparedBitmap.key.chapter == key.chapter,
           preparedBitmap.key.page == key.page, preparedBitmap.key.url == key.url { return preparedBitmap.image }
        return bitmaps.cached(key)
    }

    func bitmap(chapter: Int, page: Int, url: String, pixelWidth: CGFloat) async throws -> CGImage {
        guard !closed else { throw CancellationError() }
        let key = bitmapKey(chapter: chapter, page: page, url: url, pixelWidth: pixelWidth)
        let image = try await bitmaps.image(key) { [self] in try await imageData(chapter: chapter, page: page, url: url) }
        guard !closed else { throw CancellationError() }
        aspects[Position(chapter: chapter, page: page)] = CGFloat(image.width) / CGFloat(max(image.height, 1))
        return image
    }

    func setDecodeWidth(_ width: CGFloat) {
        guard width > 0, width != decodeWidth else { return }
        decodeWidth = width
        prefetch()
    }

    func seen(_ position: Position) {
        guard !closed, position != self.position, pages(position.chapter).indices.contains(position.page) else { return }
        preparedBitmap = nil
        self.position = position
        save(force: false)
        prefetch()
    }

    /// Downloads the next pages before the viewer gets there.
    func prefetch() {
        guard !closed else { return }
        let pages = currentPages, chapter = position.chapter
        let indices = [position.page + 1, position.page - 1, position.page + 2]
        let nearby = decodeWidth > 0 ? indices.compactMap { index -> ReaderBitmapKey? in
            guard pages.indices.contains(index) else { return nil }
            return bitmapKey(chapter: chapter, page: index, url: pages[index], pixelWidth: decodeWidth)
        } : []
        for (key, request) in imagePrefetch where !nearby.contains(key) { request.task.cancel(); imagePrefetch[key] = nil }
        for key in nearby where imagePrefetch[key] == nil && cachedBitmap(key) == nil {
            let id = UUID()
            let task = Task(priority: .utility) { [weak self] in
                guard let self else { return }
                _ = try? await self.bitmap(chapter: key.chapter, page: key.page, url: key.url, pixelWidth: CGFloat(key.pixelWidth))
                if self.imagePrefetch[key]?.id == id { self.imagePrefetch[key] = nil }
            }
            imagePrefetch[key] = (id, task)
        }
        if position.page >= pages.count - 3, !mode.paged, chapterPrefetch == nil {
            let id = UUID()
            let task = Task { [weak self] in
                await self?.loadNext()
                if self?.chapterPrefetch?.id == id { self?.chapterPrefetch = nil }
            }
            chapterPrefetch = (id, task)
        }
    }

    func save(force: Bool) {
        guard force || Date().timeIntervalSince(saved) > 1.5 else { return }
        saved = Date()
        if let catalog {
            catalog.record(chapter: position.chapter, page: position.page, totalPages: currentPages.count)
            return
        }
        MangaStore.shared.record(MangaLibrary.Progress(comic: comic, chapterID: chapters.indices.contains(position.chapter) ? chapters[position.chapter].id : nil,
                                                       chapterTitle: title(position.chapter), chapterIndex: position.chapter,
                                                       chapterCount: chapters.count, page: position.page, pageCount: currentPages.count))
    }

    func chapterID(_ chapter: Int) -> String? { chapters.indices.contains(chapter) ? chapters[chapter].id : nil }
    func close() {
        closed = true
        requestID = UUID(); opening = false; loadingNext = false
        chapterRequest = nil; chapterFailure = nil; pageRequest = nil
        for request in imagePrefetch.values { request.task.cancel() }
        imagePrefetch.removeAll()
        chapterPrefetch?.task.cancel(); chapterPrefetch = nil
        bitmaps.close()
        preparedBitmap = nil
        catalog?.close()
    }
}

/// Reads a comic full screen: vertical scroll (webtoons) or one page at a time in either direction.
struct MangaReaderView: View {
    @State private var model: MangaReaderModel
    @State private var chrome = true
    @State private var showsChapters = false
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    @Environment(Store.self) private var store
    #endif
    private let start: MangaReading

    init(reading: MangaReading) {
        start = reading
        _model = State(initialValue: MangaReaderModel(reading))
    }

    init(session: LocalReadingSession) {
        start = session.reading
        _model = State(initialValue: MangaReaderModel(session.reading, catalog: session))
    }

    var body: some View {
        WithPerceptionTracking {
            ZStack {
                Color.black.ignoresSafeArea()
                if !model.loaded.isEmpty {
                    pages
                } else if let failure = model.failure {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                        Text(failure).multilineTextAlignment(.center).frame(maxWidth: 520)
                        HStack {
                            Button(L10n.text("Try Again")) { Task { await model.open(model.position.chapter, page: model.position.page) } }
                            Button(L10n.text("Close")) { close() }
                        }
                        .controlButton()
                    }
                    .foregroundStyle(.white).padding()
                } else {
                    VStack(spacing: 16) {
                        ProgressView().tint(.white).controlSize(.large)
                        MangaWaitNote().padding(.horizontal, 32)
                    }
                }
                if !model.loaded.isEmpty, model.chapterRequest != nil,
                   model.opening || model.chapterFailure != nil {
                    MangaChapterRequestStatus(model: model)
                }
                MangaReaderChrome(model: model, visible: chrome, showsChapters: $showsChapters, close: close)
            }
            .environment(\.colorScheme, .dark)
            #if os(iOS)
            .statusBarHidden(!chrome)
            .persistentSystemOverlays(chrome ? .automatic : .hidden)
            .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
            #endif
            #if os(macOS)
            .toolbar(.hidden, for: .windowToolbar)
            .navigationBarBackButtonHidden()
            .onAppear { store.hidesSidebar = true }
            .onDisappear { store.hidesSidebar = false }
            #endif
            #if os(tvOS)
            .onExitCommand { if chrome { close() } else { withAnimation { chrome = true } } }
            #endif
            .sheet(isPresented: $showsChapters) {
                WithPerceptionTracking {
                    MangaChapterPicker(model: model) { index in showsChapters = false; Task { await model.open(index) } }
                }
            }
            .task {
                // Presenting the chapter sheet can cover the reader. Coming back keeps the
                // selected chapter and page instead of resolving the initial chapter again.
                if model.loaded.isEmpty { await model.open(start.chapter, page: start.page) }
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                withAnimation(.appSmooth) { chrome = false }
            }
            .onDisappear { model.save(force: true) }
            .environment(\.mangaToggleChrome, MangaChromeToggle { withAnimation(.appSmooth(duration: 0.2)) { chrome.toggle() } })
        }
    }

    @ViewBuilder private var pages: some View {
        switch model.mode {
        case .vertical: MangaVerticalReader(model: model)
        case .leftToRight, .rightToLeft: MangaPagedReader(model: model)
        }
    }

    private func close() {
        model.save(force: true)
        model.close()
        dismiss()
    }
}

/// Chapter controls and page gestures share this presentation, including a retry that retains
/// the original target chapter and end-relative page when the image request fails.
private struct MangaChapterRequestStatus: View {
    let model: MangaReaderModel

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 10) {
                if let failure = model.chapterFailure {
                    Text(failure).font(.caption).multilineTextAlignment(.center).lineLimit(3)
                    Button(L10n.text("Try Again")) { Task { await model.retryChapter() } }.controlButton()
                } else {
                    ProgressView().tint(.white)
                    Text("正在加载章节…").font(.callout)
                }
            }
            .foregroundStyle(.white).padding(18)
            .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 16)).padding(24)
            .allowsHitTesting(model.chapterFailure != nil)
        }
    }
}

struct MangaChromeToggle { let toggle: () -> Void; func callAsFunction() { toggle() } }
extension EnvironmentValues { @Entry var mangaToggleChrome: MangaChromeToggle? = nil }

// MARK: - One page

/// A page image, fetched the way its source asks. Re-layouts keep the same page visible while
/// a larger bitmap is prepared; identities include chapter/page so reused URLs cannot cross pages.
struct MangaPageImage: View {
    let model: MangaReaderModel
    let chapter: Int
    let index: Int
    let url: String
    let pixelWidth: CGFloat
    var fitsScreen = false
    @State private var handoff = ReaderPageHandoff<ReaderBitmapKey, CGImage>()
    @State private var attempt = 0

    private var key: ReaderBitmapKey { model.bitmapKey(chapter: chapter, page: index, url: url, pixelWidth: pixelWidth) }
    private var visibleImage: CGImage? {
        if let image = model.cachedBitmap(key) { return image }
        guard let displayed = handoff.displayed,
              displayed.page.chapter == chapter, displayed.page.page == index, displayed.page.url == url else { return nil }
        return displayed.value
    }

    var body: some View {
        WithPerceptionTracking {
            Group {
                if let image = visibleImage {
                    ReaderBitmapImage(image: image, rotation: model.rotation, fitsScreen: fitsScreen)
                } else {
                    let aspect = model.aspects[.init(chapter: chapter, page: index)] ?? 0.7
                    Color.black
                        .aspectRatio(model.rotation.swapsAxes ? 1 / aspect : aspect, contentMode: .fit)
                        .overlay {
                            WithPerceptionTracking {
                                VStack(spacing: 12) {
                                    Text("\(index + 1)").font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.25))
                                    if let message = handoff.failure {
                                        Text(message).font(.caption).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center).lineLimit(3).padding(.horizontal)
                                        Button(L10n.text("Try Again")) { attempt += 1 }.controlButton()
                                    } else { ProgressView().tint(.white.opacity(0.6)) }
                                }
                            }
                        }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: fitsScreen ? .infinity : nil)
            .task(id: "\(chapter)#\(index)#\(url)#\(attempt)#\(key.pixelWidth)") {
                let request = handoff.begin(key)
                do {
                    let image = try await model.bitmap(chapter: chapter, page: index, url: url, pixelWidth: pixelWidth)
                    try Task.checkCancellation()
                    handoff.finish(request, value: image)
                } catch is CancellationError {
                } catch {
                    if !Task.isCancelled { handoff.fail(request, message: error.mangaMessage) }
                }
            }
            .onDisappear { handoff = ReaderPageHandoff() }
        }
    }
}

/// Fit the rotated bounds first, then render the original bitmap inside that frame. Keeping
/// rotation out of the decode key reuses the image at every angle without another request.
private struct ReaderBitmapImage: View {
    let image: CGImage
    let rotation: ReaderPageRotation
    let fitsScreen: Bool

    private var dimensions: CGSize { CGSize(width: image.width, height: image.height) }

    var body: some View {
        if fitsScreen {
            GeometryReader { proxy in bitmap(in: proxy.size) }
        } else {
            let bounds = rotation.bounds(for: dimensions)
            Color.clear.aspectRatio(bounds.width / max(bounds.height, 1), contentMode: .fit)
                .overlay { GeometryReader { proxy in bitmap(in: proxy.size) } }
        }
    }

    private func bitmap(in viewport: CGSize) -> some View {
        let size = rotation.fittedSize(image: dimensions, viewport: viewport, fitHeight: fitsScreen)
        return Image(decorative: image, scale: 1).resizable().interpolation(.high)
            .frame(width: size.width, height: size.height)
            .rotationEffect(.degrees(Double(rotation.rawValue)))
            .frame(width: viewport.width, height: viewport.height)
    }
}

// MARK: - Vertical

/// Pages one under another, read on into the next chapter; pinch or double-tap to zoom.
struct MangaVerticalReader: View {
    let model: MangaReaderModel
    @State private var zoom: CGFloat = 1
    @State private var pinch: CGFloat = 1
    @State private var rotationAnchor: MangaReaderModel.Position?
    @State private var rotationRelease: Task<Void, Never>?
    #if os(iOS)
    @State private var zoomer = MangaZoomController()
    #endif
    @Environment(\.displayScale) private var scale
    @Environment(\.mangaToggleChrome) private var toggleChrome

    var body: some View {
        WithPerceptionTracking {
            // The pages run edge to edge, under the Dynamic Island; the outer reader keeps the safe area so the
            // Previous Chapter button at the top can sit below it.
            GeometryReader { outer in
                WithPerceptionTracking {
                let top = outer.safeAreaInsets.top
                GeometryReader { proxy in
                    WithPerceptionTracking {
                        #if os(iOS)
                        // UIKit zooms the whole column, so the spot between the fingers stays under them (see MangaZoomView).
                        MangaPinchZoom(controller: zoomer, rotation: model.rotation) {
                            WithPerceptionTracking {
                                column(proxy.size, top: top)
                                    .onTapGesture(count: 2, coordinateSpace: CoordinateSpace.local) { zoomer.toggle(at: $0) }
                                    .onTapGesture { toggleChrome?() }
                                    .environment(\.colorScheme, .dark)
                            }
                        }
                        #else
                        column(proxy.size, top: top)
                            #if os(macOS)
                            .simultaneousGesture(MagnifyGesture()
                                .onChanged { value in pinch = value.magnification }
                                .onEnded { value in zoom = min(4, max(1, zoom * value.magnification)); pinch = 1 })
                            .onTapGesture(count: 2) { withAnimation(.appSmooth) { zoom = zoom > 1 ? 1 : 2 } }
                            .onTapGesture { toggleChrome?() }
                            #endif
                        #endif
                    }
                }
                .ignoresSafeArea()
                }
            }
        }
    }

    private func column(_ size: CGSize, top: CGFloat) -> some View {
        let width = size.width * zoom * pinch
        let axes: Axis.Set = zoom > 1 ? [.vertical, .horizontal] : .vertical
        return ScrollViewReader { reader in
            WithPerceptionTracking {
                ScrollView(axes, showsIndicators: false) {
                    WithPerceptionTracking {
                        chapterColumn(size, top: top).frame(width: width)
                    }
                }
                .coordinateSpace(name: "reader.vertical.viewport")
                .onPreferenceChange(ReaderPageFrames.self) { frames in
                    MainActor.assumeIsolated {
                        guard rotationAnchor == nil,
                              let position = ReaderVerticalViewport.visiblePage(frames: frames, height: size.height, current: model.position) else { return }
                        model.seen(position)
                    }
                }
                .appOnChange(of: model.target) { _, target in
                    guard let target, model.target == target, model.chapterRequest == nil else { return }
                    reader.scrollTo(target, anchor: .top)
                    model.target = nil
                }
                .appOnChange(of: model.pageRequestID) { _, requestID in
                    guard let target = model.consumePageRequest(requestID) else { return }
                    reader.scrollTo(target, anchor: .top)
                }
                .appOnChange(of: model.rotation) { _, _ in
                    let anchor = model.position
                    rotationAnchor = anchor
                    rotationRelease?.cancel()
                    zoom = 1; pinch = 1
                    reader.scrollTo(anchor, anchor: .top)
                    rotationRelease = Task { @MainActor in
                        await Task.yield()
                        guard !Task.isCancelled else { return }
                        reader.scrollTo(anchor, anchor: .top)
                        try? await Task.sleep(for: .milliseconds(150))
                        if !Task.isCancelled { rotationAnchor = nil }
                    }
                }
                .task(id: Int(size.width * scale)) { model.setDecodeWidth(min(size.width * scale * 1.5, 2400)) }
                .onAppear {
                    if let target = model.target { reader.scrollTo(target, anchor: .top); model.target = nil }
                }
                .onDisappear { rotationRelease?.cancel() }
            }
        }
    }

    private func chapterColumn(_ size: CGSize, top: CGFloat) -> some View {
        LazyVStack(spacing: 0) {
            WithPerceptionTracking {
                if model.hasPrevious, model.loaded.first?.index == model.position.chapter, let first = model.loaded.first {
                    Button { Task { await model.open(first.index - 1, page: -1) } } label: {
                        Label(L10n.text("Previous Chapter"), systemImage: "chevron.up")
                            .padding(.vertical, 24).frame(maxWidth: .infinity).padding(.top, top)
                    }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7)).id("previous")
                }
                ForEach(model.loaded) { chapter in
                    WithPerceptionTracking { chapterPages(chapter, size: size) }
                }
            }
        }
    }

    private func chapterPages(_ chapter: MangaReaderModel.Chapter, size: CGSize) -> some View {
        Group {
            ForEach(Array(chapter.pages.enumerated()), id: \.offset) { index, url in
                WithPerceptionTracking {
                    MangaPageImage(model: model, chapter: chapter.index, index: index, url: url,
                                   pixelWidth: min(size.width * scale * 1.5, 2400))
                        .id(MangaReaderModel.Position(chapter: chapter.index, page: index))
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(key: ReaderPageFrames.self,
                                    value: [.init(chapter: chapter.index, page: index): proxy.frame(in: .named("reader.vertical.viewport"))])
                            }
                        }
                        #if os(tvOS)
                        .focusable()
                        #endif
                }
            }
            MangaChapterEnd(model: model, chapter: chapter.index)
        }
    }
}

private struct ReaderPageFrames: PreferenceKey {
    static let defaultValue: [MangaReaderModel.Position: CGRect] = [:]
    static func reduce(value: inout [MangaReaderModel.Position: CGRect], nextValue: () -> [MangaReaderModel.Position: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// The break between two chapters in vertical mode: what comes next, or the end of the comic.
private struct MangaChapterEnd: View {
    let model: MangaReaderModel
    let chapter: Int
    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 10) {
                if chapter + 1 < model.chapters.count {
                    Text(L10n.text("End of %@", model.title(chapter))).font(.footnote).foregroundStyle(.white.opacity(0.5))
                    Text(L10n.text("Next: %@", model.title(chapter + 1))).font(.headline).foregroundStyle(.white.opacity(0.85))
                    if model.loadingNext { ProgressView().tint(.white) }
                    if let failure = model.nextFailure {
                        Text(failure).font(.caption).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
                        Button(L10n.text("Try Again")) { Task { await model.loadNext() } }.controlButton()
                    }
                } else {
                    Image(systemName: "checkmark.circle").font(.title).foregroundStyle(.white.opacity(0.6))
                    Text(model.single ? L10n.text("The End") : L10n.text("You're all caught up")).font(.headline).foregroundStyle(.white.opacity(0.85))
                }
            }
            .padding(.vertical, 48).frame(maxWidth: .infinity)
            .onAppear { Task { await model.loadNext() } }
        }
    }
}

// MARK: - Paged

/// One page at a time. Taps on the sides turn pages (the leading side goes back, mirrored for right-to-left),
/// the middle shows the controls; the remote's arrows and the keyboard's turn them too.
struct MangaPagedReader: View {
    let model: MangaReaderModel
    @Environment(\.displayScale) private var scale
    @Environment(\.mangaToggleChrome) private var toggleChrome
    @State private var page = 0
    #if os(tvOS)
    @FocusState private var focused: Bool
    #endif

    private var rtl: Bool { model.mode == .rightToLeft }
    private var count: Int { model.currentPages.count }

    var body: some View {
        WithPerceptionTracking {
            GeometryReader { proxy in
                WithPerceptionTracking {
                    let pixelWidth = min(max(proxy.size.width, proxy.size.height) * scale, 3000)
                    Group {
                        #if os(iOS)
                        MangaAtomicPagedReader(model: model, pixelWidth: pixelWidth)
                        #else
                        ZStack {
                            if page < count {
                                MangaPageImage(model: model, chapter: model.position.chapter, index: page, url: model.currentPages[page], pixelWidth: pixelWidth, fitsScreen: true)
                                    .id("\(model.position.chapter)-\(page)")
                                    .transition(.opacity)
                            } else { MangaPagedEnd(model: model) }
                            // The next page decodes out of sight, so turning shows it at once.
                            if page + 1 < count {
                                MangaPageImage(model: model, chapter: model.position.chapter, index: page + 1, url: model.currentPages[page + 1], pixelWidth: pixelWidth, fitsScreen: true)
                                    .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
                            }
                        }
                        #if os(macOS)
                        .overlay { WithPerceptionTracking { tapZones(proxy.size) } }
                        .focusable().focusEffectDisabled()
                        .onKeyPress(.leftArrow) { turn(rtl ? 1 : -1); return .handled }
                        .onKeyPress(.rightArrow) { turn(rtl ? -1 : 1); return .handled }
                        .onKeyPress(.space) { turn(1); return .handled }
                        #else
                        .focusable().focused($focused)
                        .onAppear { focused = true }
                        .onMoveCommand { direction in
                            // Left is the previous page and Right the next in every reading mode, as on any TV list: pages fade
                            // here rather than slide, and a remote's Left going forward in right-to-left comics read as backwards.
                            switch direction {
                            case .left: turn(-1)
                            case .right: turn(1)
                            case .down: Task { if model.hasNext { await model.open(model.position.chapter + 1) } }
                            case .up: Task { if model.hasPrevious { await model.open(model.position.chapter - 1) } }
                            default: break
                            }
                        }
                        .onPlayPauseCommand { toggleChrome?() }
                        .onTapGesture { toggleChrome?() }
                        #endif
                        #endif
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
            .ignoresSafeArea()
            #if !os(iOS)
            .onAppear { page = model.position.page }
            .appOnChange(of: page) { _, value in
                if value < count { model.seen(.init(chapter: model.position.chapter, page: value)) }
                else if model.hasNext { Task { await model.open(model.position.chapter + 1) } }
            }
            .appOnChange(of: model.target) { _, target in
                guard let target, model.target == target, model.chapterRequest == nil else { return }
                page = target.page
                model.target = nil
            }
            .appOnChange(of: model.pageRequestID) { _, requestID in
                guard let target = model.consumePageRequest(requestID) else { return }
                page = target.page
            }
            #endif
        }
    }

    private func turn(_ step: Int) {
        let next = page + step
        if next < 0 {
            if model.hasPrevious { Task { await model.open(model.position.chapter - 1, page: -1) } }
            return
        }
        guard next <= count else { return }
        withAnimation(.appSmooth(duration: 0.18)) { page = next }
    }

    #if !os(tvOS)
    /// A tap `across` the screen (0 left, 1 right): a third on each side turns the page; the middle shows the controls.
    private func tapped(_ across: CGFloat) {
        if across < 0.3 { turn(rtl ? 1 : -1) } else if across > 0.7 { turn(rtl ? -1 : 1) } else { toggleChrome?() }
    }

    private func tapZones(_ size: CGSize) -> some View {
        Color.clear.contentShape(Rectangle())
            .onTapGesture(coordinateSpace: CoordinateSpace.local) { point in tapped(point.x / max(size.width, 1)) }
    }
    #endif
}

/// After a chapter's last page: the next chapter, or the end.
private struct MangaPagedEnd: View {
    let model: MangaReaderModel
    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 14) {
                if model.hasNext {
                    Text(L10n.text("End of %@", model.title(model.position.chapter))).font(.footnote).foregroundStyle(.white.opacity(0.5))
                    Text(L10n.text("Next: %@", model.title(model.position.chapter + 1))).font(.title3.weight(.semibold))
                    if let failure = model.nextFailure {
                        Text(failure).font(.caption).multilineTextAlignment(.center).padding(.horizontal)
                        Button(L10n.text("Try Again")) { Task { await model.open(model.position.chapter + 1) } }.controlButton()
                    } else { ProgressView().tint(.white) }
                } else {
                    Image(systemName: "checkmark.circle").font(.largeTitle).foregroundStyle(.white.opacity(0.6))
                    Text(model.single ? L10n.text("The End") : L10n.text("You're all caught up")).font(.title3.weight(.semibold))
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

#if os(iOS)
/// One persistent presentation owns the currently visible bitmap. Navigation requests may
/// overtake each other, but only the latest completed image advances the visible page/history.
private struct MangaAtomicPagedReader: View {
    let model: MangaReaderModel
    let pixelWidth: CGFloat
    @Environment(\.mangaToggleChrome) private var toggleChrome
    @State private var handoff = ReaderPageHandoff<ReaderBitmapKey, CGImage>()
    @State private var loading: Task<Void, Never>?
    @State private var showingEnd = false

    private var rtl: Bool { model.mode == .rightToLeft }
    private var visibleKey: ReaderBitmapKey {
        let index = model.position.page
        let url = model.currentPages.indices.contains(index) ? model.currentPages[index] : ""
        return model.bitmapKey(chapter: model.position.chapter, page: index, url: url, pixelWidth: pixelWidth)
    }
    private var visibleImage: CGImage? {
        // A chapter jump predecodes the replacement before changing position. Show that exact
        // bitmap immediately, so its already-committed title/page cannot accompany the old chapter.
        if let image = model.cachedBitmap(visibleKey) { return image }
        return handoff.displayed?.value
    }
    private var requestedPage: Int {
        guard let request = handoff.requested, request.page.chapter == model.position.chapter else { return model.position.page }
        return request.page.page
    }

    var body: some View {
        WithPerceptionTracking {
            ZStack {
                if showingEnd {
                    MangaPagedEnd(model: model)
                        .contentShape(Rectangle())
                        .onTapGesture(coordinateSpace: CoordinateSpace.local) { _ in showingEnd = false }
                        .gesture(DragGesture(minimumDistance: 35).onEnded { _ in showingEnd = false })
                } else {
                    MangaZoomablePage(pageID: "\(visibleKey.chapter)#\(visibleKey.page)#\(visibleKey.url)", rotation: model.rotation,
                                      tapped: tapped, swiped: { physicalStep in turn(rtl ? -physicalStep : physicalStep) }) {
                        WithPerceptionTracking {
                            ZStack {
                                Color.black
                                if let image = visibleImage { ReaderBitmapImage(image: image, rotation: model.rotation, fitsScreen: true) }
                            }
                        }
                    }
                }
                if model.chapterRequest == nil, handoff.isLoading || handoff.failure != nil {
                    VStack(spacing: 10) {
                        if let failure = handoff.failure {
                            Text("第 \(requestedPage + 1) 页加载失败").font(.callout.weight(.semibold))
                            Text(failure).font(.caption).multilineTextAlignment(.center).lineLimit(3)
                            Button(L10n.text("Try Again")) { requestPage(requestedPage) }.controlButton()
                        } else {
                            ProgressView().tint(.white)
                            Text("正在加载第 \(requestedPage + 1) 页…").font(.callout)
                        }
                    }
                    .foregroundStyle(.white).padding(18)
                    .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 16))
                    .padding(24)
                    .allowsHitTesting(handoff.failure != nil)
                }
            }
            .background(Color.black)
            .onAppear {
                model.setDecodeWidth(pixelWidth)
                if model.chapterRequest == nil {
                    requestPage(model.consumePageRequest(model.pageRequestID)?.page ?? model.position.page)
                    model.target = nil
                }
            }
            .appOnChange(of: model.target) { _, target in
                guard let target, model.target == target, model.chapterRequest == nil else { return }
                showingEnd = false
                requestPage(target.page)
                model.target = nil
            }
            .appOnChange(of: model.pageRequestID) { _, requestID in
                guard let target = model.consumePageRequest(requestID) else { return }
                requestPage(target.page)
            }
            .appOnChange(of: model.chapterRequest) { _, request in
                if request != nil, request == model.chapterRequest { handoff.cancel() }
            }
            .appOnChange(of: pixelWidth) { _, width in
                model.setDecodeWidth(width)
                if model.chapterRequest == nil { requestPage(requestedPage) }
            }
            .onDisappear {
                if model.chapterRequest == nil { loading?.cancel() }
                handoff.cancel()
            }
        }
    }

    private func requestPage(_ index: Int) {
        guard model.currentPages.indices.contains(index) else { return }
        showingEnd = false
        loading?.cancel()
        model.cancelOpening()
        let chapter = model.position.chapter, url = model.currentPages[index]
        let key = model.bitmapKey(chapter: chapter, page: index, url: url, pixelWidth: pixelWidth)
        let request = handoff.begin(key)
        if let image = model.cachedBitmap(key) {
            handoff.finish(request, value: image)
            model.seen(.init(chapter: chapter, page: index))
            return
        }
        loading = Task {
            do {
                let image = try await model.bitmap(chapter: chapter, page: index, url: url, pixelWidth: pixelWidth)
                try Task.checkCancellation()
                guard model.chapterRequest == nil, chapter == model.position.chapter, handoff.finish(request, value: image) else { return }
                model.seen(.init(chapter: chapter, page: index))
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { handoff.fail(request, message: error.mangaMessage) }
            }
        }
    }

    private func turn(_ step: Int) {
        if let pending = model.chapterRequest {
            // A forward chapter starts at page zero; stepping back crosses into the preceding
            // chapter's last page. End-relative previous requests cross forward at offset zero.
            navigate(pending.stepped(step).normalizedBoundary())
            return
        }
        navigate(ReaderPageIntent(chapter: model.position.chapter, page: requestedPage + step))
    }

    private func navigate(_ intent: ReaderPageIntent) {
        if intent.chapter == model.position.chapter {
            switch intent.resolve(pageCount: model.currentPages.count) {
            case .page(let page): requestPage(page)
            case .chapter(let destination):
                if destination.chapter < 0 { requestPage(0) }
                else if destination.chapter >= model.chapters.count { showingEnd = true }
                else { requestChapter(destination) }
            }
        } else if model.chapters.indices.contains(intent.chapter) { requestChapter(intent) }
    }

    private func requestChapter(_ intent: ReaderPageIntent) {
        loading?.cancel()
        handoff.cancel()
        loading = model.beginPageOpening(intent)
    }

    private func tapped(_ across: CGFloat) {
        if across < 0.3 { turn(rtl ? 1 : -1) }
        else if across > 0.7 { turn(rtl ? -1 : 1) }
        else { toggleChrome?() }
    }
}

/// A page that zooms with a pinch or a double tap, then pans; at 1× drags fall through to the page turner.
struct MangaZoomablePage<Content: View>: UIViewRepresentable {
    let pageID: String
    let rotation: ReaderPageRotation
    /// A single tap, with where it landed across the page: 0 at the left edge, 1 at the right.
    let tapped: (CGFloat) -> Void
    let swiped: (Int) -> Void
    @ViewBuilder let content: Content

    struct EdgeToEdgeContent: View {
        let content: Content
        var body: some View { content.ignoresSafeArea() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(UIHostingController(rootView: EdgeToEdgeContent(content: content))) }

    func makeUIView(context: Context) -> MangaPageScrollView {
        let scroll = MangaPageScrollView()
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 4
        scroll.bouncesZoom = true
        scroll.panGestureRecognizer.isEnabled = false
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.backgroundColor = .black
        scroll.delegate = context.coordinator
        let host = context.coordinator.host
        host.view.backgroundColor = .black
        if #available(iOS 16.4, *) { host.safeAreaRegions = [] }
        host.view.translatesAutoresizingMaskIntoConstraints = true
        scroll.pageView = host.view
        scroll.addSubview(host.view)
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.singleTapped(_:)))
        tap.require(toFail: doubleTap)
        // A failed page's Try Again button still gets its tap.
        tap.cancelsTouchesInView = false
        scroll.addGestureRecognizer(tap)
        for direction: UISwipeGestureRecognizer.Direction in [.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.swiped(_:)))
            swipe.direction = direction
            swipe.delegate = context.coordinator
            tap.require(toFail: swipe)
            scroll.addGestureRecognizer(swipe)
        }
        context.coordinator.tapped = tapped
        context.coordinator.swiped = swiped
        return scroll
    }

    func updateUIView(_ scroll: MangaPageScrollView, context: Context) {
        context.coordinator.host.rootView = EdgeToEdgeContent(content: content)
        context.coordinator.tapped = tapped
        context.coordinator.swiped = swiped
        if context.coordinator.pageID != pageID || context.coordinator.rotation != rotation {
            context.coordinator.pageID = pageID
            context.coordinator.rotation = rotation
            scroll.resetViewport()
        }
        scroll.setNeedsLayout()
    }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        let host: UIHostingController<EdgeToEdgeContent>
        var tapped: (CGFloat) -> Void = { _ in }
        var swiped: (Int) -> Void = { _ in }
        var pageID: String?
        var rotation: ReaderPageRotation?
        init(_ host: UIHostingController<EdgeToEdgeContent>) { self.host = host }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { host.view }
        func scrollViewDidZoom(_ scrollView: UIScrollView) { scrollView.panGestureRecognizer.isEnabled = scrollView.zoomScale > 1.01 }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let scroll = gestureRecognizer.view as? UIScrollView else { return false }
            return scroll.zoomScale <= 1.01
        }
        @objc func swiped(_ gesture: UISwipeGestureRecognizer) {
            swiped(gesture.direction == .left ? 1 : -1)
        }
        @objc func singleTapped(_ gesture: UITapGestureRecognizer) {
            guard let scroll = gesture.view as? UIScrollView, scroll.bounds.width > 0 else { return }
            tapped((gesture.location(in: scroll).x - scroll.bounds.minX) / scroll.bounds.width)
        }
        @objc func doubleTapped(_ gesture: UITapGestureRecognizer) {
            guard let scroll = gesture.view as? UIScrollView else { return }
            if scroll.zoomScale > 1 { scroll.setZoomScale(1, animated: true); return }
            let point = gesture.location(in: host.view)
            let size = CGSize(width: scroll.bounds.width / 2.5, height: scroll.bounds.height / 2.5)
            scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
        }
    }
}

/// Layout follows the real UIKit viewport, not a deferred block holding an earlier SwiftUI
/// update. A resize or quarter turn resets the fitted frame before accepting another zoom.
final class MangaPageScrollView: UIScrollView {
    weak var pageView: UIView?
    private var viewport = CGSize.zero
    private var layingOut = false

    func resetViewport() {
        layer.removeAllAnimations()
        pageView?.layer.removeAllAnimations()
        setZoomScale(1, animated: false)
        panGestureRecognizer.isEnabled = false
        contentOffset = .zero
        viewport = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !layingOut, bounds.width > 0, bounds.height > 0, let pageView else { return }
        layingOut = true
        defer { layingOut = false }
        if viewport != bounds.size {
            setZoomScale(1, animated: false)
            viewport = bounds.size
            contentOffset = .zero
            pageView.transform = .identity
            pageView.frame = CGRect(origin: .zero, size: viewport)
            contentSize = viewport
        } else if zoomScale == 1 {
            pageView.frame = CGRect(origin: .zero, size: viewport)
            contentSize = viewport
        }
    }
}

/// Lets SwiftUI taps reach the vertical reader's zoom.
@MainActor final class MangaZoomController {
    fileprivate weak var view: MangaZoomView?
    /// Double tap: zooms in around `point` (in the column's own, unzoomed space), or back out.
    func toggle(at point: CGPoint) {
        guard let view else { return }
        view.toggleZoom(at: view.content.convert(point, to: view))
    }
}

/// Zooms the vertical reader's whole scrolling column, the way Mihon's webtoon reader does, so its pages stay lazy.
struct MangaPinchZoom<Content: View>: UIViewRepresentable {
    let controller: MangaZoomController
    let rotation: ReaderPageRotation
    @ViewBuilder let content: Content

    // SwiftUI's root modifier provides the same edge-to-edge column on iOS 16.2,
    // before UIHostingController exposes safeAreaRegions in iOS 16.4.
    struct EdgeToEdgeContent: View {
        let content: Content
        var body: some View { content.ignoresSafeArea() }
    }

    func makeCoordinator() -> UIHostingController<EdgeToEdgeContent> {
        UIHostingController(rootView: EdgeToEdgeContent(content: content))
    }

    func makeUIView(context: Context) -> MangaZoomView {
        let host = context.coordinator
        host.view.backgroundColor = .clear
        if #available(iOS 16.4, *) { host.safeAreaRegions = [] }
        let view = MangaZoomView(content: host.view)
        view.rotation = rotation
        controller.view = view
        return view
    }

    func updateUIView(_ view: MangaZoomView, context: Context) {
        view.rotation = rotation
        context.coordinator.rootView = EdgeToEdgeContent(content: content)
        controller.view = view
    }
}

/// Scales and moves `content` with a transform, like a photo: the spot between the fingers stays under them while
/// they pinch and move; one finger pans sideways when zoomed (the column's own scroll view keeps scrolling it down),
/// and past its top or bottom moves the zoomed view up or down. Zoom past the limits gives a little, then springs back.
final class MangaZoomView: UIView, UIGestureRecognizerDelegate {
    let content: UIView
    let maxScale: CGFloat = 4
    private(set) var scale: CGFloat = 1
    /// The content's centre, from the view's centre.
    private var offset = CGPoint.zero
    /// The last pinch centre, from the view's centre.
    private var focal = CGPoint.zero
    private var touches = 0
    private let pinch = UIPinchGestureRecognizer()
    private let pan = UIPanGestureRecognizer()
    private weak var foundScroll: UIScrollView?
    var rotation: ReaderPageRotation = .upright {
        didSet {
            guard rotation != oldValue else { return }
            content.layer.removeAllAnimations()
            scale = 1; offset = .zero; touches = 0
            scroll?.panGestureRecognizer.isEnabled = true
            apply()
        }
    }

    init(content: UIView) {
        self.content = content
        super.init(frame: .zero)
        clipsToBounds = true
        addSubview(content)
        pinch.addTarget(self, action: #selector(pinched(_:)))
        pan.addTarget(self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = false
        for recognizer in [pinch, pan] as [UIGestureRecognizer] {
            recognizer.delegate = self
            addGestureRecognizer(recognizer)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        content.bounds = CGRect(origin: .zero, size: bounds.size)
        content.center = CGPoint(x: bounds.midX, y: bounds.midY)
        offset = clamped(offset, scale: scale)
        apply()
    }

    /// The column's own scroll view (SwiftUI's ScrollView is a UIScrollView underneath).
    private var scroll: UIScrollView? {
        if let foundScroll, foundScroll.isDescendant(of: content) { return foundScroll }
        var queue = [content]
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if let scroll = view as? UIScrollView { foundScroll = scroll; return scroll }
            queue += view.subviews
        }
        return nil
    }

    private func apply() {
        content.transform = CGAffineTransform(translationX: offset.x, y: offset.y).scaledBy(x: scale, y: scale)
        // Zoomed, the edges move the view instead of stretching the column.
        scroll?.bounces = scale <= 1.01
    }

    private func centred(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x - bounds.midX, y: point.y - bounds.midY) }

    /// Keeps the zoomed content covering the view.
    private func clamped(_ offset: CGPoint, scale: CGFloat) -> CGPoint {
        let x = max(0, (scale - 1) * bounds.width / 2), y = max(0, (scale - 1) * bounds.height / 2)
        return CGPoint(x: min(x, max(-x, offset.x)), y: min(y, max(-y, offset.y)))
    }

    /// The offset that puts the content point now under `from` under `to` at `newScale`.
    private func anchored(_ from: CGPoint, at to: CGPoint, scale newScale: CGFloat) -> CGPoint {
        let point = CGPoint(x: (from.x - offset.x) / scale, y: (from.y - offset.y) / scale)
        return CGPoint(x: to.x - point.x * newScale, y: to.y - point.y * newScale)
    }

    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        let location = centred(gesture.location(in: self))
        switch gesture.state {
        case .began:
            focal = location
            touches = gesture.numberOfTouches
            // Two fingers both pinch and move; the column must not scroll with them as well.
            scroll?.panGestureRecognizer.isEnabled = false
            fallthrough
        case .changed:
            // A finger lifted or landed moves the centre point; start from there without a jump.
            if gesture.numberOfTouches != touches { touches = gesture.numberOfTouches; focal = location; gesture.scale = 1; return }
            // Past the limits the zoom gives less and less.
            let step = scale > maxScale || scale < 1 ? pow(gesture.scale, 0.35) : gesture.scale
            let newScale = min(maxScale * 1.6, max(0.6, scale * step))
            gesture.scale = 1
            offset = clamped(anchored(focal, at: location, scale: newScale), scale: newScale)
            scale = newScale
            focal = location
            apply()
        case .ended, .cancelled, .failed:
            scroll?.panGestureRecognizer.isEnabled = true
            let settled = min(maxScale, max(1, scale))
            zoom(to: settled, offset: anchored(focal, at: focal, scale: settled))
        default: break
        }
    }

    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        let move = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)
        guard pinch.state != .began, pinch.state != .changed else { return }
        var next = offset
        next.x += move.x
        // The column scrolls itself; only at its top or bottom does the zoomed view move up or down.
        if let scroll {
            let top = -scroll.adjustedContentInset.top
            let bottom = max(top, scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height)
            if (move.y > 0 && scroll.contentOffset.y <= top + 1) || (move.y < 0 && scroll.contentOffset.y >= bottom - 1) { next.y += move.y }
        }
        offset = clamped(next, scale: scale)
        apply()
        if gesture.state == .ended {
            // Glide on sideways, as a scroll view would.
            let velocity = gesture.velocity(in: self).x
            let target = clamped(CGPoint(x: offset.x + velocity * 0.25, y: offset.y), scale: scale)
            guard target.x != offset.x else { return }
            offset = target
            UIView.animate(withDuration: 0.5, delay: 0, options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]) { self.apply() }
        }
    }

    func toggleZoom(at point: CGPoint) {
        if scale > 1.01 { zoom(to: 1, offset: .zero); return }
        let location = centred(point)
        zoom(to: 2.5, offset: anchored(location, at: location, scale: 2.5))
    }

    private func zoom(to newScale: CGFloat, offset newOffset: CGPoint) {
        scale = newScale <= 1.01 ? 1 : newScale
        offset = clamped(newOffset, scale: scale)
        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState]) { self.apply() }
    }

    override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        gesture === pan ? scale > 1.01 : super.gestureRecognizerShouldBegin(gesture)
    }

    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
#endif

// MARK: - Controls

private struct MangaReaderChrome: View {
    /// Dark glass: the chrome sits on white pages as often as dark ones, and its labels are white.
    static let glass = GlassStyle.regular.tint(.black.opacity(0.45)).interactive()
    #if os(tvOS)
    private static let titleFont = Font.system(size: 29, weight: .semibold), chapterFont = Font.system(size: 23)
    private static let pillInset: CGFloat = 26, pillHeight: CGFloat = 76
    #else
    private static let titleFont = Font.subheadline.weight(.semibold), chapterFont = Font.caption
    private static let pillInset: CGFloat = 14, pillHeight: CGFloat = 40
    #endif
    let model: MangaReaderModel
    let visible: Bool
    @Binding var showsChapters: Bool
    let close: () -> Void

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                top
                Spacer(minLength: 0)
                bottom
            }
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .animation(.appSmooth(duration: 0.2), value: visible)
            #if os(macOS)
            .ignoresSafeArea(.container, edges: .top)
            .background { WithPerceptionTracking { MangaHidesWindowButtons() } }
            #endif
        }
    }

    private var top: some View {
        HStack(spacing: 14) {
            #if !os(tvOS)
            Button(action: close) { Image(systemName: "xmark").font(.headline).frame(width: 36, height: 36).iosTouchTarget() }
                .buttonStyle(.plain).glassSurface(MangaReaderChrome.glass, in: Circle())
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel(L10n.text("Close"))
            #endif
            VStack(alignment: .leading, spacing: 1) {
                Text(model.comic.title).font(Self.titleFont).lineLimit(1)
                if !model.single { Text(model.title(model.position.chapter)).font(Self.chapterFont).foregroundStyle(.white.opacity(0.75)).lineLimit(1) }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, Self.pillInset).frame(minHeight: Self.pillHeight)
            .glassSurface(MangaReaderChrome.glass, in: Capsule())
            .layoutPriority(-1)
            Spacer(minLength: 0)
            #if !os(tvOS)
            Button { model.rotation = model.rotation.next } label: {
                WithPerceptionTracking {
                    VStack(spacing: 1) {
                        Image(systemName: "rotate.right").font(.headline)
                        Text("\(model.rotation.rawValue)°").font(.system(size: 9, weight: .semibold).monospacedDigit())
                    }
                    .frame(width: 36, height: 36).iosTouchTarget()
                }
            }
            .buttonStyle(.plain).glassSurface(MangaReaderChrome.glass, in: Circle())
            .accessibilityLabel("顺时针旋转 90 度")
            .accessibilityValue("\(model.rotation.rawValue) 度")
            .contextMenu {
                Button("复原旋转") { model.rotation = .upright }
            }
            Menu {
                WithPerceptionTracking {
                    Picker(L10n.text("Reading Mode"), selection: Binding(get: { model.mode }, set: { mode in
                        let position = model.position
                        model.mode = mode
                        model.target = position
                    })) {
                        ForEach(MangaReaderMode.allCases) { perceptionArgument0 in WithPerceptionTracking { Label(perceptionArgument0.title, systemImage: perceptionArgument0.symbol).tag(perceptionArgument0) } }
                    }
                }
            } label: { WithPerceptionTracking { Image(systemName: model.mode.symbol).font(.headline).frame(width: 36, height: 36).iosTouchTarget() } }
            .menuStyle(.button).buttonStyle(.plain).glassSurface(MangaReaderChrome.glass, in: Circle())
            .accessibilityLabel(L10n.text("Reading Mode"))
            if !model.single {
                Button { showsChapters = true } label: { Image(systemName: "list.bullet").font(.headline).frame(width: 36, height: 36).iosTouchTarget() }
                    .buttonStyle(.plain).glassSurface(MangaReaderChrome.glass, in: Circle())
                    .accessibilityLabel(L10n.text("Chapters"))
            }
            #endif
        }
        #if os(macOS)
        // Up in the title bar, lined up with the bottom bar. Under the 52 pt title bar the top bar sat much further
        // from the top edge than the bottom bar sits from the bottom.
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 10)
        #else
        .padding(.horizontal, 16).padding(.vertical, 10)
        #endif
        .background(LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }

    #if os(tvOS)
    /// Apple TV has no slider and the remote turns the pages, so the bar only says where you are: a short track and the
    /// page count in one pill, centred, like the TV app's scrubber.
    private var bottom: some View {
        let count = max(model.currentPages.count, 1)
        let page = min(model.position.page + 1, count)
        let track: CGFloat = 420
        return HStack(spacing: 24) {
            // Fills from the left in every reading mode, as progress bars do on the TV: filled from the right for
            // right-to-left comics, page 1 was a tick at the far end and read as the last page. The empty track stays dark
            // so it doesn't pass for filled over a white page.
            Capsule().fill(.black.opacity(0.35)).frame(width: track, height: 8)
                .overlay(alignment: .leading) {
                    WithPerceptionTracking {
                        Capsule().fill(.white).frame(width: max(track * CGFloat(page) / CGFloat(count), 8), height: 8)
                    }
                }
            Text("\(page) / \(count)").font(.system(size: 26, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
        }
        .padding(.horizontal, 32).padding(.vertical, 18)
        .glassSurface(MangaReaderChrome.glass, in: Capsule())
        .frame(maxWidth: .infinity)
        .padding(.bottom, 40)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(page) / \(count)")
    }
    #else
    private var bottom: some View {
        let count = model.currentPages.count
        return HStack(spacing: 12) {
            #if !os(tvOS)
            Button { Task { await model.open(model.position.chapter - 1) } } label: { Image(systemName: "backward.end.fill").frame(width: 32, height: 32).iosTouchTarget() }
                .buttonStyle(.plain).disabled(!model.hasPrevious).opacity(model.hasPrevious ? 1 : 0.35)
                .accessibilityLabel(L10n.text("Previous Chapter"))
            if count > 1 {
                Slider(value: Binding(get: { Double(min(model.position.page, count - 1)) },
                                      set: { value in model.requestPage(.init(chapter: model.position.chapter, page: Int(value.rounded()))) }),
                       in: 0...Double(count - 1), step: 1)
                    .tint(.white)
                    .environment(\.layoutDirection, model.mode == .rightToLeft ? .rightToLeft : .leftToRight)
            } else { Spacer() }
            #else
            Spacer()
            #endif
            Text("\(min(model.position.page + 1, max(count, 1))) / \(max(count, 1))").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            #if !os(tvOS)
            Button { Task { await model.open(model.position.chapter + 1) } } label: { Image(systemName: "forward.end.fill").frame(width: 32, height: 32).iosTouchTarget() }
                .buttonStyle(.plain).disabled(!model.hasNext).opacity(model.hasNext ? 1 : 0.35)
                .accessibilityLabel(L10n.text("Next Chapter"))
            #endif
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .glassSurface(MangaReaderChrome.glass, in: Capsule())
        .padding(.horizontal, 16).padding(.bottom, 12)
    }
    #endif
}

/// The comic's chapters, the one being read marked; picking one opens it.
private struct MangaChapterPicker: View {
    let model: MangaReaderModel
    let pick: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        WithPerceptionTracking {
            NavigationStack {
                WithPerceptionTracking {
                    ScrollViewReader { reader in
                        WithPerceptionTracking {
                            List(Array(model.chapters.enumerated()), id: \.offset) { index, chapter in
                                WithPerceptionTracking {
                                    Button { pick(index) } label: {
                                        HStack {
                                            Text(chapter.title).foregroundStyle(.primary)
                                            Spacer()
                                            if index == model.position.chapter { Image(systemName: "book.fill").foregroundStyle(Brand.cyan) }
                                        }
                                    }
                                    .id(index)
                                }
                            }
                            .onAppear { reader.scrollTo(model.position.chapter, anchor: .center) }
                        }
                    }
                    .navigationTitle(L10n.text("Chapters"))
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .toolbar { WithPerceptionTracking {  ToolbarItem(placement: .cancellationAction) { Button(L10n.text("Close")) { dismiss() } }   }}
                }
            }
            #if os(macOS)
            .frame(minWidth: 360, minHeight: 480)
            #endif
            .presentationDetents([.medium, .large])
        }
    }
}

#if os(macOS)
/// Hides the window's close, minimise and zoom buttons while the reader is open, so its top bar can sit in the title bar
/// lined up with the bottom bar: with the toolbar hidden, macOS fades them in when the pointer comes near, over the bar's
/// close button. The reader's own close button, Esc and Command-W still close it; the buttons come back with it.
private struct MangaHidesWindowButtons: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ probe: Probe, context: Context) {}

    final class Probe: NSView {
        private static let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            show(true, in: window)
            show(false, in: newWindow)
        }
        private func show(_ shown: Bool, in window: NSWindow?) {
            for kind in Self.kinds { window?.standardWindowButton(kind)?.isHidden = !shown }
        }
    }
}
#endif
