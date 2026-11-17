import SwiftUI
import Perception

/// Shares one reader presentation across detail, favorites, history and push-source playback.
struct LocalReadingPresentation: ViewModifier {
    @Environment(Store.self) private var store

    func body(content: Content) -> some View {
        WithPerceptionTracking {
            #if os(iOS) || os(tvOS)
            content.fullScreenCover(item: Binding(get: { store.localReading }, set: { value in
                if value == nil { store.localReading?.close() }
                store.localReading = value
            })) { session in
                WithPerceptionTracking {
                    MangaReaderView(session: session).environment(store)
                }
            }
            #else
            content.sheet(item: Binding(get: { store.localReading }, set: { value in
                if value == nil { store.localReading?.close() }
                store.localReading = value
            })) { session in
                WithPerceptionTracking { MangaReaderView(session: session).environment(store).frame(minWidth: 640, minHeight: 600) }
            }
            #endif
        }
    }
}
