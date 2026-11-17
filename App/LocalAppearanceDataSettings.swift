#if os(iOS)
import SwiftUI
import TVCore
import Perception
import UniformTypeIdentifiers

extension LocalAppearance {
    var colorScheme: ColorScheme? { switch self { case .system: nil; case .light: .light; case .dark: .dark } }
}

struct LocalAppearanceSettingsView: View {
    var body: some View {
        SettingsPage(title: "主题", symbol: "circle.lefthalf.filled") {
            LocalAppearanceSettingsSection()
        }
    }
}

struct LocalAppearanceSettingsSection: View {
    @AppStorage(LocalAppearance.key) private var appearance = LocalAppearance.system
    var body: some View {
        SettingsGroup(title: "主题", footer: "立即应用并自动保存；跟随系统会使用设备当前的亮暗外观。") {
            Picker("主题", selection: $appearance) { ForEach(LocalAppearance.allCases) { Text($0.title).tag($0) } }
                .pickerStyle(.segmented).accessibilityIdentifier("settings.appearance")
        }
    }
}

private struct LocalBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct LocalBackupSettingsView: View {
    @Environment(Store.self) private var store
    @State private var importing = false
    @State private var exporting = false
    @State private var document: LocalBackupDocument?
    @State private var preview: LocalBackupPayload?
    @State private var createdAt: Date?
    @State private var selected = Set(LocalBackupCategory.allCases)
    @State private var replacing = false
    @State private var busy = false
    @State private var undo = LocalBackupCoordinator.undoAvailable
    @State private var status = ""
    var body: some View {
        SettingsPage(title: "备份迁移", symbol: "archivebox") {
            SettingsGroup(title: "备份与迁移", footer: "导出映匣 iOS JSON 备份，不包含账号密码、Cookie、API 密钥、视频缓存和语音模型。来源代码可能带有作者写入的配置；请妥善保管。MacCat 桌面备份格式暂不支持。") {
                Button("导出备份") {
                    run {
                        document = LocalBackupDocument(data: try await LocalBackupCoordinator.export(store))
                        exporting = true
                    }
                }.disabled(busy).accessibilityIdentifier("settings.backup.export")
                Button("选择备份文件") { importing = true }.disabled(busy).accessibilityIdentifier("settings.backup.import")
                Button("撤回上次恢复") { run { try await LocalBackupCoordinator.undo(store); status = "已撤回上次恢复"; undo = LocalBackupCoordinator.undoAvailable } }
                    .disabled(busy || !undo)
                if store.restoringBackup {
                    Button("重试上次未完成的恢复") {
                        run {
                            if await LocalBackupCoordinator.recover(store) {
                                status = "已恢复上次操作前的数据"; await store.restoreSubscription(); store.cloudSync?.start()
                            } else { status = store.error ?? "恢复未完成，日志已保留" }
                        }
                    }.disabled(busy)
                }
                if busy { ProgressView("正在处理备份…") }
                if !status.isEmpty { Text(status).font(.footnote).foregroundStyle(.secondary) }
            }
            if let value = preview {
                SettingsGroup(title: "恢复预览", footer: "恢复会停止播放，并保存恢复前的数据以供撤回。未选择的分类保持现状；恢复的来源保持关闭，需手动启用。") {
                    if let createdAt { Text(createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption) }
                    ForEach(LocalBackupCategory.allCases) { category in
                        Toggle(category.title + "（\(count(category, in: value)) 项）", isOn: Binding(get: { selected.contains(category) }, set: {
                            if $0 { selected.insert(category) } else { selected.remove(category) }
                        })).settingsSwitch()
                    }
                    Picker("恢复模式", selection: $replacing) {
                        Text("合并，保留较新记录").tag(false)
                        Text("替换所选分类").tag(true)
                    }
                    Button("确认恢复") {
                        run {
                            try await LocalBackupCoordinator.restore(value, categories: selected, replacing: replacing, store: store)
                            preview = nil; undo = true; status = "恢复完成，可撤回到恢复前的数据。"
                        }
                    }.settingsButton(prominent: true).disabled(busy || selected.isEmpty)
                    Button("取消") { preview = nil }.disabled(busy)
                }
            }
        }
        .localDocumentImporter(isPresented: $importing, kind: .backupFile) { result in
            switch result {
            case .failure(let error): status = error.localizedDescription
            case .success(let selection):
                run {
                    defer { selection.release() }
                    let data = try await selection.readData(maxBytes: LocalBackupArchive.maximumBytes)
                    let (archive, payload) = try LocalBackupCoordinator.inspect(data)
                    preview = payload; createdAt = archive.createdAt; selected = Set(LocalBackupCategory.allCases); status = ""
                }
            }
        } cancelled: { status = "已取消文件选择" }
        .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "Yingxia-iOS-backup-" + Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))) { result in
            switch result { case .success: status = "备份已导出"; case .failure(let error): status = error.localizedDescription }
            document = nil
        }
    }
    private func run(_ operation: @escaping () async throws -> Void) {
        busy = true; status = ""
        Task { defer { busy = false }; do { try await operation() } catch { status = error.localizedDescription } }
    }
    private func count(_ category: LocalBackupCategory, in value: LocalBackupPayload) -> Int {
        switch category {
        case .history: value.history.count
        case .favorites: value.favorites.count
        case .settings: value.settings.count
        case .sources: (try? JSONDecoder().decode([SubscriptionEntry].self, from: value.subscriptions).count) ?? 0
        }
    }
}
#endif
