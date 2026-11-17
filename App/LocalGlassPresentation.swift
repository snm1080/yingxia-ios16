import SwiftUI
import Perception

#if os(iOS)
import UIKit

private struct LocalGlassDialogKey: EnvironmentKey { static let defaultValue = false }
private struct LocalGlassSharedBackdropKey: EnvironmentKey { static let defaultValue = false }
private struct LocalDialogContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

enum LocalDialogLayout: Equatable {
    case centered, upper, calendar, expanded, player

    func height(in viewport: CGSize, maximum: CGFloat?, content: CGFloat, header: CGFloat) -> CGFloat {
        let available = max(1, viewport.height - 24)
        let limit: CGFloat
        switch self {
        case .centered:
            limit = min(maximum ?? 580, available)
        case .upper:
            // Portrait dialogs occupy the upper half. A keyboard or landscape viewport
            // may leave less vertical space; keep that smaller area usable and scrollable.
            limit = min(maximum ?? 480, viewport.width > viewport.height ? available : viewport.height * 0.52)
        case .calendar: limit = min(maximum ?? 680, available)
        case .expanded: limit = min(maximum ?? 820, available)
        case .player: limit = min(maximum ?? 520, available)
        }
        let fitted = content > 0 && self != .expanded && self != .player ? content + header : limit
        return max(1, min(available, limit, fitted))
    }
}
extension EnvironmentValues {
    var localGlassSharedBackdrop: Bool {
        get { self[LocalGlassSharedBackdropKey.self] }
        set { self[LocalGlassSharedBackdropKey.self] = newValue }
    }
    var isLocalGlassDialog: Bool {
        get { self[LocalGlassDialogKey.self] }
        set { self[LocalGlassDialogKey.self] = newValue }
    }
}

/// A restrained raised surface, with the background still visible through the material.
private struct LocalGlassSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var opaque
    @Environment(\.localGlassSharedBackdrop) private var sharedBackdrop
    let radius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let dark = scheme == .dark
        content
            .background {
                Group {
                    if opaque {
                        shape.fill(Color(uiColor: .secondarySystemBackground))
                    } else if sharedBackdrop {
                        // Translucent tiles share the page's static canvas. They do
                        // not need a live blur of the retained tabs underneath it.
                        shape.fill(LinearGradient(colors: [
                            .white.opacity(dark ? 0.09 : 0.74),
                            .white.opacity(dark ? 0.035 : 0.34)
                        ], startPoint: .topLeading, endPoint: .bottomTrailing))
                    } else {
                        shape.fill(.ultraThinMaterial)
                            .overlay { shape.fill(Color.white.opacity(dark ? 0.025 : 0.22)) }
                    }
                }
                // Shadow only the plate. A shadow on content rasterizes all of a
                // settings group's labels/controls again while scrolling on iOS 16.
                .shadow(color: .black.opacity(dark ? 0.24 : 0.09), radius: sharedBackdrop ? 5 : 12, x: 3, y: 5)
                .shadow(color: .white.opacity(dark ? 0.025 : 0.30), radius: sharedBackdrop ? 2 : 4, x: -2, y: -2)
                .allowsHitTesting(false)
            }
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [
                    .white.opacity(dark ? 0.20 : 0.65),
                    .white.opacity(dark ? 0.025 : 0.10),
                    .black.opacity(dark ? 0.18 : 0.045)
                ], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.7)
                .allowsHitTesting(false)
            }
    }
}

