import SwiftUI
import Perception
import TVCore

/// Shared destination for the two independent Settings and home-panel entry points.
struct LocalSourceSettingsView: View {
    @Environment(Store.self) private var store
    let kind: LocalSourceGroup
    private var group: LocalSourceGroup { kind }
    init(kind: LocalSourceGroup = .subscription) { self.kind = kind }
    @State private var name = ""
    @State private var address = ""
    @State private var showsPicker = false
    @State private var preparingSelection = false
    @State private var importProgress = ""
    @State private var batchReport: LocalDocumentBatchReport?
    @State private var confirmsDeleteAll = false
    @State private var websiteShown = false
    @State private var reorderSession = LocalSettingsReorderSession()
    private var activeEntry: SubscriptionEntry? { store.managedSubscriptions(in: group).first(where: \.enabled) }
    var body: some View {
        WithPerceptionTracking {
            sourceForm
            .navigationTitle(group.title)
            .localDocumentImporter(isPresented: $showsPicker, kind: group == .python ? .pythonFiles : .subscriptionFile) { result in
                switch result {
                case .success(let selection):
                    importSelectedDocuments(selection)
                case .failure(let error):
                    store.importError = error.localizedDescription
                }
            } cancelled: {
                store.notice = "已取消文件选择"
            }
            .onAppear { store.importError = nil; store.notice = nil }
            .onDisappear { reorderSession.cancel() }
            .localGlassDialog(isPresented: $websiteShown, title: "接口配置", layout: .expanded) {
                WithPerceptionTracking {
                    ConfigCenterView {
                        guard let entry = activeEntry, let document = store.documents[entry.address],
                              let site = document.sites.first(where: { $0.raw["catPawOpen"] != nil }) else { return nil }
                        return await CatPawOpen.configCenter(site: site, origin: document.origin, jarURL: document.spiderURL)
                    }
                }
            }
        }
    }
    private var sourceForm: some View {
        SettingsPage(title: group.title) { accountSection; importSection; entriesSection }
    }
    @ViewBuilder private var accountSection: some View {
        if group == .subscription {
            WithPerceptionTracking {
                SettingsGroup(title: "账号与内容") {
                    LabeledContent("当前接口", value: activeEntry?.title ?? "未启用")
                    if let entry = activeEntry, let document = store.documents[entry.address],
                       document.sites.contains(where: { $0.raw["catPawOpen"] != nil }) {
                        Button("打开接口配置") { websiteShown = true }
                            .frame(minHeight: 44).accessibilityIdentifier("settings.subscription.website")
                    }
                }
            }
        }
    }
    private var importSection: some View {
        WithPerceptionTracking {
            SettingsGroup(title: "添加\(group.title)", footer: group == .python
                ? "本地可多选 Python 文件或 ZIP，选完后点“打开”；有依赖的脚本请一起压缩为 ZIP。逐个导入并显示结果，失败文件不影响其它文件。支持远程 Python、脚本 JSON 和 MD5 地址。文件导入后保存副本，修改后请重新导入。Python 可同时启用多个，观看记录归入当前订阅。"
                : "本地选择 JSON 或 ZIP 文件；多文件接口包请把 index.js、index.config.js 和对应 MD5 一起压缩为 ZIP。支持远程订阅和 MD5 地址。文件导入后保存副本，修改后请重新导入。同时只启用一个订阅，Python 来源可独立启用。") {
                TextField("名称（可选，留空自动生成）", text: $name)
                    .accessibilityLabel("来源名称")
                    .accessibilityIdentifier("sources.\(group.rawValue).name")
                    .disabled(store.importing || preparingSelection)
                HStack(spacing: 12) {
                    TextField(group == .python ? "Python / MD5 地址" : "订阅 / MD5 地址", text: $address)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .accessibilityLabel(group == .python ? "Python 地址" : "订阅地址")
                        .accessibilityIdentifier("sources.\(group.rawValue).address")
                        .disabled(store.importing || preparingSelection)
                        .onSubmit(importAddress)
                    Button(action: importAddress) {
                        Text("导入").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }
                        .buttonStyle(.borderless)
                        .disabled(store.importing || preparingSelection || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("sources.\(group.rawValue).import.address")
                    Button(action: presentFile) {
                        Text("本地文件").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("导入本地文件")
                    .disabled(store.importing || preparingSelection)
                    .accessibilityIdentifier("sources.\(group.rawValue).import.files")
                }
                if group == .subscription {
                    Toggle("自动更新", isOn: Binding(get: { store.subscriptionAutoUpdateEnabled }, set: { store.subscriptionAutoUpdateEnabled = $0 }))
                        .accessibilityIdentifier("sources.subscription.autoUpdate.enabled")
                    if store.subscriptionAutoUpdateEnabled {
                        ForEach(SubscriptionUpdateFrequency.allCases) { frequency in
                            Button {
                                store.subscriptionUpdateFrequency = frequency
                            } label: {
                                HStack {
                                    Text(frequency.title)
                                    Spacer()
                                    Image(systemName: store.subscriptionUpdateFrequency == frequency ? "checkmark.circle.fill" : "circle")
                                }
                                .frame(minHeight: 44).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(store.subscriptionUpdateFrequency == frequency ? [.isSelected] : [])
                            .accessibilityIdentifier("sources.subscription.autoUpdate.\(frequency.rawValue)")
                        }
                        Text("进入前台时按所选频率检查已启用订阅，仅在内容变化时更新；本地文件请重新导入。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if preparingSelection { ProgressView(importProgress.isEmpty ? "正在读取所选文件" : importProgress) }
                else if store.importing { ProgressView("正在导入或更新") }
                if let report = batchReport {
                    Text(report.summary).foregroundStyle(report.failureCount > 0 ? .red : .secondary)
                    Text(report.details).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("sources.\(group.rawValue).import.results")
                }
                if let message = store.importError { Text(message).foregroundStyle(.red) }
                if let message = store.notice { Text(message).foregroundStyle(.secondary) }
            }
        }
    }

    private func importAddress() {
        guard !store.importing, !preparingSelection,
              !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        batchReport = nil
        Task {
            await store.importSourceAddresses(address, group: group, name: name)
            if store.importError == nil { address = ""; name = "" }
        }
    }
    private var entriesSection: some View {
        WithPerceptionTracking {
                SettingsGroup(title: "已导入\(group == .python ? " Python" : group.title)",
                              headerActionTitle: group == .python && !store.managedSubscriptions(in: group).isEmpty ? "删除全部" : nil,
                              headerActionDisabled: store.importing || preparingSelection || store.restoringBackup,
                              headerActionIdentifier: "sources.python.deleteAll",
                              headerAction: { confirmsDeleteAll = true }) {
                    if store.managedSubscriptions(in: group).isEmpty {
                        Text("尚未添加\(group.title)").foregroundStyle(.secondary)
                    }
                    LocalSettingsReorderList(validIDs: store.managedSubscriptions(in: group).map(\.address),
                        enabled: group == .python && !preparingSelection && !store.importing && !store.restoringBackup,
                        session: $reorderSession, move: { source, target in
                            guard !preparingSelection else { return }
                            store.moveManagedSubscription(source, onto: target)
                        }) {
                        ForEach(store.managedSubscriptions(in: group)) { entry in
                            ManagedLocalSourceRow(entry: entry, group: group, reorderEnabled: !preparingSelection,
                                reorderSession: $reorderSession, remove: { store.removeSubscription(entry) })
                                .disabled(preparingSelection)
                                .localSettingsReorderRow(id: entry.address)
                        }
                    }
                }
                .confirmationDialog("删除全部 Python？", isPresented: $confirmsDeleteAll, titleVisibility: .visible) {
                    Button("删除全部", role: .destructive) {
                        store.removeSubscriptions(Set(store.managedSubscriptions(in: .python).map(\.address)))
                    }
                    Button("取消", role: .cancel) { }
                }
        }
    }

    private func presentFile() {
        batchReport = nil
        store.importError = nil; store.notice = "正在打开文件选择器…"
        showsPicker = true
    }

    private func importSelectedDocuments(_ selection: LocalDocumentSelection) {
        guard !store.importing, !preparingSelection else { selection.release(); return }
        Diagnostics.shared.record(.info, "imports", "source picker import ready kind=\(selection.kind.rawValue)")
        preparingSelection = true
        batchReport = nil
        let proposedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { preparingSelection = false; importProgress = "" }
            let report = await selection.importDocuments(progress: { index, total, filename in
                importProgress = "正在导入 \(index) / \(total)：\(filename)"
            }) { _, url in
                guard !store.importing else {
                    throw NSError(domain: "LocalSourceImport", code: 2, userInfo: [NSLocalizedDescriptionKey: "另一个来源正在导入或更新，请稍后重试此文件"])
                }
                let title = selection.urls.count > 1 && !proposedName.isEmpty
                    ? proposedName + " · " + url.deletingPathExtension().lastPathComponent : proposedName
                await store.importLocalSources([url], group: group, name: title, importingCopy: true)
                if let error = store.importError {
                    throw NSError(domain: "LocalSourceImport", code: 1, userInfo: [NSLocalizedDescriptionKey: error])
                }
                return store.notice ?? "已保存"
            }
            batchReport = report
            store.importError = nil; store.notice = nil
            if report.successCount > 0 { name = "" }
        }
    }

}

private struct ManagedLocalSourceRow: View {
    @Environment(Store.self) private var store
    let entry: SubscriptionEntry
    let group: LocalSourceGroup
    let reorderEnabled: Bool
    @Binding var reorderSession: LocalSettingsReorderSession
    let remove: () -> Void
    @State private var confirmsRemoval = false
    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(entry.title).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Toggle(entry.title, isOn: Binding(get: {
                        store.subscriptions.first { $0.address == entry.address }?.enabled ?? entry.enabled
                    }, set: { enabled in Task { await store.setSubscription(entry, enabled: enabled) } }))
                        .labelsHidden().fixedSize()
                        .accessibilityIdentifier("sources.entry.\(entry.id).enabled")
                    Button("删除", role: .destructive) { confirmsRemoval = true }
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel("删除 " + entry.title)
                        .accessibilityIdentifier("sources.entry.\(entry.id).delete")
                        .confirmationDialog("删除来源？", isPresented: $confirmsRemoval) {
                            Button("删除", role: .destructive, action: remove)
                            Button("取消", role: .cancel) { }
                        }
                    Button("更新") { Task { await store.refreshSource(entry) } }
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel("更新\(entry.title)")
                    if group == .python {
                        LocalSettingsReorderHandle(title: entry.title, id: entry.address,
                            enabled: reorderEnabled && !store.importing && !store.restoringBackup, session: $reorderSession)
                            .accessibilityAction(named: "上移") { store.moveManagedSubscription(entry, by: -1) }
                            .accessibilityAction(named: "下移") { store.moveManagedSubscription(entry, by: 1) }
                    }
                }
                .buttonStyle(.borderless)
                .disabled(store.importing || store.restoringBackup)
                if let failure = store.subscriptionErrors[entry.address] {
                    Text(failure).font(.footnote).foregroundStyle(.red)
                }
            }
            .padding(.vertical, 3)
        }
    }
}
