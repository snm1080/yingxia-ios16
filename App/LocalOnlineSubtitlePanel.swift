import SwiftUI
import Perception
@preconcurrency import AVFoundation
import TVCore

#if !os(tvOS)
struct LocalOnlineSubtitlePanel: View {
    let session: PlaybackSession
    let channel: Channel
    #if os(iOS)
    @Binding var target: SubtitleTrackSelection.Target
    var applied: (SubtitleTrackSelection.Target) -> Void = { _ in }
    #else
    private let target = SubtitleTrackSelection.Target.primary
    #endif
    @Environment(\.openURL) private var openURL
    @State private var query = ""
    @State private var items: [JSONValue] = []
    @State private var files: [JSONValue] = []
    @State private var fileChoices: [JSONValue] = []
    @State private var selectedCandidate: JSONValue?
    @State private var searchID = ""
    @State private var busy = false
    @State private var status = ""
    @State private var providerNotices: [String] = []
    @State private var work: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var operationTarget = SubtitleTrackSelection.Target.primary
    @State private var operationIntent = UUID()
    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 12) {
                Text("搜索在线字幕").font(.headline)
                #if os(iOS)
                Picker("应用到", selection: $target) {
                    ForEach(SubtitleTrackSelection.Target.allCases, id: \.self) { target in Text(target.title).tag(target) }
                }.pickerStyle(.segmented)
                Text("下载后应用到" + target.title).font(.caption).foregroundStyle(.secondary)
                if target == .secondary && (session.aiSubtitles.generate || session.aiSubtitles.translate) {
                    Text("AI 字幕优先显示；关闭 AI 字幕后显示所选副字幕。").font(.caption).foregroundStyle(.secondary)
                }
                #endif
                HStack {
                    #if os(iOS)
                    TextField("片名或剧集", text: $query).textFieldStyle(LocalGlassTextFieldStyle()).onSubmit { search() }
                    #else
                    TextField("片名或剧集", text: $query).textFieldStyle(.roundedBorder).onSubmit { search() }
                    #endif
                    Button("搜索") { search() }.disabled(busy || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if busy { Button("取消") { cancel(); status = "已取消" } }
                }
                Text("点击字幕下载并应用；包含多种语言或集数时，可分别选择文件。").font(.caption).foregroundStyle(.secondary)
                if busy { ProgressView() }
                if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
                ForEach(providerNotices, id: \.self) { notice in
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Button { choose(item) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.object?["name"]?.string ?? "字幕")
                            Text(candidateDetail(item)).font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(busy)
                }
                if !fileChoices.isEmpty {
                    HStack {
                        Text(selectedCandidate?.object?["name"]?.string ?? "选择字幕文件").font(.subheadline.bold())
                        Spacer()
                        Button("收起") { fileChoices = []; selectedCandidate = nil }
                    }
                    ForEach(Array(fileChoices.enumerated()), id: \.offset) { _, file in
                        Button(file.object?["name"]?.string ?? "下载字幕") {
                            if let selectedCandidate { download(selectedCandidate, fileID: file.object?["id"]?.string) }
                        }.frame(minHeight: 44).disabled(busy)
                    }
                }
                if !files.isEmpty {
                    Text("已下载字幕").font(.headline)
                    ForEach(Array(files.enumerated()), id: \.offset) { _, file in
                        HStack(alignment: .top) {
                            Button { load(file) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(file.object?["name"]?.string ?? "字幕文件")
                                    Text(applicationStatus(file))
                                        .font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            }.buttonStyle(.plain).disabled(busy)
                            Button("删除", role: .destructive) { remove(file) }.frame(minHeight: 44).disabled(busy)
                        }
                    }
                }
            }
            .task(id: session.mediaEnhancements.sessionID) {
                cancel(); items = []; files = []; fileChoices = []; selectedCandidate = nil; providerNotices = []
                query = channel.historyContext?.videoName ?? channel.name
                refreshFiles()
            }
            .onDisappear { cancel() }
            #if os(iOS)
            .appOnChange(of: target) { _, _ in cancel(); status = "" }
            #endif
        }
    }
    private func candidateDetail(_ item: JSONValue) -> String {
        var details = [item.object?["provider"]?.string, item.object?["language"]?.string, item.object?["format"]?.string].compactMap { $0 }.filter { !$0.isEmpty }
        if item.object?["conflict"] == .bool(true) { details.append("季集可能不匹配") }
        if item.object?["externalUrl"]?.string != nil { details.append("在网站下载") }
        return details.joined(separator: " · ")
    }
    private func applicationStatus(_ file: JSONValue) -> String {
        let id = documentID(file)
        if session.externalSubtitles.selected == id { return "已应用到主字幕" }
        if session.externalSubtitles.secondarySelected == id { return "已应用到副字幕" }
        #if os(iOS)
        return "已下载，点击应用到" + target.title
        #else
        return "已下载，点击应用"
        #endif
    }
    private func documentID(_ file: JSONValue) -> String { "online-subtitle:" + (file.object?["id"]?.string ?? "") }
    private func cancel() { generation = UUID(); work?.cancel(); work = nil; busy = false }
    private func run(_ action: @escaping @MainActor ([String: JSONValue]) async throws -> Void) {
        guard !busy else { return }
        let active = UUID(), scope = session.mediaEnhancements.serviceParams
        generation = active; busy = true; status = ""
        operationTarget = target; operationIntent = session.externalSubtitles.intentRevision
        work = Task {
            defer { if generation == active { busy = false; work = nil } }
            do { try await action(scope) }
            catch { if generation == active && !Task.isCancelled {
                status = error is CancellationError ? "已取消应用，请重新选择字幕" : error.localizedDescription
            } }
        }
    }
    private func request(_ method: String, _ input: [String: JSONValue]) async throws -> JSONValue {
        try Task.checkCancellation()
        guard input["sessionId"] == session.mediaEnhancements.serviceParams["sessionId"] else { throw CancellationError() }
        let result = try await MobileMediaServices.call(method, input)
        try Task.checkCancellation()
        guard input["sessionId"] == session.mediaEnhancements.serviceParams["sessionId"] else { throw CancellationError() }
        return result
    }
    private func search() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        run { scope in
            try await LocalMediaServiceSettings.apply()
            try Task.checkCancellation()
            var input = scope; input["query"] = .string(text)
            items = []; fileChoices = []; selectedCandidate = nil; providerNotices = []
            let result = try await request("subtitle.search", input)
            searchID = result.object?["searchId"]?.string ?? ""; items = result.object?["items"]?.array ?? []
            let notices = (result.object?["warnings"]?.array ?? []) + (result.object?["errors"]?.array ?? [])
            let providers = result.object?["providers"]?.array ?? []
            let completed = providers.contains { $0.object?["state"]?.string == "complete" }
            status = items.isEmpty ? (!providers.isEmpty && !completed ? "本次搜索的字幕来源暂不可用" : "未找到匹配字幕") : "找到 \(items.count) 个字幕"
            providerNotices = notices.compactMap { item in
                guard let message = item.object?["message"]?.string else { return nil }
                let names = ["shooter": "射手", "xunlei": "迅雷", "assrt": "Assrt", "subtitlecat": "SubtitleCat", "subhd": "SubHD"]
                let provider = item.object?["provider"]?.string ?? ""
                return [names[provider] ?? provider, message].filter { !$0.isEmpty }.joined(separator: "：")
            }
        }
    }
    private func refreshFiles() {
        run { scope in files = try await request("subtitle.list", scope).object?["files"]?.array ?? [] }
    }
    private func choose(_ item: JSONValue) {
        if let address = item.object?["externalUrl"]?.string, let url = URL(string: address), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
            openURL(url); return
        }
        run { scope in
            var input = scope; input["searchId"] = .string(searchID); input["candidateId"] = item.object?["id"]
            let result = try await request("subtitle.files", input)
            let choices = result.object?["files"]?.array ?? []
            if choices.count > 1 {
                selectedCandidate = item; fileChoices = choices
                status = "找到 \(choices.count) 个文件，请选择语言或集数；只下载所选文件。"
            } else { try await performDownload(item, fileID: choices.first?.object?["id"]?.string, scope: scope) }
        }
    }
    private func download(_ item: JSONValue, fileID: String?) { run { scope in try await performDownload(item, fileID: fileID, scope: scope) } }
    private func performDownload(_ item: JSONValue, fileID: String?, scope: [String: JSONValue]) async throws {
        var input = scope; input["searchId"] = .string(searchID); input["candidateId"] = item.object?["id"]
        if let fileID { input["fileId"] = .string(fileID) }
        status = "正在下载字幕…"
        let result = try await request("subtitle.download", input)
        let downloaded = result.object?["files"]?.array ?? []
        files = try await request("subtitle.list", scope).object?["files"]?.array ?? []
        fileChoices = []; selectedCandidate = nil
        guard !downloaded.isEmpty else { throw TVError.unsupported("下载结果没有可用字幕") }
        if downloaded.count == 1, let first = downloaded.first { try await performLoad(first, scope: scope) }
        else { status = "已下载 \(downloaded.count) 个字幕，请选择需要的语言或集数。" }
    }
    private func load(_ file: JSONValue) { run { scope in try await performLoad(file, scope: scope) } }
    private func remove(_ file: JSONValue) {
        run { scope in
            var input = scope; input["assetId"] = file.object?["id"]
            _ = try await request("subtitle.delete", input)
            let wasSelected = session.externalSubtitles.selected == documentID(file) || session.externalSubtitles.secondarySelected == documentID(file)
            session.externalSubtitles.removeImported(documentID(file))
            files = try await request("subtitle.list", scope).object?["files"]?.array ?? []
            status = wasSelected ? "字幕已删除，对应字幕位置已关闭" : "已删除下载文件"
        }
    }
    private func performLoad(_ file: JSONValue, scope: [String: JSONValue]) async throws {
        let applicationTarget = operationTarget, intent = operationIntent
        var input = scope; input["assetId"] = file.object?["id"]
        let result = try await request("subtitle.asset", input)
        guard target == applicationTarget, session.externalSubtitles.intentRevision == intent else { throw CancellationError() }
        guard let encoded = result.object?["data"]?.string, let data = Data(base64Encoded: encoded) else { throw TVError.unsupported("字幕下载数据无效") }
        try session.externalSubtitles.add(data: data, name: result.object?["name"]?.string ?? "在线字幕.srt", id: documentID(file), target: applicationTarget)
        #if os(iOS)
        status = "已应用到" + applicationTarget.title + "：" + (file.object?["name"]?.string ?? "在线字幕")
        applied(applicationTarget)
        #else
        status = "已应用字幕：" + (file.object?["name"]?.string ?? "在线字幕")
        #endif
    }
}