private struct LocalGlassBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isLocalGlassDialog) private var dialog
    var body: some View {
        if !dialog {
            ZStack {
                Color(uiColor: .systemGroupedBackground)
                LinearGradient(colors: [Color.cyan.opacity(scheme == .dark ? 0.055 : 0.08),
                                        .clear, Color.indigo.opacity(scheme == .dark ? 0.07 : 0.055)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }.ignoresSafeArea()
        }
    }
}

private struct LocalGlassSettingsBackdrop: View {
    @Environment(\.isLocalGlassDialog) private var dialog
    var body: some View {
        if !dialog {
            LocalGlassBackdrop()
                .allowsHitTesting(false)
        }
    }
}

extension View {
    func localGlassSurface(cornerRadius: CGFloat = 22) -> some View {
        modifier(LocalGlassSurface(radius: cornerRadius))
    }

    func localGlassBackdrop() -> some View {
        background { LocalGlassBackdrop() }
    }

    /// A static canvas under translucent cards. Live material belongs to dialogs,
    /// where there is actually changing page content behind the glass.
    func localGlassSettingsCanvas() -> some View {
        background { LocalGlassSettingsBackdrop() }
        .environment(\.localGlassSharedBackdrop, true)
    }

    func localGlassInputSurface(cornerRadius: CGFloat = 12) -> some View {
        modifier(LocalGlassInputSurface(radius: cornerRadius))
    }

    /// Report the natural height of a scroll view's content, not its stretching viewport.
    /// Short descriptions and calendars then leave no empty tail below their last row.
    func localDialogContentHeight() -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(key: LocalDialogContentHeightKey.self, value: geometry.size.height)
            }
        }
    }

    func localPlayerGlassSurface(cornerRadius: CGFloat = 22) -> some View {
        modifier(LocalPlayerGlassSurface(radius: cornerRadius))
    }

    /// A separate modal controller preserves native dismissal and navigation on iOS 16.2.
    /// It uses a transparent presentation host so the card floats above the existing page.
    func localGlassDialog<Dialog: View>(isPresented: Binding<Bool>, title: String,
                                       maxWidth: CGFloat = 560, maxHeight: CGFloat? = nil,
                                       layout: LocalDialogLayout = .centered,
                                       onDismiss: (() -> Void)? = nil,
                                       @ViewBuilder content: @escaping () -> Dialog) -> some View {
        fullScreenCover(isPresented: isPresented, onDismiss: onDismiss) {
            LocalGlassDialog(title: title, maxWidth: maxWidth, maxHeight: maxHeight, layout: layout,
                             close: { isPresented.wrappedValue = false }, content: content)
        }
    }
}

private struct LocalGlassDialog<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    let maxWidth: CGFloat
    let maxHeight: CGFloat?
    let layout: LocalDialogLayout
    let close: () -> Void
    @State private var contentHeight: CGFloat = 0
    @State private var headerHeight: CGFloat = 52
    @ViewBuilder var content: () -> Content

    var body: some View {
        GeometryReader { viewport in
            WithPerceptionTracking {
                ZStack {
                    Color.black.opacity(layout == .player ? 0.12 : scheme == .dark ? 0.22 : 0.12)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture(perform: close)
                        .accessibilityHidden(true)
                    VStack(spacing: 0) {
                        if !title.isEmpty {
                            Text(title).font(.headline).lineLimit(2).multilineTextAlignment(.center)
                                .padding(.horizontal, 52).frame(maxWidth: .infinity, minHeight: 52)
                                .overlay(alignment: .trailing) {
                                    Button(action: close) {
                                        Image(systemName: "xmark").font(.system(size: 14, weight: .semibold))
                                            .frame(width: 44, height: 44).contentShape(Circle())
                                    }
                                    .buttonStyle(.plain).accessibilityLabel("关闭")
                                    .accessibilityIdentifier("local.dialog.close").padding(.trailing, 6)
                                }
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                                    guard height.isFinite, height > 0, abs(headerHeight - height) > 0.5 else { return }
                                    var transaction = Transaction(animation: nil); transaction.disablesAnimations = true
                                    withTransaction(transaction) { headerHeight = height }
                                }
                        }
                        content()
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                    .frame(width: max(1, min(maxWidth, viewport.size.width - 28)),
                           height: layout.height(in: viewport.size, maximum: maxHeight,
                                                 content: contentHeight, header: title.isEmpty ? 0 : headerHeight))
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .modifier(LocalDialogSurface(layout: layout))
                    .environment(\.isLocalGlassDialog, true)
                    .environment(\.localGlassSharedBackdrop, false)
                    .environment(\.usesLocalDock, false)
                    .environment(\.localDockInset, 0)
                    .environment(\.localDockTop, nil)
                    .environment(\.colorScheme, layout == .player ? .dark : scheme)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("local.dialog")
                    .accessibilityAddTraits(.isModal)
                    .onPreferenceChange(LocalDialogContentHeightKey.self) { height in
                        if height.isFinite, height >= 0, abs(contentHeight - height) > 0.5 {
                            var transaction = Transaction(animation: nil); transaction.disablesAnimations = true
                            withTransaction(transaction) { contentHeight = height }
                        }
                    }
                    .padding(.vertical, 12).padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: layout == .player ? .trailing : layout == .upper ? .top : .center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { LocalTransparentPresentation() }
            }
        }
        .appSheetBackground(.clear)
        .accessibilityAction(.escape, close)
    }
}

