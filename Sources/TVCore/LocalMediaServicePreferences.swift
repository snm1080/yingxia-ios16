import Foundation

/// Draft values stay outside UserDefaults until the user saves the complete form.
/// The same values construct the runtime request, so UI defaults cannot drift.
public struct LocalOnlineSubtitlePreferences: Equatable, Sendable {
    public var xunlei = true, shooter = true, assrt = true, subtitlecat = false, subhd = false
    public var language = "zh", assrtToken = ""
    public init() {}
    public static func load(defaults: UserDefaults = .standard) -> Self {
        var value = Self()
        for key in ["xunlei", "shooter", "assrt", "subtitlecat", "subhd"] {
            if let enabled = defaults.object(forKey: "onlineSubtitle." + key) as? Bool {
                switch key { case "xunlei": value.xunlei = enabled; case "shooter": value.shooter = enabled
                case "assrt": value.assrt = enabled; case "subtitlecat": value.subtitlecat = enabled; default: value.subhd = enabled }
            }
        }
        value.language = defaults.string(forKey: "onlineSubtitle.language") ?? value.language
        value.assrtToken = defaults.string(forKey: "onlineSubtitle.assrtToken") ?? ""
        return value
    }
    public var values: [String: JSONValue] {
        ["xunlei": .bool(xunlei), "shooter": .bool(shooter), "assrt": .bool(assrt), "subtitlecat": .bool(subtitlecat),
         "subhd": .bool(subhd), "language": .string(language), "assrtToken": .string(assrtToken)]
    }
    public func save(defaults: UserDefaults = .standard) throws {
        guard ["zh", "en"].contains(language), !assrtToken.contains(where: { $0.isNewline }) else { throw LocalMediaPreferenceError.invalidValue }
        persistMediaPreferences(values, prefix: "onlineSubtitle.", defaults: defaults)
    }
}

public struct LocalAISubtitlePreferences: Equatable, Sendable {
    public var enabled = false
    public var endpoint = "", serviceProtocol = "chat", model = "", apiKey = "", targetLanguage = "zh-CN"
    public var transcriptionEndpoint = "", transcriptionModel = "whisper-1", transcriptionApiKey = ""
    public var transcriptionProtocol = "transcription", transcriptionUseTranslation = false, localASRLocale = "zh-CN"
    public init() {}
    public static func load(defaults: UserDefaults = .standard) -> Self {
        var value = Self()
        value.enabled = defaults.bool(forKey: "aiSubtitle.enabled")
        value.transcriptionUseTranslation = defaults.bool(forKey: "aiSubtitle.transcriptionUseTranslation")
        for (key, path) in stringFields { if let saved = defaults.string(forKey: "aiSubtitle." + key) { value[keyPath: path] = saved } }
        return value
    }
    private static var stringFields: [(String, WritableKeyPath<Self, String>)] { [
        ("endpoint", \.endpoint), ("protocol", \.serviceProtocol), ("model", \.model), ("apiKey", \.apiKey),
        ("targetLanguage", \.targetLanguage), ("transcriptionEndpoint", \.transcriptionEndpoint),
        ("transcriptionModel", \.transcriptionModel), ("transcriptionApiKey", \.transcriptionApiKey),
        ("transcriptionProtocol", \.transcriptionProtocol), ("localASRLocale", \.localASRLocale),
    ] }
    public var values: [String: JSONValue] {
        var values = Dictionary(uniqueKeysWithValues: Self.stringFields.map { ($0.0, JSONValue.string(self[keyPath: $0.1])) })
        values["enabled"] = .bool(enabled); values["transcriptionUseTranslation"] = .bool(transcriptionUseTranslation)
        return values
    }
    /// Remote speech can reuse only a provider that accepts chat/completions
    /// audio input. Switching protocols never silently changes this preference.
    public var canShareTranscriptionService: Bool { ["chat", "deepseek"].contains(serviceProtocol) }
    public var usesSharedTranscriptionService: Bool { transcriptionProtocol == "chat" && transcriptionUseTranslation }
    public func validate() throws {
        guard ["chat", "anthropic", "deepseek", "responses", "gemini"].contains(serviceProtocol),
              ["local", "chat", "transcription"].contains(transcriptionProtocol) else {
            throw LocalMediaPreferenceError.invalidValue
        }
        // Keep inactive drafts intact. They must not prevent selecting offline
        // speech or turning off the service that would use those fields.
        guard enabled else { return }
        guard targetLanguage.range(of: #"^[A-Za-z][A-Za-z0-9-]{1,63}$"#, options: .regularExpression) != nil,
              !apiKey.contains(where: { $0.isNewline }) else { throw LocalMediaPreferenceError.invalidValue }
        if usesSharedTranscriptionService && !canShareTranscriptionService {
            throw LocalMediaPreferenceError.incompatibleSpeechProvider
        }
        var addresses = [endpoint]
        if transcriptionProtocol != "local" && !usesSharedTranscriptionService {
            guard !transcriptionApiKey.contains(where: { $0.isNewline }) else { throw LocalMediaPreferenceError.invalidValue }
            addresses.append(transcriptionEndpoint)
        }
        for address in addresses where !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let url = URL(string: address), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil, url.user == nil, url.password == nil, url.fragment == nil else { throw LocalMediaPreferenceError.invalidAddress }
        }
    }
    public func validateTest(_ kind: String) throws {
        try validate()
        if kind == "transcription" && transcriptionProtocol == "local" { return }
        guard enabled else { throw LocalMediaPreferenceError.onlineDisabled }
        let address: String, selectedModel: String
        if kind == "transcription" && !usesSharedTranscriptionService {
            address = transcriptionEndpoint.isEmpty ? endpoint : transcriptionEndpoint
            selectedModel = transcriptionModel
        } else { address = endpoint; selectedModel = model }
        guard !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !selectedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalMediaPreferenceError.incompleteAIService
        }
    }
    public func save(defaults: UserDefaults = .standard) throws {
        try validate()
        persistMediaPreferences(values, prefix: "aiSubtitle.", defaults: defaults)
    }
}

private func persistMediaPreferences(_ values: [String: JSONValue], prefix: String, defaults: UserDefaults) {
    for (key, value) in values {
        switch value {
        case .bool(let enabled): defaults.set(enabled, forKey: prefix + key)
        case .string(let text): defaults.set(text, forKey: prefix + key)
        default: break
        }
    }
}

public enum LocalMediaPreferenceError: LocalizedError {
    case invalidValue, invalidAddress, incompatibleSpeechProvider, onlineDisabled, incompleteAIService
    public var errorDescription: String? {
        switch self {
        case .invalidValue: "请检查协议、语言和密钥格式。"
        case .incompatibleSpeechProvider: "当前翻译协议不支持复用音频接口，请选择 OpenAI 兼容协议或单独配置语音服务。"
        case .onlineDisabled: "请先启用在线字幕服务。离线语音包可单独使用。"
        case .incompleteAIService: "请填写当前接口的服务地址和模型后再测试。"
        case .invalidAddress: "服务地址须为 HTTP / HTTPS，账号和密钥请填写在独立字段中。"
        }
    }
}
