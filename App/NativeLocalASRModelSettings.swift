#if os(iOS)
import SwiftUI
import Perception
import TVCore

struct NativeLocalASRModelSettings: View {
    @Binding var locale: String
    @State private var models = NativeLocalASRModels.shared
    private var selected: LocalASRModel? { models.models.first { $0.id == LocalASRModel.modelID(for: locale) } }
    private var visibleModels: [LocalASRModel] {
        models.models.filter { $0.id == selected?.id || models.state($0).busy }
    }
    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 16) {
                LocalGlassChoicePicker(title: "音频语言", selection: $locale,
                    options: models.models.map { .init($0.id, "\($0.name) · \(bytes($0.bytes))") })
                Text("只需下载所选语言包。离线识别无需密钥，音频留在设备上。切换语言不会中断其他语言包的下载。")
                    .font(.system(size: 14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let error = models.catalogError { Text(error).font(.system(size: 14)).foregroundStyle(.red) }
                if selected == nil && models.catalogError == nil {
                    Text("请选择音频对应的语言。").font(.system(size: 14)).foregroundStyle(.secondary)
                }
                ForEach(visibleModels) { model in
                    modelRow(model)
                }
            }
        }
        .task {
            let normalized = LocalASRModel.modelID(for: locale)
            if models.models.contains(where: { $0.id == normalized }) { locale = normalized }
            await models.refresh()
        }
    }
    private func modelRow(_ model: LocalASRModel) -> some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        Text(model.name).font(.system(size: 19, weight: .semibold))
                        Spacer(minLength: 8)
                        Text("\(model.files.count) 个文件 · \(bytes(model.bytes))").font(.system(size: 14)).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.name).font(.system(size: 19, weight: .semibold))
                        Text("\(model.files.count) 个文件 · \(bytes(model.bytes))").font(.system(size: 14)).foregroundStyle(.secondary)
                    }
                }
                stateContent(model)
                if let notice = models.notices[model.id] {
                    Text(notice).font(.system(size: 14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .localGlassInputSurface(cornerRadius: 16)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings.ai.local-model.\(model.id)")
        }
    }
    @ViewBuilder private func stateContent(_ model: LocalASRModel) -> some View {
        switch models.state(model) {
        case .missing:
            Label("尚未下载", systemImage: "arrow.down.circle").font(.system(size: 17)).foregroundStyle(.secondary)
            Button("下载语音包") { models.download(model) }.settingsButton(prominent: true)
        case .checking:
            ProgressView("正在检查已下载文件…")
            cancel(model)
        case let .downloading(received, total):
            progress(title: "下载进度", received: received, total: total)
            Text(fileDescription(model, completed: received)).font(.system(size: 14)).foregroundStyle(.secondary)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let last = models.progressDates[model.id], context.date.timeIntervalSince(last) >= 10 {
                    Text("已 \(Int(context.date.timeIntervalSince(last))) 秒未收到新数据，正在等待网络；可取消后重试。")
                        .font(.system(size: 14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            cancel(model, title: "取消下载")
        case let .verifying(verified, total):
            progress(title: "文件校验", received: verified, total: total)
            Text("按实际读取的字节校验完整性，完成后再检查是否可用。")
                .font(.system(size: 14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            cancel(model)
        case .loading:
            ProgressView("文件完整，正在检查是否可用…")
            Text("首次加载可能需要一些时间，最多等待 60 秒。")
                .font(.system(size: 14)).foregroundStyle(.secondary)
            cancel(model)
        case .downloaded:
            Label("文件完整，尚未检查加载", systemImage: "checkmark.circle").font(.system(size: 17))
            Text("下载已完成。检查通过后可在播放器开启 AI 生成字幕。")
                .font(.system(size: 14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("检查是否可用") { models.verify(model) }.settingsButton(prominent: true)
            delete(model)
        case .ready:
            Label("可离线使用", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            Text("已完成下载、文件校验和本机加载检查。保存语言设置后，在播放器开启「AI 生成字幕」。")
                .font(.system(size: 14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("重新检查") { models.verify(model) }.settingsButton()
            delete(model)
        case .cancelling:
            ProgressView("正在取消并清理临时文件…")
        case .removing:
            ProgressView("正在释放并删除语音包…")
        case let .unavailable(message):
            Label("已下载，暂时无法加载", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            Text(message).font(.system(size: 14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("重新检查") { models.verify(model) }.settingsButton(prominent: true)
            delete(model)
        case let .failed(message):
            Text(message).font(.system(size: 14)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            Button("重试下载") { models.download(model) }.settingsButton(prominent: true)
            delete(model)
        }
    }
    private func progress(title: String, received: Int64, total: Int64) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 17, weight: .medium))
            if total > 0 {
                ProgressView(value: Double(min(max(0, received), total)), total: Double(total))
                Text("\(Int(Double(min(max(0, received), total)) / Double(total) * 100))% · \(bytes(received)) / \(bytes(total))")
                    .font(.system(size: 14)).monospacedDigit().foregroundStyle(.secondary)
            } else { ProgressView(); Text("正在等待文件大小…").font(.system(size: 14)).foregroundStyle(.secondary) }
        }
    }
    private func fileDescription(_ model: LocalASRModel, completed: Int64) -> String {
        var remaining = completed
        for (index, file) in model.files.enumerated() {
            if remaining < file.bytes { return "文件 \(index + 1)/\(model.files.count) · \(file.name)" }
            remaining -= file.bytes
        }
        return "全部文件已接收，正在准备校验。"
    }
    private func cancel(_ model: LocalASRModel, title: String = "取消") -> some View {
        Button(title) { models.cancel(model) }.settingsButton()
    }
    private func delete(_ model: LocalASRModel) -> some View {
        Button("删除语音包", role: .destructive) { models.remove(model) }.settingsButton()
    }
    private func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: max(0, count), countStyle: .file) }
}
#endif
