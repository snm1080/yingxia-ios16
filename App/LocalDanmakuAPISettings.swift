import SwiftUI
import Perception
import TVCore

struct LocalDanmakuAPISettings: View {
    var hasBuiltin = false
    @State private var model = LocalDanmakuAPISettingsModel()
    var body: some View {
        SettingsGroup(title: "弹幕 API 列表") {
            if hasBuiltin {
                Toggle("内置（当前订阅自带的弹幕）", isOn: Binding(get: { model.builtin }, set: { model.setBuiltinEnabled($0) })).settingsSwitch()
            }
            ForEach(model.entries) { api in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Toggle(api.name, isOn: Binding(get: { api.enabled }, set: { model.setEnabled($0, id: api.id) })).settingsSwitch()
                        Button { model.beginEditing(api.id) } label: {
                            Image(systemName: "pencil").frame(width: 44, height: 44)
                        }.buttonStyle(.plain).accessibilityLabel("编辑 " + api.name).disabled(model.isEditing)
                        Button(role: .destructive) { model.remove(api.id) } label: {
                            Image(systemName: "trash").frame(width: 44, height: 44)
                        }.buttonStyle(.plain).accessibilityLabel("删除 " + api.name)
                    }
                    Text(api.url).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }.padding(.vertical, 3).accessibilityElement(children: .contain).accessibilityIdentifier("settings.danmaku.api." + api.name)
            }
            if model.isEditing {
                TextField("API 名称", text: $model.name).accessibilityIdentifier("settings.danmaku.api.name")
                TextField("HTTP / HTTPS API 地址", text: $model.address).keyboardType(.URL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("settings.danmaku.api.address")
                HStack {
                    Button("取消") { model.cancelEditing() }
                    Spacer()
                    Button("保存 API") { model.save() }.settingsButton(prominent: true)
                        .accessibilityIdentifier("settings.danmaku.api.save")
                }.buttonStyle(.borderless)
            } else {
                Button("添加 API") { model.beginAdding() }.settingsButton(prominent: true)
                    .accessibilityIdentifier("settings.danmaku.api.add")
            }
            if !model.message.isEmpty { Text(model.message).font(.caption).foregroundStyle(.secondary) }
            Text("自动匹配只使用已启用的 API，按列表顺序尝试。支持 Dandanplay 兼容的搜索、分集与弹幕协议。自建服务（如 LogVar）需要 token 时，请填写带 token 的完整地址，例如 https://example.com:88/你的token，否则服务器会返回 401 未授权。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
