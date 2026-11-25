#if os(iOS)
import SwiftUI
import UIKit
import TVCore

/// A native responder owns the complete painted strip, including transparent
/// spaces between labels. Sibling song-list buttons cannot receive its touches.
struct MusicMiniPlayerTouchSurface: UIViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.layoutDirection) private var layoutDirection
    let inline: Bool
    let title: String
    let transportLabel: String
    let canAdvance: Bool
    let open: () -> Void
    let transport: () -> Void
    let next: () -> Void
    let stop: () -> Void

    func makeUIView(context: Context) -> MusicMiniPlayerTouchView { MusicMiniPlayerTouchView() }

    func updateUIView(_ view: MusicMiniPlayerTouchView, context: Context) {
        view.configure(inline: inline, rightToLeft: layoutDirection == .rightToLeft, enabled: isEnabled,
                       title: title, transportLabel: transportLabel, canAdvance: canAdvance,
                       open: open, transport: transport, next: next, stop: stop)
    }
}

final class MusicMiniPlayerTouchView: UIView, UIContextMenuInteractionDelegate {
    private typealias Action = MusicMiniPlayerLayout.Action
    private var buttons: [Action: UIButton] = [:]
    private var inline = false
    private var rightToLeft = false
    private var enabled = true
    private var onOpen: (() -> Void)?
    private var onTransport: (() -> Void)?
    private var onNext: (() -> Void)?
    private var onStop: (() -> Void)?

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        isAccessibilityElement = false
        for action in Action.allCases {
            let button = UIButton(type: .custom)
            button.backgroundColor = .clear
            button.isExclusiveTouch = true
            button.isAccessibilityElement = true
            button.addAction(UIAction { [weak self] _ in self?.perform(action) }, for: .touchUpInside)
            addSubview(button)
            buttons[action] = button
        }
        buttons[.open]?.accessibilityIdentifier = "music.miniPlayer.open"
        buttons[.transport]?.accessibilityIdentifier = "music.miniPlayer.transport"
        buttons[.next]?.accessibilityIdentifier = "music.miniPlayer.next"
        buttons[.stop]?.accessibilityIdentifier = "music.miniPlayer.stop"
        buttons[.open]?.accessibilityHint = L10n.text("Now Playing")
        buttons[.open]?.accessibilityCustomActions = [UIAccessibilityCustomAction(name: L10n.text("Stop"),
            target: self, selector: #selector(accessibilityStop))]
        addInteraction(UIContextMenuInteraction(delegate: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(inline: Bool, rightToLeft: Bool, enabled: Bool, title: String,
                   transportLabel: String, canAdvance: Bool, open: @escaping () -> Void,
                   transport: @escaping () -> Void, next: @escaping () -> Void, stop: @escaping () -> Void) {
        self.inline = inline
        self.rightToLeft = rightToLeft
        self.enabled = enabled
        onOpen = open; onTransport = transport; onNext = next; onStop = stop
        buttons[.open]?.accessibilityLabel = title
        buttons[.transport]?.accessibilityLabel = transportLabel
        buttons[.next]?.accessibilityLabel = L10n.text("Next")
        buttons[.stop]?.accessibilityLabel = L10n.text("Stop")
        for (action, button) in buttons {
            button.isHidden = inline && (action == .next || action == .stop)
            button.isEnabled = enabled && (action != .next || canAdvance)
        }
        accessibilityElements = Action.allCases.compactMap { action in
            guard let button = buttons[action], !button.isHidden else { return nil }
            return button
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        for region in MusicMiniPlayerLayout.regions(size: bounds.size, inline: inline, rightToLeft: rightToLeft) {
            buttons[region.action]?.frame = region.frame
        }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        MusicMiniPlayerLayout.contains(point, size: bounds.size)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, alpha > 0.01, isUserInteractionEnabled,
              let action = MusicMiniPlayerLayout.action(at: point, size: bounds.size, inline: inline, rightToLeft: rightToLeft)
        else { return nil }
        layoutIfNeeded()
        // Disabled Next still consumes its covered area, without opening the
        // player or selecting the song below it.
        return buttons[action] ?? self
    }

    private func perform(_ action: Action) {
        guard enabled, buttons[action]?.isEnabled == true else { return }
        switch action {
        case .open: onOpen?()
        case .transport: onTransport?()
        case .next: onNext?()
        case .stop: onStop?()
        }
    }

    @objc private func accessibilityStop() -> Bool {
        guard enabled else { return false }
        onStop?()
        return true
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard enabled, MusicMiniPlayerLayout.contains(location, size: bounds.size) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [UIAction(title: L10n.text("Stop"), image: UIImage(systemName: "xmark"), attributes: .destructive) { [weak self] _ in
                self?.onStop?()
            }])
        }
    }
}
#endif
