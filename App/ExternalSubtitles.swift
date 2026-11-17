@preconcurrency import AVFoundation
import SwiftUI
import Perception
import TVCore
import UniformTypeIdentifiers

/// Subtitle files the app shows over the picture itself (#576): those a source offers beside a video AVPlayer plays
/// directly (an MP4, an HLS stream), which used to be dropped, and those the viewer adds while watching. A file the
/// repackager made a track of (`Remux.subtitleSources`) stays AVPlayer's.
///
/// They load after the picture starts, never before it. One that fails says why and can be tried again; it never
/// stops the video. Choosing one turns the item's own subtitles off, and choosing one of those turns this off.
@MainActor @Perceptible final class ExternalSubtitles {
    struct Entry: Identifiable, Equatable {
        enum State: Equatable { case loading, ready(SubtitleDocument), failed(String) }
        let id: String
        let name: String
        /// Added by the viewer rather than offered by the source.
        let imported: Bool
        var state: State
        /// What to fetch again.
        var subtitle: ExternalSubtitle?

        var document: SubtitleDocument? { if case .ready(let document) = state { document } else { nil } }
        var title: String {
            let language = document?.language ?? subtitle.map { $0.language.isEmpty ? SubtitleMatch.language($0.name) : $0.language } ?? ""
            guard !language.isEmpty, let named = Locale.current.localizedString(forIdentifier: language) else { return name }
            return "\(named) · \(name)"
        }
    }

    private(set) var entries: [Entry] = []
    typealias Target = SubtitleTrackSelection.Target
    private var primarySelected: String?
    private var fallbackSecondarySelected: String?
    var importTarget: Target = .primary
    private(set) var intentRevision = UUID()
    var selected: String? { selection(for: .primary) }
    var secondarySelected: String? { selection(for: .secondary) }
    func selection(for target: Target) -> String? {
        #if os(iOS)
        if let engine {
            // Observe the published request, so a native choice or moving the other slot
            // also updates online status. Automatic selection only considers native tracks.
            let id = target == .primary ? engine.subtitleSelection : engine.secondarySubtitleSelection
            return entries.first { $0.id == id && $0.document != nil }?.id
        }
        #endif
        return target == .primary ? primarySelected : fallbackSecondarySelected
    }
    private(set) var timing = SubtitleTiming()
    /// A file or address the viewer added that couldn't be read, for an alert.
    var importFailure: String?
    var document: SubtitleDocument? { entries.first { $0.id == selected }?.document }

    /// The player shows what is chosen; set by the session.
    @PerceptionIgnored var cues: SubtitleCues?
    @PerceptionIgnored weak var player: AVPlayer?
    #if os(iOS)
    @PerceptionIgnored weak var engine: KSPlaybackEngine?
    #endif
    /// Runs when a file is chosen or put away, for the session's clock.
    @PerceptionIgnored var changed: () -> Void = {}
    @PerceptionIgnored private var headers: [String: String] = [:]
    @PerceptionIgnored private var scope: String?
    @PerceptionIgnored private var loading: Task<Void, Never>?
    @PerceptionIgnored private var requestIDs: [String: UUID] = [:]
    @PerceptionIgnored private var retries: [String: Task<Void, Never>] = [:]
    /// The first file that loads comes on by itself, unless the viewer chose (or the video has its own on).
    @PerceptionIgnored private var automatic = true
    @PerceptionIgnored private var generation = UUID()
    /// At most this many of a source's files, three at a time.
    static let limit = 8, concurrent = 3