/// Inset glass fields keep the panel visible without the system's opaque black well.
private struct LocalGlassInputSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var opaque
    let radius: CGFloat
    func body(content: Content) -> some View {
        let dark = scheme == .dark
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .foregroundStyle(dark ? Color.white.opacity(0.96) : Color.primary)
            .background {
                shape.fill(opaque ? Color(uiColor: .tertiarySystemBackground) :
                            dark ? Color.white.opacity(0.09) : Color.white.opacity(0.46))
            }
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [
                    .black.opacity(dark ? 0.18 : 0.08), .white.opacity(dark ? 0.22 : 0.75)
                ], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8)
                .allowsHitTesting(false)
            }
    }
}

private struct LocalDialogSurface: ViewModifier {
    let layout: LocalDialogLayout
    @ViewBuilder func body(content: Content) -> some View {
        if layout == .player { content.localPlayerGlassSurface(cornerRadius: 24) }
        else if layout == .calendar { content.modifier(LocalCalendarGlassSurface()) }
        else { content.localGlassSurface(cornerRadius: 24) }
    }
}

/// A softly raised, translucent calendar plate. Its rim has an inset highlight;
/// only the plate is shadowed so poster and text scrolling stays independent.
private struct LocalCalendarGlassSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var opaque
    func body(content: Content) -> some View {
        let dark = scheme == .dark
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        content
            .background {
                Group {
                    if opaque { shape.fill(Color(uiColor: .secondarySystemGroupedBackground)) }
                    else {
                        shape.fill(.ultraThinMaterial)
                            .overlay {
                                shape.fill(LinearGradient(colors: [
                                    .white.opacity(dark ? 0.12 : 0.48),
                                    .cyan.opacity(dark ? 0.025 : 0.045),
                                    .white.opacity(dark ? 0.025 : 0.12)
                                ], startPoint: .topLeading, endPoint: .bottomTrailing))
                            }
                    }
                }
                .shadow(color: .black.opacity(dark ? 0.35 : 0.15), radius: 20, x: 8, y: 12)
                .shadow(color: .white.opacity(dark ? 0.05 : 0.42), radius: 9, x: -5, y: -5)
                .allowsHitTesting(false)
            }
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [
                    .white.opacity(dark ? 0.45 : 0.9), .white.opacity(0.07),
                    .black.opacity(dark ? 0.32 : 0.12)
                ], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .overlay {
                shape.inset(by: 2).stroke(LinearGradient(colors: [
                    .black.opacity(dark ? 0.14 : 0.045), .clear, .white.opacity(dark ? 0.13 : 0.5)
                ], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.6)
                    .allowsHitTesting(false)
            }
    }
}

/// The video remains visible through every player panel, with stable white text contrast.
private struct LocalPlayerGlassSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var opaque
    let radius: CGFloat
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                if opaque { shape.fill(Color(white: 0.09)) }
                else {
                    shape.fill(.ultraThinMaterial).opacity(0.72)
                        .overlay { shape.fill(Color.black.opacity(0.25)) }
                }
            }
            .overlay { shape.strokeBorder(.white.opacity(0.13), lineWidth: 0.6).allowsHitTesting(false) }
            .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
            .environment(\.colorScheme, .dark)
    }
}

/// iOS 16.2 has no presentationBackground. Clear only this modal's hosting ancestors;
/// never change the underlying window, page, or a system document picker.
private struct LocalTransparentPresentation: UIViewRepresentable {
    func makeUIView(context: Context) -> ClearView { ClearView() }
    func updateUIView(_ view: ClearView, context: Context) { view.clearPresentation() }
    final class ClearView: UIView {
        override func didMoveToWindow() { super.didMoveToWindow(); clearPresentation() }
        override func didMoveToSuperview() { super.didMoveToSuperview(); clearPresentation() }
        override func layoutSubviews() { super.layoutSubviews(); clearPresentation() }
        func clearPresentation() {
            // UIKit appearance properties are safe to set during this layout pass.
            // Deferring them until the next run-loop exposed an opaque first frame,
            // then queued the same writes again on every modal layout update.
            func clear(_ view: UIView) {
                if view.backgroundColor != .clear { view.backgroundColor = .clear }
                if view.isOpaque { view.isOpaque = false }
            }
            clear(self)
            guard window != nil else { return }
            var responder: UIResponder? = self
            while let next = responder, !(next is UIViewController) { responder = next.next }
            guard let controller = responder as? UIViewController else { return }
            clear(controller.view)
            var ancestor = superview
            while let view = ancestor, view !== controller.view {
                clear(view)
                ancestor = view.superview
            }
            if let container = controller.presentationController?.containerView, container.backgroundColor != .clear {
                container.backgroundColor = .clear
            }
        }
    }
}
#endif
