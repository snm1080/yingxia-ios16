import SwiftUI
import Perception
import TVCore

/// A cover, always square with the same rounding for its size, however the image is shaped:
/// rows, the mini player and the Now Playing screen all draw covers through this.
struct MusicArtwork: View {
    let url: URL?
    var size: CGFloat?
    var symbol = "music.note"
    var body: some View {
        WithPerceptionTracking {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { WithPerceptionTracking { PosterImage(url: url, symbol: symbol) } }
                .frame(width: size, height: size)
                .posterClip(RoundedRectangle(cornerRadius: size.map { max(4, $0 * 0.12) } ?? 12, style: .continuous))
        }
    }
}

#if os(iOS)
/// The player as a strip above the tab bar, as in Music: cover, title and artist, play and next.
/// It is always the same height; the lyrics and everything else are on the Now Playing screen,
/// which a tap opens. `inline` is the narrower form beside a minimized tab bar.
struct MusicMiniPlayer: View {
    @Environment(Store.self) private var store
    var inline = false

    var body: some View {
        WithPerceptionTracking {
            let music = store.music
            HStack(spacing: 0) {
                // A real label-wide button owns the artwork, text and empty space.
                // A parent tap/drag gesture around transport buttons can lose the
                // initial touch to the covered song list on iOS 16.
                Button {
                    // Build 37 probe: a received tap logs here even when the cover then
                    // fails to appear, which separates dead hit-testing from a wedged
                    // main thread or a dropped presentation (category music.ui).
                    Diagnostics.shared.record(.info, "music.ui", "strip open tap phase=\(music.phase) presentsPlayer=\(music.presentsPlayer)")
                    music.presentsPlayer = true
                    Diagnostics.shared.record(.info, "music.ui", "strip open applied presentsPlayer=\(music.presentsPlayer)")
                } label: {
                    HStack(spacing: inline ? 10 : 12) {
                        MusicArtwork(url: music.track?.artwork, size: inline ? 28 : 34)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(music.track?.title ?? "").font(.system(size: 17, weight: .semibold)).lineLimit(1)
                            if let failure = music.failure {
                                Text(failure).font(.system(size: 14)).foregroundStyle(Brand.amber).lineLimit(1)
                            } else if !inline {
                                Text(music.track?.artistLine ?? "").font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, inline ? 6 : 10).padding(.trailing, inline ? 4 : 6)
                    .frame(maxWidth: .infinity, minHeight: 44, maxHeight: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(L10n.text("Now Playing"))
                .accessibilityIdentifier("music.miniPlayer.open")
                HStack(spacing: inline ? 0 : 2) {
                    if music.failure != nil {
                        button("arrow.clockwise", label: "Retry") { music.retry() }
                    } else if music.busy && !music.isPlaying {
                        Button {
                            Diagnostics.shared.record(.info, "music.ui", "strip open tap (busy) phase=\(music.phase) presentsPlayer=\(music.presentsPlayer)")
                            music.presentsPlayer = true
                            Diagnostics.shared.record(.info, "music.ui", "strip open applied presentsPlayer=\(music.presentsPlayer)")
                        } label: {
                            ProgressView().frame(width: 44, height: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).accessibilityLabel(L10n.text("Now Playing"))
                    } else {
                        button(music.isPlaying ? "pause.fill" : "play.fill", label: music.isPlaying ? "Pause" : "Play") { music.toggle() }
                            .modifier(MusicPlayPauseTransition())
                    }
                    if !inline {
                        button("forward.fill", label: "Next") { music.next() }.disabled(!music.canAdvance)
                        // Closes the strip without opening Now Playing first; Continue Playing keeps the song.
                        button("xmark", label: "Stop") { music.stop() }.font(.body).foregroundStyle(.secondary)
                    }
                }
                .font(.title3)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.trailing, inline ? 4 : 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .contextMenu {
                WithPerceptionTracking {
                    Button(role: .destructive) { music.stop() } label: { Label(L10n.text("Stop"), systemImage: "xmark") }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: L10n.text("Now Playing")) { music.presentsPlayer = true }
            .accessibilityAction(named: L10n.text("Stop")) { music.stop() }
        }
    }

    private func button(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            // Build 37 probe: tap receipt for the strip's transport actions (music.ui).
            let music = store.music
            Diagnostics.shared.record(.info, "music.ui", "strip \(label) tap phase=\(music.phase) presentsPlayer=\(music.presentsPlayer)")
            action()
            Diagnostics.shared.record(.info, "music.ui", "strip \(label) applied phase=\(music.phase) presentsPlayer=\(music.presentsPlayer)")
        } label: {
            Image(systemName: symbol).frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.text(label))
    }
}

private struct MusicPlayPauseTransition: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.contentTransition(.symbolEffect(.replace))
        } else {
            content.contentTransition(.opacity)
        }
    }
}

/// The tab bar's accessory slot (iOS 26.1): the system floats the mini player above the bar and
/// tucks it in beside the bar when scrolling minimizes it, with its own animation. Before 26.1
/// there is no way to hide the slot, so pages show the strip themselves (`musicPlayerInset`).
extension View {
    @ViewBuilder func musicAccessory(enabled: Bool) -> some View {
        #if TVBOX_SDK26_1 && compiler(>=6.2)
        if #available(iOS 26.1, *) {
            tabViewBottomAccessory(isEnabled: enabled) { WithPerceptionTracking { MusicAccessoryContent() } }
        } else {
            self
        }
        #else
        self
        #endif
    }
}

enum MusicAccessory {
    /// The system's accessory holds the mini player: iOS 26.1 on a phone.
    static func used(compact: Bool) -> Bool {
        #if TVBOX_SDK26_1 && compiler(>=6.2)
        if #available(iOS 26.1, *) { return compact }
        #endif
        return false
    }
}

#if TVBOX_SDK26_1 && compiler(>=6.2)
@available(iOS 26.1, *)
private struct MusicAccessoryContent: View {
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    var body: some View { WithPerceptionTracking { MusicMiniPlayer(inline: placement == .inline) } }
}
#endif
#endif
