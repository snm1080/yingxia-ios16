import SwiftUI
import TVCore

struct TMDBServiceSettingsView: View {
    @State private var config = TMDBServiceSettings.load()
    @State private var message: String?
    @State private var credentialType = TMDBServiceSettings.load().token.isEmpty ? "apiKey" : "token"
    var body: some View {
        SettingsPage(title: "TMDB", symbol: "film.stack") {
            SettingsGroup(footer: "默认使用内置 TMDB。关闭自定义后保留已填写的配置。") {
                Toggle("自定义 TMDB", isOn: $config.enabled)
                    .appOnChange(of: config.enabled) { _, enabled in if !enabled { save() } }
            }
            if config.enabled {
                SettingsGroup(title: "自定义 TMDB") {
                    Toggle("超清海报", isOn: $config.ultraHD)
                    Picker("凭据类型", selection: $credentialType) {
                        Text("API Key (v3)").tag("apiKey")
                        Text("Read Access Token").tag("token")
                    }
                    SecureField(credentialType == "token" ? "TMDB Read Access Token" : "TMDB API Key", text: credential)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if !config.credential.isEmpty {
                        Button("清除已保存的密钥") { config.apiKey = ""; config.token = ""; message = "密钥将在保存后清除" }
                    }
                    TextField("语言", text: $config.language, prompt: Text("zh-CN"))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("API 地址", text: $config.apiBase, prompt: Text(TMDBServiceSettings.defaultAPIBase))
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("图片地址", text: $config.imageBase, prompt: Text(TMDBServiceSettings.defaultImageBase))
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Toggle("使用代理", isOn: $config.proxyEnabled)
                    if config.proxyEnabled {
                        TextField("代理地址", text: $config.proxyUrl, prompt: Text("http://127.0.0.1:7890"))
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("代理账号（可选）", text: $config.proxyUsername)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("代理密码（可选）", text: $config.proxyPassword)
                        if !config.proxyPassword.isEmpty { Button("清除已保存的代理密码") { config.proxyPassword = ""; message = "代理密码将在保存后清除" } }
                        Text("支持 HTTP、HTTPS、SOCKS5；TMDB API 与图片使用相同代理。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("保存 TMDB 设置", action: save).settingsButton(prominent: true)
                }
            }
            if let message { SettingsGroup { Text(message).font(.footnote).foregroundStyle(.secondary) } }
        }
    }
    private var credential: Binding<String> {
        Binding(get: { credentialType == "token" ? config.token : config.apiKey }, set: {
            if credentialType == "token" { config.token = $0; config.apiKey = "" }
            else { config.apiKey = $0; config.token = "" }
        })
    }
    private func save() {
        do {
            if credentialType == "token" { config.apiKey = "" }
            else { config.token = "" }
            try config.save()
            message = config.enabled ? "已保存自定义 TMDB" : "已使用内置 TMDB"
        } catch { message = "配置无效，请检查 API、图片和代理地址。" }
    }
}