#if os(iOS)
struct LocalAISubtitlePlayerPanel: View {
    let session: PlaybackSession
    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("AI 生成字幕", isOn: Binding(get: { session.aiSubtitles.generate }, set: { session.aiSubtitles.configure(generate: $0) })).settingsSwitch()
                    Toggle("AI 翻译字幕", isOn: Binding(get: { session.aiSubtitles.translate }, set: { session.aiSubtitles.configure(translate: $0) })).settingsSwitch()
                }.padding(14).localGlassInputSurface(cornerRadius: 16)
                Text(session.aiSubtitles.generate ? "翻译将使用 AI 从当前音轨生成的文字，原文与译文显示在副字幕位置。" : "单独翻译使用当前主字幕文字。开启生成后，可从当前音轨识别原文。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("先在设置的「AI 字幕」中选择离线语言包或在线服务。离线音频留在设备上；在线识别发送音频，翻译发送文字。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if session.isLive {
                    Text("直播目前无法定位并采集音频片段，暂不支持 AI 字幕；点播视频就绪后可开启。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .top, spacing: 10) {
                    if session.aiSubtitles.busy { ProgressView() }
                    Text(session.aiSubtitles.status).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = session.aiSubtitles.generationError, error != session.aiSubtitles.status {
                    Text(error).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if session.aiSubtitles.generate || session.aiSubtitles.translate {
                    Button("关闭 AI 字幕") { session.aiSubtitles.stop() }.settingsButton()
                }
            }
        }
    }
}
#endif
#endif