    /// A new episode: its source's files, after the picture.
    func begin(_ channel: Channel, playing url: URL) {
        stop()
        headers = channel.headers
        scope = channel.historyContext?.id ?? channel.skipScope
        timing = SubtitleTimingStore.load(scope: scope)
        cues?.timing = timing
        let included = Remux.subtitleSources(url)
        // The title names the episode ("第02集", "S01E02") more often than a drive's address does.
        let file = channel.url.lastPathComponent.removingPercentEncoding ?? channel.url.lastPathComponent
        let video = SubtitleMatch.episode(channel.name) != nil || file.isEmpty ? channel.name : file
        var seen = Set<URL>()
        let wanted = SubtitleMatch.candidates(channel.subtitles, video: video)
            .filter { !included.contains($0.url) && seen.insert($0.url).inserted }.prefix(Self.limit)
        guard !wanted.isEmpty else { return }
        entries = wanted.map { Entry(id: $0.url.absoluteString, name: $0.name, imported: false, state: .loading, subtitle: $0) }
        Diagnostics.shared.record(.info, "subtitles", "external files=\(wanted.count) of=\(channel.subtitles.count) in-stream=\(included.count)")
        let active = generation, headers = headers
        let requests = Dictionary(uniqueKeysWithValues: wanted.map { ($0.url.absoluteString, UUID()) })
        requestIDs.merge(requests) { _, next in next }
        loading = Task { [weak self] in
            await withTaskGroup(of: (String, UUID, Result<SubtitleDocument, Error>).self) { group in
                var queued = wanted.makeIterator(), running = 0
                func next() {
                    guard let subtitle = queued.next() else { return }
                    running += 1
                    group.addTask { (subtitle.url.absoluteString, requests[subtitle.url.absoluteString]!, await Self.fetch(subtitle, headers: headers)) }
                }
                for _ in 0..<Self.concurrent { next() }
                while running > 0, let (id, requestID, result) = await group.next() {
                    running -= 1
                    guard let self, self.generation == active, !Task.isCancelled else { group.cancelAll(); return }
                    if self.requestIDs[id] == requestID {
                        self.requestIDs[id] = nil
                        self.finish(id, result)
                    }
                    next()
                }
            }
        }
    }

    /// The episode plays from another address now (repackaged after AVPlayer refused it): the source's files that
    /// became tracks of the stream are AVPlayer's from here on.
    func playing(_ url: URL) {
        let included = Remux.subtitleSources(url)
        guard !included.isEmpty else { return }
        entries.removeAll { entry in
            guard !entry.imported, let source = entry.subtitle?.url, included.contains(source) else { return false }
            retries[entry.id]?.cancel(); requestIDs[entry.id] = nil
            #if os(iOS)
            engine?.removeExternalSubtitle(entry.id)
            #endif
            return true
        }
        if let primarySelected, !entries.contains(where: { $0.id == primarySelected }) { self.primarySelected = nil }
        show()
    }

    #if os(iOS)
    /// The playback session owns same-work reopens; an engine input ID changes even
    /// when its current episode and subtitle intent stay the same.
    func prepareForReopen() {
        generation = UUID(); intentRevision = UUID()
        loading?.cancel(); loading = nil
        retries.values.forEach { $0.cancel() }; retries = [:]; requestIDs = [:]
        cues?.show(nil, timing: timing, at: nil)
    }

    /// Re-register retained bytes after engine shutdown, then resume only unfinished loads.
    /// Existing native/Off requests have already been restored from the session snapshot.
    func restoreAfterReopen(_ channel: Channel) {
        headers = channel.headers
        for entry in entries {
            if let document = entry.document { engine?.registerExternalSubtitle(document, timing: timing) }
        }
        show()
        let active = generation
        for entry in entries {
            guard case .loading = entry.state else { continue }
            let source = entry.subtitle ?? URL(string: entry.id).flatMap { url in
                ["http", "https"].contains(url.scheme?.lowercased() ?? "") ? ExternalSubtitle(name: entry.name, url: url) : nil
            }
            guard let source else { continue }
            let id = entry.id, requestID = UUID(), headers = entry.imported ? [:] : headers
            requestIDs[id] = requestID
            retries[id] = Task { [weak self] in
                let result = await Self.fetch(source, headers: headers)
                guard let self, self.generation == active, self.requestIDs[id] == requestID, !Task.isCancelled else { return }
                self.retries[id] = nil; self.requestIDs[id] = nil
                self.finish(id, result)
            }
        }
    }
    #endif

    /// Puts everything away: the episode ended or another began.
    func stop() {
        generation = UUID(); intentRevision = UUID()
        loading?.cancel(); loading = nil
        retries.values.forEach { $0.cancel() }; retries = [:]; requestIDs = [:]
        #if os(iOS)
        for entry in entries { engine?.removeExternalSubtitle(entry.id) }
        #endif
        entries = []; automatic = true; importFailure = nil
        primarySelected = nil; fallbackSecondarySelected = nil
        show()
    }

