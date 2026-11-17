import SwiftUI
import Perception
import TVCore

// Explicit names keep these adapters distinct from native overloads. Runtime checks
// preserve newer rendering while every fallback is available on the iOS 16.2 target.
extension View {
    @ViewBuilder func appOnChange<Value: Equatable>(of value: Value, initial: Bool = false,
                                                   _ action: @escaping (Value, Value) -> Void) -> some View {
        if #available(iOS 17, macOS 14, tvOS 17, *) {
            onChange(of: value, initial: initial, action)
        } else {
            // Capturing this render's value supplies the previous value when SwiftUI
            // invokes its original one-argument onChange callback.
            onChange(of: value) { [value] next in action(value, next) }
                .onAppear { if initial { action(value, value) } }
        }
    }

    func appOnChange<Value: Equatable>(of value: Value, initial: Bool = false,
                                       _ action: @escaping (Value) -> Void) -> some View {
        appOnChange(of: value, initial: initial) { _, next in action(next) }
    }

    func appOnChange<Value: Equatable>(of value: Value, initial: Bool = false,
                                       _ action: @escaping () -> Void) -> some View {
        appOnChange(of: value, initial: initial) { _, _ in action() }
    }

    /// The optional route remains the source of truth. Back navigation clears it
    /// just as the item-based API does, so a later selection can push again.
    @ViewBuilder func appNavigationDestination<Item: Hashable, Destination: View>(
        item: Binding<Item?>, @ViewBuilder destination: @escaping (Item) -> Destination
    ) -> some View {
        if #available(iOS 17, macOS 14, tvOS 17, *) {
            navigationDestination(item: item) { value in
                WithPerceptionTracking { destination(value) }
            }
        } else {
            navigationDestination(isPresented: Binding(
                get: { item.wrappedValue != nil },
                set: { if !$0 { item.wrappedValue = nil } }
            )) {
                WithPerceptionTracking {
                    if let value = item.wrappedValue { destination(value) }
                }
            }
        }
    }

    @ViewBuilder func appSheetBackground<Style: ShapeStyle>(_ style: Style) -> some View {
        if #available(iOS 16.4, macOS 13.3, tvOS 16.4, *) { presentationBackground(style) }
        else { background(style) }
    }

    @ViewBuilder func appSheetBackground<Background: View>(alignment: Alignment = .center,
                                                         @ViewBuilder content: @escaping () -> Background) -> some View {
        if #available(iOS 16.4, macOS 13.3, tvOS 16.4, *) {
            presentationBackground(alignment: alignment) { WithPerceptionTracking { content() } }
        } else {
            background(alignment: alignment) { WithPerceptionTracking { content() } }
        }
    }

    @ViewBuilder func appPresentationCornerRadius(_ radius: CGFloat?) -> some View {
        if #available(iOS 16.4, macOS 13.3, tvOS 16.4, *) { presentationCornerRadius(radius) }
        else { self }
    }

    /// Target registration is used by iOS 17 snapping. iOS 16 callers retain
    /// explicit ScrollViewReader positioning and their drag handlers.
    @ViewBuilder func appScrollTargetLayout(isEnabled: Bool = true) -> some View {
        if #available(iOS 17, macOS 14, tvOS 17, *) { scrollTargetLayout(isEnabled: isEnabled) }
        else { self }
    }

    /// Older scroll views keep the system clip. Their content includes explicit
    /// shadow/hover padding; scrolling, positioning and interaction are unchanged.
    @ViewBuilder func appScrollClipDisabled(_ disabled: Bool = true) -> some View {
        if #available(iOS 17, macOS 14, tvOS 17, *) { scrollClipDisabled(disabled) } else { self }
    }

    @ViewBuilder func appSymbolReplaceTransition() -> some View {
        if #available(iOS 17, macOS 14, tvOS 17, *) { contentTransition(.symbolEffect(.replace)) }
        else { contentTransition(.opacity) }
    }

    @ViewBuilder func appVariableColor(isActive: Bool = true) -> some View {
        if #available(iOS 17, macOS 14, tvOS 17, *) { symbolEffect(.variableColor, isActive: isActive) }
        else { opacity(isActive ? 1 : 0.65).animation(.easeInOut(duration: 0.2), value: isActive) }
    }

    @ViewBuilder func appBounce<Value: Equatable>(value: Value) -> some View {
        if #available(iOS 17, macOS 14, tvOS 17, *) { symbolEffect(.bounce, value: value) }
        else { modifier(LegacySymbolBounce(value: value)) }
    }
}

private struct LegacySymbolBounce<Value: Equatable>: ViewModifier {
    let value: Value
    @State private var raised = false
    func body(content: Content) -> some View {
        content.offset(y: raised ? -3 : 0)
            .animation(.easeInOut(duration: 0.16), value: raised)
            .appOnChange(of: value) {
                raised = true
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(160))
                    raised = false
                }
            }
    }
}

