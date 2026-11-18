import SwiftUI
import TVCore
import UniformTypeIdentifiers
import UIKit

enum LocalSettingsReorderProvider {
    static func make(_ data: Data) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.data.identifier, visibility: .ownProcess) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }
}

private struct LocalSettingsRowFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// One continuous drop surface includes row gaps and room after the final row.
/// Hover is presentation only; persistence is owned by a validated performDrop.
struct LocalSettingsReorderList<Content: View>: View {
    let validIDs: [String]
    let enabled: Bool
    @Binding var session: LocalSettingsReorderSession
    let move: (String, String) -> Void
    @ViewBuilder var content: Content
    @State private var frames: [String: CGRect] = [:]
    @State private var target: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .coordinateSpace(name: "local-settings-reorder-list")
            .onPreferenceChange(LocalSettingsRowFrames.self) { MainActor.assumeIsolated { frames = $0 } }
            .onDrop(of: [UTType.data.identifier], delegate: LocalSettingsListDrop(
                validIDs: validIDs, enabled: enabled, frames: frames,
                session: $session, target: $target, move: move))
            .overlay {
                if let target, target != session.sourceID, let frame = frames[target] {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.accentColor, lineWidth: 2)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                        .allowsHitTesting(false)
                }
            }
            .onChange(of: enabled) { if !$0 { session.cancel(); target = nil } }
            .onChange(of: session.sourceID) { if $0 == nil { target = nil } }
    }
}

private struct LocalSettingsListDrop: DropDelegate {
    let validIDs: [String]
    let enabled: Bool
    let frames: [String: CGRect]
    @Binding var session: LocalSettingsReorderSession
    @Binding var target: String?
    let move: (String, String) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        enabled && session.sourceID.map(validIDs.contains) == true
            && info.hasItemsConforming(to: [UTType.data.identifier])
    }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { target = nil; return DropProposal(operation: .cancel) }
        target = destination(info)
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) { target = nil }
    func performDrop(info: DropInfo) -> Bool {
        target = nil
        guard validateDrop(info: info), let destination = destination(info),
              let provider = info.itemProviders(for: [UTType.data.identifier]).first else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.data.identifier) { data, _ in
            guard let data else { return }
            Task { @MainActor in
                guard let source = session.accept(data, onto: destination, validIDs: validIDs) else { return }
                withAnimation(.easeInOut(duration: 0.18)) { move(source, destination) }
            }
        }
        return true
    }
    private func destination(_ info: DropInfo) -> String? {
        LocalSettingsReorderFrame.target(at: info.location.y,
            frames: frames.map { LocalSettingsReorderFrame(id: $0.key, minY: $0.value.minY, maxY: $0.value.maxY) },
            validIDs: validIDs)
    }
}

extension View {
    func localSettingsReorderRow(id: String) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(key: LocalSettingsRowFrames.self,
                    value: [id: proxy.frame(in: .named("local-settings-reorder-list"))])
            }
        }
    }
}

struct LocalSettingsReorderHandle: View {
    let title: String
    let id: String
    let enabled: Bool
    @Binding var session: LocalSettingsReorderSession
    var body: some View {
        LocalSettingsNativeDragHandle(id: id, enabled: enabled, session: $session)
            .frame(width: 44, height: 44)
            .accessibilityElement()
            .accessibilityLabel("排序 " + title)
            .accessibilityHint("长按并拖动此行调整顺序")
    }
}

/// The native interaction belongs only to the handle, leaving all row controls
/// untouched. The end callback explicitly invalidates cancelled/outside drops.
private struct LocalSettingsNativeDragHandle: UIViewRepresentable {
    let id: String
    let enabled: Bool
    @Binding var session: LocalSettingsReorderSession
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView(image: UIImage(systemName: "line.3.horizontal"))
        view.contentMode = .center
        view.tintColor = .secondaryLabel
        view.isUserInteractionEnabled = true
        let interaction = UIDragInteraction(delegate: context.coordinator)
        interaction.isEnabled = enabled
        view.addInteraction(interaction)
        return view
    }
    func updateUIView(_ view: UIImageView, context: Context) {
        context.coordinator.parent = self
        view.interactions.compactMap { $0 as? UIDragInteraction }.forEach { $0.isEnabled = enabled }
    }
    final class Coordinator: NSObject, UIDragInteractionDelegate {
        var parent: LocalSettingsNativeDragHandle
        init(_ parent: LocalSettingsNativeDragHandle) { self.parent = parent }
        func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: any UIDragSession) -> [UIDragItem] {
            guard parent.enabled else { return [] }
            let data = parent.session.begin(parent.id)
            let item = UIDragItem(itemProvider: LocalSettingsReorderProvider.make(data))
            item.localObject = data
            return [item]
        }
        func dragInteraction(_ interaction: UIDragInteraction, sessionAllowsMoveOperation session: any UIDragSession) -> Bool { true }
        func dragInteraction(_ interaction: UIDragInteraction, sessionIsRestrictedToDraggingApplication session: any UIDragSession) -> Bool { true }
        func dragInteraction(_ interaction: UIDragInteraction, session: any UIDragSession, didEndWith operation: UIDropOperation) {
            // Data loading may complete after a successful move ends. Keep its
            // token until accept(), but invalidate every unsuccessful native drag.
            guard operation != .move, let data = session.items.first?.localObject as? Data else { return }
            parent.session.cancel(data)
        }
    }
}