    func select(_ id: String?, target: Target = .primary) {
        automatic = false; intentRevision = UUID()
        if let id, !entries.contains(where: { $0.id == id && $0.document != nil }) { return }
        if target == .primary {
            primarySelected = id
            if id != nil && fallbackSecondarySelected == id { fallbackSecondarySelected = nil }
        } else {
            fallbackSecondarySelected = id
            if id != nil && primarySelected == id { primarySelected = nil }
        }
        #if os(iOS)
        if let engine {
            if target == .primary { engine.selectSubtitle(id: id ?? "no") }
            else { engine.selectSecondarySubtitle(id: id ?? "no") }
            show(); return
        }
        #endif
        if let id, target == .primary {
            let active = generation
            Task {
                guard self.generation == active, self.selected == id else { return }
                await self.nativeOff()
            }
        }
        show()
    }

    /// Call after selecting an embedded track; the matching external slot makes way.
    func nativeChosen(target: Target = .primary) {
        automatic = false; intentRevision = UUID()
        if target == .primary { primarySelected = nil } else { fallbackSecondarySelected = nil }
        show()
    }

    func retry(_ id: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }), let subtitle = entries[index].subtitle else { return }
        entries[index].state = .loading
        automatic = false; intentRevision = UUID()
        let active = generation, headers = headers, requestID = UUID(), target = importTarget, intent = intentRevision
        requestIDs[id] = requestID
        retries[id]?.cancel()
        retries[id] = Task { [weak self] in
            let result = await Self.fetch(subtitle, headers: headers)
            guard let self, self.generation == active, self.requestIDs[id] == requestID, !Task.isCancelled else { return }
            self.retries[id] = nil; self.requestIDs[id] = nil
            self.finish(id, result, target: self.intentRevision == intent ? target : nil)
        }
    }

    /// The chosen file read again with another text encoding.
    func read(as encoding: SubtitleEncoding) {
        guard let index = entries.firstIndex(where: { $0.id == selected }), let document = entries[index].document,
              document.encoding != encoding else { return }
        do {
            let next = try document.reading(as: encoding)
            entries[index].state = .ready(next)
            #if os(iOS)
            engine?.registerExternalSubtitle(next, timing: timing)
            #endif
            show()
        } catch {
            importFailure = error.localizedDescription
        }
    }

    func setTiming(_ next: SubtitleTiming) {
        guard next != timing else { return }
        timing = next
        SubtitleTimingStore.save(next, scope: scope)
        cues?.timing = next
        #if os(iOS)
        engine?.setExternalSubtitleTiming(next)
        #endif
    }

    /// A file picked on this device or dropped on the player; it comes on.
    func add(file url: URL) {
        do { add(try SubtitleDocument.load(file: url), target: importTarget) }
        catch { fail(url.lastPathComponent, error) }
    }

    #if os(iOS)
    /// A native Files result keeps its copy/grant through the background provider read. Media
    /// changes cancel the task and cannot add old subtitles to the next episode.
    func add(selection: LocalDocumentSelection) {
        automatic = false; intentRevision = UUID()
        let url = selection.urls[0], active = generation, id = url.absoluteString, target = importTarget, requestID = UUID(), intent = intentRevision
        requestIDs[id] = requestID
        retries[id]?.cancel()
        retries[id] = Task { [weak self] in
            defer { selection.release() }
            do {
                let data = try await selection.readData(maxBytes: 8 * 1024 * 1024)
                let document = try SubtitleDocument(id: id, name: url.lastPathComponent, data: data)
                try Task.checkCancellation()
                guard let self, self.generation == active, self.requestIDs[id] == requestID else { return }
                self.retries[id] = nil; self.requestIDs[id] = nil
                self.add(document, target: self.intentRevision == intent ? target : nil)
            } catch {
                guard let self, self.generation == active, self.requestIDs[id] == requestID, !Task.isCancelled else { return }
                self.retries[id] = nil; self.requestIDs[id] = nil
                if !(error is CancellationError) { self.fail(url.lastPathComponent, error) }
            }
        }
    }
    #endif

    /// A file at an address the viewer typed; it comes on once loaded.
    func add(address text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            importFailure = L10n.text("Enter an address that starts with http:// or https://.")
            return
        }
        automatic = false; intentRevision = UUID()
        let id = url.absoluteString, active = generation, target = importTarget, requestID = UUID(), intent = intentRevision
        retries[id]?.cancel(); requestIDs[id] = requestID
        if !entries.contains(where: { $0.id == id }) {
            entries.append(Entry(id: id, name: url.lastPathComponent, imported: true, state: .loading))
        }
        retries[id] = Task { [weak self] in
            let result = await Self.fetch(address: url)
            guard let self, self.generation == active, self.requestIDs[id] == requestID, !Task.isCancelled else { return }
            self.retries[id] = nil; self.requestIDs[id] = nil
            if case .failure(let error) = result { self.fail(url.lastPathComponent, error) }
            self.finish(id, result, target: self.intentRevision == intent ? target : nil)
        }
    }

    /// A downloaded or generated subtitle uses the same rendering and native-track arbitration.
    func add(data: Data, name: String, id: String = UUID().uuidString, target: Target = .primary) throws {
        add(try SubtitleDocument(id: id, name: name, data: data), target: target)
    }

    /// Removing an online download also removes its imported document from the active track list.
    func removeImported(_ id: String) {
        guard entries.contains(where: { $0.id == id && $0.imported }) else { return }
        retries[id]?.cancel(); retries[id] = nil; requestIDs[id] = nil
        #if os(iOS)
        engine?.removeExternalSubtitle(id)
        #endif
        if primarySelected == id { primarySelected = nil }
        if fallbackSecondarySelected == id { fallbackSecondarySelected = nil }
        entries.removeAll { $0.id == id && $0.imported }
        show()
    }

    private func add(_ document: SubtitleDocument, target: Target?) {
        retries[document.id]?.cancel(); retries[document.id] = nil; requestIDs[document.id] = nil
        entries.removeAll { $0.id == document.id }
        entries.append(Entry(id: document.id, name: document.name, imported: true, state: .ready(document)))
        Diagnostics.shared.record(.info, "subtitles", "imported format=\(document.format.rawValue) cues=\(document.cues.count)")
        #if os(iOS)
        engine?.registerExternalSubtitle(document, timing: timing)
        #endif
        // A replacement may have the same ID/encoding/cue count; force its fresh source into the primary renderer.
        if selected == document.id { cues?.show(nil, timing: timing, at: nil) }
        if let target { select(document.id, target: target) } else { show() }
    }

    private func fail(_ name: String, _ error: Error) {
        importFailure = "\(name): \(error.localizedDescription)"
    }

    private func finish(_ id: String, _ result: Result<SubtitleDocument, Error>, target: Target? = nil) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        switch result {
        case .success(let document):
            entries[index].state = .ready(document)
            #if os(iOS)
            engine?.registerExternalSubtitle(document, timing: timing)
            #endif
            if selected == id { cues?.show(nil, timing: timing, at: nil) }
            if let target { select(id, target: target) }
            if selected == id { show() }
        case .failure(let error):
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            Diagnostics.shared.record(.warning, "subtitles", "external host=\(entries[index].subtitle?.url.host() ?? "-") \(error.localizedDescription)")
            entries[index].state = .failed(error.localizedDescription)
        }
        chooseAutomatically()
    }

    /// The best file (the first, by `SubtitleMatch`) comes on once it has loaded, unless the video shows its own
    /// subtitles or the viewer chose. One that failed gives way to the next.
    private func chooseAutomatically() {
        guard automatic, let best = entries.first(where: { if case .failed = $0.state { false } else { true } }), best.document != nil else { return }
        automatic = false
        let active = generation, intent = intentRevision
        Task {
            guard await self.nativeShowing() != true, self.generation == active, self.selected == nil, self.intentRevision == intent else { return }
            self.select(best.id)
        }
    }

    private func show() {
        #if os(iOS)
        cues?.show(document, timing: timing, at: engine?.position ?? player?.currentTime().seconds)
        #else
        cues?.show(document, timing: timing, at: player?.currentTime().seconds)
        #endif
        changed()
    }

    /// Whether the item shows one of its own subtitles now; nil when it has none.
    private func nativeShowing() async -> Bool? {
        #if os(iOS)
        if let engine { return engine.tracks.contains { $0.kind == .subtitle && $0.selected } }
        #endif
        guard let item = player?.currentItem, let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) else { return nil }
        return item.currentMediaSelection.selectedMediaOption(in: group).map { !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) } ?? false
    }

    /// The item's own subtitles off, so the two don't show at once.
    private func nativeOff() async {
        #if os(iOS)
        if let engine { engine.selectSubtitle(id: "no"); return }
        #endif
        let active = generation, chosen = selected
        guard let item = player?.currentItem, let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
              generation == active, selected == chosen, player?.currentItem === item, group.allowsEmptySelection, item.currentMediaSelection.selectedMediaOption(in: group) != nil else { return }
        item.select(nil, in: group)
    }

    nonisolated private static func fetch(_ subtitle: ExternalSubtitle, headers: [String: String]) async -> Result<SubtitleDocument, Error> {
        do { return .success(try await SubtitleDocument.load(subtitle, headers: headers)) } catch { return .failure(error) }
    }

    nonisolated private static func fetch(address url: URL) async -> Result<SubtitleDocument, Error> {
        do { return .success(try await SubtitleDocument.load(address: url)) } catch { return .failure(error) }
    }

    /// The kinds of file the import panels offer.
    static let types: [UTType] = ["srt", "vtt", "ass", "ssa"].compactMap { UTType(filenameExtension: $0) } + [.plainText]
    static func handles(_ url: URL) -> Bool { ["srt", "vtt", "ass", "ssa"].contains(url.pathExtension.lowercased()) }
}