extension Animation {
    static var appSmooth: Animation { appSmooth() }
    static func appSmooth(duration: TimeInterval = 0.5, extraBounce: Double = 0) -> Animation {
        if #available(iOS 17, macOS 14, tvOS 17, *) { return .smooth(duration: duration, extraBounce: extraBounce) }
        return .spring(response: duration, dampingFraction: max(0.1, 1 - extraBounce))
    }
    static var appSnappy: Animation { appSnappy() }
    static func appSnappy(duration: TimeInterval = 0.5, extraBounce: Double = 0) -> Animation {
        if #available(iOS 17, macOS 14, tvOS 17, *) { return .snappy(duration: duration, extraBounce: extraBounce) }
        return .spring(response: duration, dampingFraction: max(0.1, 0.85 - extraBounce))
    }
    static var appBouncy: Animation { appBouncy() }
    static func appBouncy(duration: TimeInterval = 0.5, extraBounce: Double = 0) -> Animation {
        if #available(iOS 17, macOS 14, tvOS 17, *) { return .bouncy(duration: duration, extraBounce: extraBounce) }
        return .spring(response: duration, dampingFraction: max(0.1, 0.65 - extraBounce))
    }
    static func appSpring(duration: TimeInterval = 0.5, bounce: Double = 0, blendDuration: TimeInterval = 0) -> Animation {
        if #available(iOS 17, macOS 14, tvOS 17, *) { return .spring(duration: duration, bounce: bounce, blendDuration: blendDuration) }
        return .spring(response: duration, dampingFraction: max(0.1, 1 - bounce), blendDuration: blendDuration)
    }
}

/// The same empty/error content and actions on iOS 16, before the system introduced
/// ContentUnavailableView. Callers keep their labels, explanations and retry controls.
struct AppContentUnavailableView<Label: View, Description: View, Actions: View>: View {
    private let label: Label
    private let description: Description
    private let actions: Actions

    init(@ViewBuilder label: () -> Label, @ViewBuilder description: () -> Description,
         @ViewBuilder actions: () -> Actions) {
        self.label = label(); self.description = description(); self.actions = actions()
    }

    @ViewBuilder var body: some View {
        if #available(iOS 17, macOS 14, tvOS 17, *) {
            ContentUnavailableView { WithPerceptionTracking { label } }
                description: { WithPerceptionTracking { description } }
                actions: { WithPerceptionTracking { actions } }
        } else {
            VStack(spacing: 12) {
                label.labelStyle(LegacyUnavailableLabelStyle()).font(.title2.weight(.semibold))
                description.font(.body).foregroundStyle(.secondary)
                actions.padding(.top, 4)
            }
            .multilineTextAlignment(.center).padding(24)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
        }
    }
}

extension AppContentUnavailableView where Actions == EmptyView {
    init(@ViewBuilder label: () -> Label, @ViewBuilder description: () -> Description) {
        self.init(label: label, description: description, actions: { EmptyView() })
    }
}

extension AppContentUnavailableView where Label == SwiftUI.Label<Text, Image>, Description == Text, Actions == EmptyView {
    init(_ title: String, systemImage: String, description: Text? = nil) {
        self.init(label: { SwiftUI.Label { Text(title) } icon: { Image(systemName: systemImage) } },
                  description: { description ?? Text("") }, actions: { EmptyView() })
    }

    static func search(text: String = "") -> Self {
        let suggestion = L10n.text("Try another keyword.")
        return Self(L10n.text("No Results"), systemImage: "magnifyingglass",
                    description: Text(text.isEmpty ? suggestion : "“\(text)”\n\(suggestion)"))
    }
}

private struct LegacyUnavailableLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 12) {
            configuration.icon.font(.system(size: 44)).foregroundStyle(.secondary)
            configuration.title
        }
    }
}

#if os(iOS)
/// Observes the real scroll viewport on iOS 16/17. A plain onAppear callback
/// cannot replace visibility: lazy cells may remain alive while far offscreen.
struct LegacyScrollVisibility: UIViewRepresentable {
    let threshold: Double
    let action: (Bool) -> Void

    func makeUIView(context: Context) -> ObserverView { ObserverView() }
    func updateUIView(_ view: ObserverView, context: Context) {
        view.threshold = threshold
        view.action = action
        view.observeScrollView()
    }

    final class ObserverView: UIView {
        var threshold = 0.5
        var action: ((Bool) -> Void)?
        private var observations: [NSKeyValueObservation] = []
        private weak var scrollView: UIScrollView?
        private var last: Bool?
        private var reportScheduled = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            observeScrollView()
        }
        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            observeScrollView()
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            observeScrollView()
        }

        func observeScrollView() {
            var ancestor = superview
            while let view = ancestor, !(view is UIScrollView) { ancestor = view.superview }
            let enclosing = ancestor as? UIScrollView
            if enclosing !== scrollView {
                observations.removeAll()
                scrollView = enclosing
                if let enclosing {
                    observations = [
                        enclosing.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                            MainActor.assumeIsolated { self?.scheduleReport() }
                        },
                        enclosing.observe(\.bounds, options: [.new]) { [weak self] _, _ in
                            MainActor.assumeIsolated { self?.scheduleReport() }
                        }
                    ]
                }
            }
            scheduleReport()
        }

        private func scheduleReport() {
            // KVO also fires during UIKit layout. Deliver one final measurement
            // after that update, so pagination cannot mutate SwiftUI mid-render.
            guard !reportScheduled else { return }
            reportScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reportScheduled = false
                self.report()
            }
        }

        private func report() {
            let visible: Bool
            if let window, bounds.width > 0, bounds.height > 0 {
                let own = convert(bounds, to: window)
                let viewport = scrollView.map { $0.convert($0.bounds, to: window).intersection(window.bounds) } ?? window.bounds
                let shown = own.intersection(viewport)
                let area = shown.isNull ? 0 : shown.width * shown.height
                visible = !isHidden && area > 0 && area >= own.width * own.height * max(0, min(1, threshold))
            } else {
                visible = false
            }
            guard visible != last else { return }
            last = visible
            action?(visible)
        }
    }
}
#endif
