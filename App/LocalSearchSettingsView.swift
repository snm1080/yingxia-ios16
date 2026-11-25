import SwiftUI
import Perception
import TVCore

struct LocalSearchSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let config: Subscription
    @State private var preferences: LocalSearchPreferences
    @State private var selectedGroup: String?
    @State private var query = ""
    init(config: Subscription) {
        self.config = config
        let preferences = LocalSearchPreferences.load(config: config)
        _preferences = State(initialValue: preferences)
        _selectedGroup = State(initialValue: preferences.groups.first?.id)
    }
    private var sites: [Site] { config.sites.filter { $0.searchable && $0.canBrowse(jarURL: config.spiderURL) } }
    private var visible: [Site] { sites.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query.trimmingCharacters(in: .whitespacesAndNewlines)) } }
    private var groupIndex: Int? { preferences.groups.firstIndex { $0.id == selectedGroup } }
    private func enabled(_ site: Site) -> Bool {
        let id = LocalSearchPreferences.memberID(for: site)
        if preferences.mode == .default { return !preferences.disabledSiteIDs.contains(id) }
        return groupIndex.map { preferences.groups[$0].siteIDs.contains(id) } ?? false
    }
    private func set(_ site: Site, _ enabled: Bool) {
        let id = LocalSearchPreferences.memberID(for: site)
        if preferences.mode == .default {
            if enabled { preferences.disabledSiteIDs.remove(id) } else { preferences.disabledSiteIDs.insert(id) }
        } else if let index = groupIndex {
            preferences.groups[index].siteIDs.removeAll { $0 == id }
            if enabled { preferences.groups[index].siteIDs.append(id) }
        }
    }
    var body: some View {
        WithPerceptionTracking {
            #if os(iOS)
            settingsForm
                .textFieldStyle(LocalGlassTextFieldStyle())
                .scrollContentBackground(.hidden)
                .scrollDismissesKeyboard(.interactively)
            #else
            NavigationStack {
                settingsForm
                    .navigationTitle("搜索设置")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                    }
            }
            #endif
        }
    }

    private var settingsForm: some View {
        WithPerceptionTracking {
            Form {
                Section {
                    #if os(iOS)
                    LocalGlassChoicePicker(title: "搜索模式", selection: $preferences.mode,
                                           options: LocalSearchPreferences.Mode.allCases.map { .init($0, $0.title) })
                    #else
                    Picker("搜索模式", selection: $preferences.mode) {
                        ForEach(LocalSearchPreferences.Mode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
                    }.pickerStyle(.segmented)
                    #endif
                    Text(preferences.mode == .all ? "查询所有支持搜索的站点，不受默认开关影响。" : preferences.mode == .default ? "勾选默认搜索的站点；关闭的站点仍可在全部模式中搜索。" : "按分组选择站点；同一站点加入多个分组只查询一次，首先显示第一个分组。")
                        .font(.system(size: 15)).foregroundStyle(.secondary)
                }.listRowBackground(Color.clear)
                if preferences.mode == .groups {
                    Section("搜索分组") {
                        ForEach(Array(preferences.groups.enumerated()), id: \.element.id) { index, group in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Button { selectedGroup = group.id } label: {
                                        Image(systemName: selectedGroup == group.id ? "checkmark.circle.fill" : "circle")
                                            .frame(width: 44, height: 44).contentShape(Rectangle())
                                    }.accessibilityLabel("选择分组 \(group.name)")
                                    TextField("分组名称", text: $preferences.groups[index].name).frame(minHeight: 44)
                                }
                                HStack(spacing: 12) {
                                    Spacer(minLength: 0)
                                    Button { preferences.groups.swapAt(index, index - 1) } label: {
                                        Image(systemName: "arrow.up").frame(width: 44, height: 44).contentShape(Rectangle())
                                    }.disabled(index == 0).accessibilityLabel("上移分组 \(group.name)")
                                    Button { preferences.groups.swapAt(index, index + 1) } label: {
                                        Image(systemName: "arrow.down").frame(width: 44, height: 44).contentShape(Rectangle())
                                    }.disabled(index + 1 == preferences.groups.count).accessibilityLabel("下移分组 \(group.name)")
                                    Button(role: .destructive) {
                                        preferences.groups.removeAll { $0.id == group.id }
                                        if selectedGroup == group.id { selectedGroup = preferences.groups.first?.id }
                                    } label: {
                                        Image(systemName: "trash").frame(width: 44, height: 44).contentShape(Rectangle())
                                    }.accessibilityLabel("删除分组 \(group.name)")
                                }
                            }
                            .buttonStyle(.borderless)
                        }
                        Button("新增分组") {
                            let group = LocalSearchPreferences.Group(name: "分组 \(preferences.groups.count + 1)")
                            preferences.groups.append(group); selectedGroup = group.id
                        }.disabled(preferences.groups.count >= 32)
                    }.listRowBackground(Color.clear)
                }
                if preferences.mode != .all {
                    Section(preferences.mode == .default ? "默认参与的站点" : "当前分组的站点") {
                        TextField("筛选站点", text: $query)
                        HStack {
                            Button("全选") { visible.forEach { set($0, true) } }
                            Spacer()
                            Button("全不选") { visible.forEach { set($0, false) } }
                        }
                        ForEach(visible) { site in
                            Toggle(site.name, isOn: Binding(get: { enabled(site) }, set: { set(site, $0) }))
                        }
                    }.listRowBackground(Color.clear)
                        .disabled(preferences.mode == .groups && groupIndex == nil)
                }
            }
            .appOnChange(of: preferences) { _, value in value.save(config: config) }
        }
    }
}