#if !os(tvOS)
/// The subtitle-file part of the player's Subtitles menu, on iPhone, iPad and Mac: the files, adding one, and the
/// chosen one's encoding, frame rate and timing.
struct ExternalSubtitleMenu: View {
    let subtitles: ExternalSubtitles
    let addFile: () -> Void
    let addAddress: () -> Void

    var body: some View {
        WithPerceptionTracking {
            if !subtitles.entries.isEmpty {
                Section(L10n.text("Subtitle Files")) {
                    ForEach(subtitles.entries) { entry in
                        WithPerceptionTracking {
                            switch entry.state {
                            case .ready:
                                Toggle(entry.title, isOn: Binding(get: { subtitles.selected == entry.id }, set: { subtitles.select($0 ? entry.id : nil) }))
                            case .loading:
                                Text(L10n.text("%@ (loading)", entry.title))
                            case .failed(let reason):
                                if entry.subtitle != nil {
                                    Button(L10n.text("%@: Try Again", entry.title)) { subtitles.retry(entry.id) }
                                }
                                Text(reason)
                            }
                        }
                    }
                }
            }
            Section {
                Button(L10n.text("Add Subtitle File…"), action: addFile)
                Button(L10n.text("Add Subtitles from Address…"), action: addAddress)
            }
            if let document = subtitles.document {
                Section {
                    if document.format.isStyled {
                        Text(L10n.text("ASS styling and effects show as plain text."))
                    }
                    Menu(L10n.text("Text Encoding")) {
                        WithPerceptionTracking {
                            Picker(L10n.text("Text Encoding"), selection: Binding(get: { document.encoding }, set: { subtitles.read(as: $0) })) {
                                ForEach(SubtitleEncoding.allCases) { perceptionArgument0 in WithPerceptionTracking { Text(perceptionArgument0.title).tag(perceptionArgument0) } }
                            }
                            .pickerStyle(.inline)
                        }
                    }
                    Menu(L10n.text("Frame Rate")) {
                        WithPerceptionTracking {
                            Picker(L10n.text("Frame Rate"), selection: Binding(get: { subtitles.timing.rate?.id ?? "" },
                                                                             set: { id in subtitles.setTiming(SubtitleTiming(delay: subtitles.timing.delay, scale: SubtitleTiming.rates.first { $0.id == id }?.scale ?? 1)) })) {
                                Text(L10n.text("As Made")).tag("")
                                ForEach(SubtitleTiming.rates) { perceptionArgument0 in WithPerceptionTracking { Text(L10n.text("%@ fps", perceptionArgument0.title)).tag(perceptionArgument0.id) } }
                            }
                            .pickerStyle(.inline)
                        }
                    }
                    ExternalSubtitleDelayMenu(subtitles: subtitles)
                }
            }
        }
    }
}

