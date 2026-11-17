import SwiftUI
import Perception
import TVCore

/// Continue Watching keeps native tap/long-press arbitration and presents its
/// actions on the same glass surface as the other homepage panels.
struct HistoryCard: View {
    @Environment(Store.self) private var store
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.stripDrag) private var drag
    @Environment(\.openHistoryDetails) private var openDetails
    @Environment(\.openRoute) private var openRoute
    #if os(iOS)
    @Environment(\.isLocalPageActive) private var isPageActive
    @State private var actionsShown = false
    @State private var pendingAction: HistoryAction?
    #endif
    let entry: PlaybackHistoryEntry

    private var canInteract: Bool {
        #if os(iOS)
        isEnabled && isPageActive && store.section == .home && drag?.active != true
        #else
        isEnabled && store.section == .home && drag?.active != true
        #endif
    }

    var body: some View {
        WithPerceptionTracking {
            Button { resume() } label: { HistoryCardLabel(entry: entry) }
                .cardButton()
                #if os(iOS)
                .highPriorityGesture(LongPressGesture(minimumDuration: 0.5, maximumDistance: 10).onEnded { _ in
                    showActions()
                })
                .accessibilityAction(named: Text("更多操作"), showActions)
                .localGlassDialog(isPresented: $actionsShown, title: entry.context.displayTitle,
                                  maxWidth: 420, layout: .centered, onDismiss: performPendingAction) {
                    WithPerceptionTracking {
                        ScrollView {
                            VStack(spacing: 10) {
                                if let route = detailsRoute {
                                    glassAction(L10n.text("Show Details"), symbol: "info.circle", action: .details(route))
                                }
                                glassAction(entry.completed ? "重新观看" : "继续观看", symbol: "play.fill", action: .resume(.resume))
                                glassAction("从头播放", symbol: "arrow.counterclockwise", action: .resume(.beginning))
                                glassAction(L10n.text("Remove from history"), symbol: "trash", action: .remove, destructive: true)
                            }
                            .padding(16)
                            .localDialogContentHeight()
                        }
                    }
                }
                .appOnChange(of: canInteract) { _, active in
                    if !active { pendingAction = nil; actionsShown = false }
                }
                #else
                .contextMenu { WithPerceptionTracking { menu } }
                #endif
                .disabled(!canInteract)
                .accessibilityIdentifier("history.resume." + entry.context.videoID)
        }
    }

    private func resume(mode: PlaybackResumeMode = .resume) {
        guard canInteract else { return }
        #if os(iOS)
        // Releasing a successful long press cannot also trigger the card's tap action.
        guard !actionsShown else { return }
        #endif
        store.resume(entry, mode: mode)
    }

    #if os(iOS)
    private enum HistoryAction {
        case details(Route), resume(PlaybackResumeMode), remove
    }

    private func showActions() {
        guard canInteract, !actionsShown else { return }
        pendingAction = nil
        actionsShown = true
    }

    private func glassAction(_ title: String, symbol: String, action: HistoryAction, destructive: Bool = false) -> some View {
        Button(role: destructive ? .destructive : nil) {
            guard canInteract else { return }
            pendingAction = action
            actionsShown = false
        } label: {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 4)
                .localGlassInputSurface(cornerRadius: 14)
                .foregroundStyle(destructive ? Color.red : Color.primary)
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }.buttonStyle(.plain)
    }

    private func performPendingAction() {
        let action = pendingAction
        pendingAction = nil
        guard canInteract, let action else { return }
        switch action {
        case .details(let route):
            store.cancelResume()
            if let openDetails { openDetails(route) } else { openRoute?(route) }
        case .resume(let mode): resume(mode: mode)
        case .remove: store.playbackHistory.remove(entry.id)
        }
    }
    #endif

    private var detailsRoute: Route? {
        guard openDetails != nil || openRoute != nil, let client = store.historyClient(entry) else { return nil }
        return Route { AnyView(VideoDetailView(video: entry.listVideo, client: client)) }
    }

    #if !os(iOS)
    @ViewBuilder private var menu: some View {
        if let route = detailsRoute {
            Button(L10n.text("Show Details"), systemImage: "info.circle") {
                guard canInteract else { return }
                store.cancelResume()
                if let openDetails { openDetails(route) } else { openRoute?(route) }
            }
        }
        Button(entry.completed ? "重新观看" : "继续观看", systemImage: "play.fill") { resume() }
        Button("从头播放", systemImage: "arrow.counterclockwise") { resume(mode: .beginning) }
        Button(L10n.text("Remove from history"), systemImage: "trash", role: .destructive) {
            guard canInteract else { return }
            store.playbackHistory.remove(entry.id)
        }
    }
    #endif
}
