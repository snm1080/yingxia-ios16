#if os(iOS)
import SwiftUI
import TVCore

private struct LocalDockBounds: PreferenceKey {
    static let defaultValue: [Anchor<CGRect>] = []
    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) { value += nextValue() }
}

private struct LocalDockFrames: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}

private struct LocalDockTouchShape: Shape {
    let frames: [CGRect]
    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Individual buttons define their own visual shape. The shared overlay only
        // removes spacers and padding, so it must retain each marked control's full hit area.
        for frame in frames { path.addRect(frame) }
        return path
    }
}

private struct LocalDockTouchRegions: ViewModifier {
    @State private var frames: [CGRect] = []
    func body(content: Content) -> some View {
        content
            .backgroundPreferenceValue(LocalDockBounds.self) { anchors in
                GeometryReader { geometry in
                    Color.clear.preference(key: LocalDockFrames.self, value: anchors.map { geometry[$0] })
                        .allowsHitTesting(false)
                }
            }
            .onPreferenceChange(LocalDockFrames.self) { if frames != $0 { frames = $0 } }
            .contentShape(.interaction, LocalDockTouchShape(frames: frames))
    }
}

private struct LocalDockAccessory<Controls: View>: ViewModifier {
    @Environment(\.usesLocalDock) private var usesDock
    @Environment(\.localDockInset) private var inset
    @Environment(\.localDockTop) private var dockTop
    @ViewBuilder var controls: () -> Controls

    func body(content: Content) -> some View {
        content.overlay {
            GeometryReader { geometry in
                controls()
                    .localDockHitRegion()
                    .padding(.trailing, max(12, geometry.safeAreaInsets.trailing))
                    .padding(.bottom, LocalDockLayout.accessoryBottom(
                        containerBottom: geometry.frame(in: .global).maxY,
                        safeAreaBottom: geometry.safeAreaInsets.bottom,
                        dockTop: usesDock ? dockTop : nil, fallbackInset: usesDock ? inset : 0))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .localDockHitRegions()
            }
        }
    }
}

extension View {
    /// Fixed-layout docks use current frames directly, with no delayed preference
    /// publication or state animation between a visible control and its hit shape.
    func localDockHitRegions(frames: [CGRect]) -> some View {
        contentShape(.interaction, LocalDockTouchShape(frames: frames))
    }

    /// Mark only painted controls; inter-capsule spacers and outer shadows pass touches through.
    func localDockHitRegion() -> some View {
        anchorPreference(key: LocalDockBounds.self, value: .bounds) { [$0] }
    }
    func localDockHitRegions() -> some View { modifier(LocalDockTouchRegions()) }

    /// Match the dock's real position rather than adding a fixed inset in a
    /// potentially different safe-area coordinate system.
    func localDockAccessory<Controls: View>(@ViewBuilder controls: @escaping () -> Controls) -> some View {
        modifier(LocalDockAccessory(controls: controls))
    }
}
#endif
