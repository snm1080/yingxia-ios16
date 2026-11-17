#if os(iOS)
import SwiftUI
import Perception
import TVCore

struct LocalAISubtitleSettingsView: View {
    @State private var config = LocalAISubtitlePreferences.load()
    @State private var status = ""
    @State private var busy = false
    @State private var testJob: Task<Void, Never>?
    @State private var testTicket = UUID()

    var body: some View {
        SettingsPage(title: "AI 字幕", symbol: "waveform") {
            SettingsGroup(title: "字幕翻译", footer: "在播放器中开启「AI 翻译字幕」，可翻译主字幕或语音生成的文字。在线开关控制翻译与在线语音，离线识别可以独立使用。") {
                Toggle("启用在线语音与翻译", isOn: $config.enabled).settingsSwitch().disabled(busy)
                if config.enabled {
                    translationFields.disabled(busy)
                } else {
                    Text("需要翻译时开启在线服务，再填写翻译接口；仅生成原文字幕可保持关闭。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            SettingsGroup(title: "语音生成字幕", footer: "在播放器中开启「AI 生成字幕」，使用当前音轨生成原文字幕。") {
                LocalGlassChoicePicker(title: "语音生成方式", selection: $config.transcriptionProtocol, options: [
                    .init("local", "离线语音识别"), .init("transcription", "在线语音转写"), .init("chat", "在线多模态识别")
                ]).disabled(busy)
                Text(config.transcriptionProtocol == "local" ? "下载语言包后即可使用，无需启用在线服务。" : "在线识别会把当前音轨片段发送到所配置的语音服务。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if config.transcriptionProtocol == "local" {
                    Text("离线语言包").font(.subheadline.weight(.semibold))
                    NativeLocalASRModelSettings(locale: $config.localASRLocale)
                } else if config.enabled {
                    onlineSpeechFields.disabled(busy)
                } else {
                    Text("启用上方在线服务后，可配置语音接口。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            SettingsGroup(footer: "保存后应用到播放器。接口测试会先保存当前填写内容，再测试对应服务。") {
                Button("保存 AI 字幕设置") { save() }
                    .settingsButton(prominent: true).disabled(busy).accessibilityIdentifier("settings.ai.save")
                if config != LocalAISubtitlePreferences.load() {
                    Text("有尚未保存的设置").font(.caption).foregroundStyle(.secondary)
                }
                if busy {
                    ProgressView("正在测试…")
                    Button("取消测试") { cancelTest() }.settingsButton()
                }
                if !status.isEmpty {
                    Text(status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.ai.status")
                }
            }
        }
        .appOnChange(of: config.serviceProtocol) { _, _ in
            if !config.canShareTranscriptionService { config.transcriptionUseTranslation = false }
        }
        .onAppear {
            if !config.canShareTranscriptionService { config.transcriptionUseTranslation = false }
        }
        .onDisappear { cancelTest(showStatus: false) }
    }
    private var translationFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            LocalGlassChoicePicker(title: "翻译协议", selection: $config.serviceProtocol, options: [
                .init("chat", "OpenAI 兼容"), .init("anthropic", "Anthropic"), .init("deepseek", "DeepSeek"),
                .init("responses", "OpenAI Responses"), .init("gemini", "Gemini")
            ])
            field("服务地址", placeholder: "https://…", text: $config.endpoint, url: true)
            field("翻译模型", placeholder: "服务提供的模型名称", text: $config.model)
            secret("翻译 API Key", text: $config.apiKey)
            field("目标语言", placeholder: "例如 zh-CN、en、ja", text: $config.targetLanguage)
            Button("保存并测试翻译") { test("translation") }.settingsButton()
        }
    }
    private var onlineSpeechFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            if config.transcriptionProtocol == "chat" {
                if config.canShareTranscriptionService {
                    Toggle("复用翻译服务和模型", isOn: $config.transcriptionUseTranslation).settingsSwitch()
                    if config.transcriptionUseTranslation {
                        Text("复用上方翻译服务。所选模型还需支持音频输入，请通过语音测试确认。")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("当前翻译协议需要单独配置多模态语音接口。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !config.usesSharedTranscriptionService {
                field("语音服务地址", placeholder: "留空使用翻译地址", text: $config.transcriptionEndpoint, url: true)
                field("语音模型", placeholder: "语音转写或音频模型名称", text: $config.transcriptionModel)
                secret("语音 API Key", text: $config.transcriptionApiKey)
                Text("密钥留空时，仅在语音与翻译服务来自同一域名时复用翻译密钥。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Button("保存并测试语音") { test("transcription") }.settingsButton()
        }
    }
    private func field(_ title: String, placeholder: String, text: Binding<String>, url: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            TextField(placeholder, text: text).keyboardType(url ? .URL : .default)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .textFieldStyle(LocalGlassTextFieldStyle()).accessibilityLabel(title)
        }
    }
    private func secret(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            SecureField("按服务要求填写", text: text).textInputAutocapitalization(.never).autocorrectionDisabled()
                .textFieldStyle(LocalGlassTextFieldStyle()).accessibilityLabel(title)
            if !text.wrappedValue.isEmpty {
                Button("清除密钥") { text.wrappedValue = ""; status = "清除后请保存设置" }.font(.caption)
            }
        }
    }
    private func save() {
        do { try config.save(); status = "已保存，播放器将使用当前设置" }
        catch { status = error.localizedDescription }
    }
    private func test(_ kind: String) {
        guard !busy else { return }
        do { try config.validateTest(kind); try config.save() }
        catch { status = error.localizedDescription; return }
        let saved = config, ticket = UUID(); testTicket = ticket
        busy = true; status = "设置已保存，正在测试…"
        testJob = Task { @MainActor in
            defer { if testTicket == ticket { busy = false; testJob = nil } }
            do {
                try Task.checkCancellation()
                try await MobileMediaServices.configure([
                    "subtitles": .object(LocalOnlineSubtitlePreferences.load().values), "ai": .object(saved.values)
                ])
                try Task.checkCancellation()
                let result = try await MobileMediaServices.call("ai.test", ["kind": .string(kind)])
                try Task.checkCancellation()
                guard testTicket == ticket else { return }
                status = result.object?["text"]?.string ?? "测试通过"
            } catch {
                guard testTicket == ticket, !(error is CancellationError) else { return }
                status = error.localizedDescription
            }
        }
    }
    private func cancelTest(showStatus: Bool = true) {
        guard busy else { return }
        testTicket = UUID(); testJob?.cancel(); testJob = nil; busy = false
        if showStatus { status = "测试已取消，已保存的设置仍保留" }
    }
}
#endif
