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
            ZStack {
                labels(music).allowsHitTesting(false).accessibilityHidden(true)
                // Ported from lmentor build06: a single native responder owns
                // both the painted empty space and the controls, so the strip's
                // taps cannot be lost to SwiftUI hit-testing on iOS 16 (the
                // SwiftUI Buttons this replaces had a history of dead taps).
                // The build 37 tap-receipt probes (category music.ui) are kept
                // in the action closures.
                MusicMiniPlayerTouchSurface(inline: inline,
                    title: [music.track?.title, music.track?.artistLine, music.failure].compactMap { $0 }.joined(separator: ", "),
                    transportLabel: L10n.text(music.failure != nil ? "Retry" : music.busy && !music.isPlaying ? "Now Playing" : music.isPlaying ? "Pause" : "Play"),
                    canAdvance: music.canAdvance,
                    open: {
                        Diagnostics.shared.record(.info, "music.ui", "strip open tap phase=\(music.phase) presentsPlayer=\(music.presentsPlayer)")
                        music.presentsPlayer = true
                        Diagnostics.shared.record(.info, "music.ui", "strip open applied presentsPlayer=\(music.presentsPlayer)")
                    },
                    transport: {
                        if music.failure != nil {
                            Diagnostics.shared.record(.info, "music.ui", "strip Retry tap phase=\(music.phase) presentsPlayer=\(music.presentsPlayer)")
                            music.retry()
                            Diagnostics.shared.record(.info, "music.ui", "strip Retry applied phase=\(music.phase) presentsPlayer=\(music.presentsPlayer)")
                        } else if music.busy && !music.isPlaying {
                            Diagnostics.shared.record(.info, "music.ui", "strip open tap (busy) phase=\(music.phase) presentsPlayer=\(music.presentsPlayer)")
                            music.presentsPlayer = true
                            Diagnostics.shared.record(.info, "music.ui", "strip open applied presentsPlayer=\(music.presentsPlayer)")
                        } else {
                            let label = music.isPlaying ? "Pause" : "Play"
                            Diagnostics.shared.record(.info, "music.ui", "strip \(label) tap phase=\(music.phase) presentsPlayer=\(music.presentsPlayer)")
                            music.toggle()
                            Diagnostics.shared.record(.info, "music.ui", "strip \(label) applied phase=\(music.phase) presentsPlayer=\(music.presentsPlayer)")
                        }
                    },
                    next: {
                        Diagnostics.shared.record(.info, "music.ui", "strip Next tap phase=\(music.phase) presentsPlayer=\(music.presentsPlayer)")
                        music.next()
                        Diagnostics.shared.record(.info, "music.ui", "strip Next applied phase=\(music.phase) presentsPlayer=\(music.presentsPlayer)")
                    },
                    stop: {
                        Diagnostics.shared.record(.info, "music.ui", "strip Stop tap phase=\(music.phase) presentsPlayer=\(music.presentsPlayer)")
                        music.stop()
                        Diagnostics.shared.record(.info, "music.ui", "strip Stop applied phase=\(music.phase) presentsPlayer=\(music.presentsPlayer)")
                    })
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Capsule())
            .accessibilityElement(children: .contain)
        }
    }

    private func labels(_ music: MusicPlaybackSession) -> some View {
        HStack(spacing: 0) {
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
            HStack(spacing: MusicMiniPlayerLayout.spacing(inline: inline)) {
                if music.failure != nil {
                    symbol("arrow.clockwise")
                } else if music.busy && !music.isPlaying {
                    ProgressView().frame(width: MusicMiniPlayerLayout.buttonWidth, height: 44)
                } else {
                    symbol(music.isPlaying ? "pause.fill" : "play.fill")
                        .modifier(MusicPlayPauseTransition())
                }
                if !inline {
                    symbol("forward.fill")
                    symbol("xmark").font(.body).foregroundStyle(.secondary)
                }
            }
            .font(.title3)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.trailing, MusicMiniPlayerLayout.trailing(inline: inline))
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name).frame(width: MusicMiniPlayerLayout.buttonWidth, height: 44)
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
