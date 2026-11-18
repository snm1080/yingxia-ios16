#if os(iOS)
import SwiftUI
import Perception
import TVCore

/// One button of the local dock, in the settings page's terms. The dock itself
/// renders `AppSection` pages; this enum is the configurable identity of a button.
enum LocalDockButton: String, CaseIterable, Identifiable, Hashable {
    case home, favorites, history, music, settings, search, push
    var id: String { rawValue }
    static let defaultOrder: [LocalDockButton] = [.home, .favorites, .history, .music, .settings, .search, .push]
    /// Home and Settings can move but never hide: hiding Settings would lock the
    /// viewer out of the page that brings it back.
    var isLocked: Bool { self == .home || self == .settings }
    var title: String {
        switch self {
        case .home: "首页"
        case .favorites: "收藏"
        case .history: "历史"
        case .music: "音乐"
        case .settings: "设置"
        case .search: "搜索"
        case .push: "推送"
        }
    }
    var section: AppSection {
        switch self {
        case .home: .home
        case .favorites: .favorites
        case .history: .history
        case .music: .music
        case .settings: .settings
        case .search: .search
        case .push: .push
        }
    }
    /// The glyph the dock paints: filled variants for Home/Settings, as the dock
    /// has always drawn them; the rest are the sections' own symbols.
    var dockIcon: String {
        switch self {
        case .home: "house.fill"
        case .settings: "gearshape.fill"
        case .search: "magnifyingglass"
        case .push: "paperplane"
        default: section.icon
        }
    }
}

/// The viewer's dock arrangement: button order plus which buttons are hidden.
/// Stored as raw-value string arrays in UserDefaults; loading sanitizes, so a
/// button added by a later version joins at its default place and a stale or
/// duplicated entry never breaks the dock.
struct LocalDockConfiguration: Equatable {
    var order: [LocalDockButton] = LocalDockButton.defaultOrder
    var hidden: Set<LocalDockButton> = []
    static let orderKey = "local.dock.buttonOrder"
    static let hiddenKey = "local.dock.hiddenButtons"
    static let changed = Notification.Name("LocalDockConfiguration.changed")

    var visible: [LocalDockButton] { order.filter { !hidden.contains($0) } }

    static func load(defaults: UserDefaults = .standard) -> LocalDockConfiguration {
        var configuration = LocalDockConfiguration()
        if let raw = defaults.stringArray(forKey: orderKey) {
            var restored: [LocalDockButton] = []
            for value in raw {
                if let button = LocalDockButton(rawValue: value), !restored.contains(button) { restored.append(button) }
            }
            // A button the saved order predates takes its default place, after
            // whichever of its default predecessors is present.
            for button in LocalDockButton.defaultOrder where !restored.contains(button) {
                let predecessors = LocalDockButton.defaultOrder.prefix { $0 != button }.reversed()
                if let anchor = predecessors.first(where: { restored.contains($0) }),
                   let index = restored.firstIndex(of: anchor) {
                    restored.insert(button, at: index + 1)
                } else {
                    restored.append(button)
                }
            }
            if !restored.isEmpty { configuration.order = restored }
        }
        if let raw = defaults.stringArray(forKey: hiddenKey) {
            configuration.hidden = Set(raw.compactMap(LocalDockButton.init(rawValue:))).filter { !$0.isLocked }
        }
        return configuration
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set(order.map(\.rawValue), forKey: Self.orderKey)
        defaults.set(hidden.map(\.rawValue).sorted(), forKey: Self.hiddenKey)
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    static func reset(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: orderKey)
        defaults.removeObject(forKey: hiddenKey)
        NotificationCenter.default.post(name: changed, object: nil)
    }
}

/// Settings > Dock 按钮: drag to reorder, toggle to show or hide, restore defaults.
/// Applies live, like the WebHTV car rail editor Sam is used to.
struct LocalDockButtonsSettingsView: View {
    @State private var configuration = LocalDockConfiguration.load()
    var body: some View {
        WithPerceptionTracking {
            List {
                Section {
                    ForEach(configuration.order) { button in
                        WithPerceptionTracking {
                            HStack(spacing: 12) {
                                Image(systemName: button.dockIcon)
                                    .font(.system(size: 19, weight: .semibold))
                                    .frame(width: 30)
                                Text(button.title).font(.body.weight(.medium)).lineLimit(1)
                                Spacer(minLength: 8)
                                if button.isLocked {
                                    Text("常驻").font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Toggle("显示", isOn: visibility(of: button))
                                        .labelsHidden()
                                        .accessibilityLabel(button.title + "显示")
                                }
                            }
                            .padding(.vertical, 3)
                        }
                    }
                    .onMove(perform: move)
                } footer: {
                    Text("长按拖动排序。首页与设置不可隐藏；隐藏的按钮不占位，Dock 会按剩下的按钮自动变短。")
                        .textCase(nil)
                }
                Section {
                    Button("恢复默认") {
                        LocalDockConfiguration.reset()
                        withAnimation(.appSmooth) { configuration = LocalDockConfiguration() }
                    }
                    .disabled(configuration == LocalDockConfiguration())
                }
            }
            .environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden)
            .background { WithPerceptionTracking { Backdrop() } }
            .navigationTitle("Dock 按钮")
            .navigationBarTitleDisplayMode(.inline)
            .onReceive(NotificationCenter.default.publisher(for: LocalDockConfiguration.changed)) { _ in
                let loaded = LocalDockConfiguration.load()
                if loaded != configuration { configuration = loaded }
            }
        }
    }

    private func visibility(of button: LocalDockButton) -> Binding<Bool> {
        Binding(get: { !configuration.hidden.contains(button) },
                set: { visible in
                    if visible { configuration.hidden.remove(button) } else { configuration.hidden.insert(button) }
                    configuration.save()
                })
    }

    private func move(from source: IndexSet, to destination: Int) {
        configuration.order.move(fromOffsets: source, toOffset: destination)
        configuration.save()
    }
}
#endif