/// The chosen file's timing: half a second at a time, earlier as well as later.
struct ExternalSubtitleDelayMenu: View {
    let subtitles: ExternalSubtitles
    var body: some View {
        WithPerceptionTracking {
            Menu(L10n.text("Subtitle Delay")) {
                WithPerceptionTracking {
                    Text(subtitles.timing.title)
                    Button(String(format: "%+.1f s", -SubtitleTiming.step)) { shift(-SubtitleTiming.step) }
                        .disabled(subtitles.timing.delay <= SubtitleTiming.delays.lowerBound)
                    Button(String(format: "%+.1f s", SubtitleTiming.step)) { shift(SubtitleTiming.step) }
                        .disabled(subtitles.timing.delay >= SubtitleTiming.delays.upperBound)
                    if !subtitles.timing.isIdentity {
                        Button(L10n.text("Reset")) { subtitles.setTiming(SubtitleTiming()) }
                    }
                }
            }
        }
    }
    private func shift(_ seconds: Double) {
        subtitles.setTiming(SubtitleTiming(delay: subtitles.timing.delay + seconds, scale: subtitles.timing.scale))
    }
}

/// Asks for a subtitle file's address.
struct SubtitleAddressPrompt: ViewModifier {
    @Binding var isPresented: Bool
    let subtitles: ExternalSubtitles
    @State private var address = ""
    func body(content: Content) -> some View {
        WithPerceptionTracking {
            content
                .alert(L10n.text("Add Subtitles from Address"), isPresented: $isPresented) {
                    WithPerceptionTracking {
                        TextField("https://…", text: $address)
                            #if os(iOS)
                            .keyboardType(.URL).textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()
                        Button(L10n.text("Cancel"), role: .cancel) { address = "" }
                        Button(L10n.text("Add")) { subtitles.add(address: address); address = "" }
                    }
                } message: {
                    WithPerceptionTracking {
                        Text(L10n.text("An SRT, WebVTT or ASS file, up to 8 MB."))
                    }
                }
                .alert(L10n.text("Subtitles Not Added"), isPresented: Binding(get: { subtitles.importFailure != nil }, set: { if !$0 { subtitles.importFailure = nil } })) {
                    WithPerceptionTracking {
                        Button(L10n.text("OK"), role: .cancel) { subtitles.importFailure = nil }
                    }
                } message: {
                    WithPerceptionTracking {
                        Text(subtitles.importFailure ?? "")
                    }
                }
        }
    }
}

extension View {
    /// The file panel and address prompt that add subtitles to the playing video.
    func subtitleImport(files: Binding<Bool>, address: Binding<Bool>, subtitles: ExternalSubtitles) -> some View {
        #if os(iOS)
        localDocumentImporter(isPresented: files, kind: .subtitleFile) { result in
            switch result {
            case .success(let selection): subtitles.add(selection: selection)
            case .failure(let error): subtitles.importFailure = error.localizedDescription
            }
        }
        .modifier(SubtitleAddressPrompt(isPresented: address, subtitles: subtitles))
        #else
        fileImporter(isPresented: files, allowedContentTypes: ExternalSubtitles.types) { result in
            switch result {
            case .success(let url): subtitles.add(file: url)
            case .failure(let error): subtitles.importFailure = error.localizedDescription
            }
        }
        .modifier(SubtitleAddressPrompt(isPresented: address, subtitles: subtitles))
        #endif
    }
}
#endif

#if os(iOS)
extension SubtitleTrackSelection.Target {
    var title: String { self == .primary ? "主字幕" : "副字幕" }
}
#endif
