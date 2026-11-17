#if os(iOS)
import AVKit
import MediaPlayer
import SwiftUI
import Perception
import TVCore

/// A compact vinyl cover above permanent centered lyrics, with the transport beside the song title.
struct MusicNowPlayingScreen: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var tint = Color(white: 0.24)
    @State private var showsChannels = false
    @State private var showsQueue = false
    @State private var showsMore = false
    @GestureState private var pullDown: CGFloat = 0

    var body: some View {
        WithPerceptionTracking {
            let music = store.music
            GeometryReader { geometry in
                WithPerceptionTracking {
                    let short = geometry.size.height < 640
                    let wide = geometry.size.width > geometry.size.height
                    let recordSize = min(wide ? 106 : 184, max(wide ? 64 : 92, geometry.size.height * (wide ? 0.22 : 0.25)))
                    VStack(spacing: 0) {
                        if wide {
                            HStack(spacing: 20) {
                                topArtwork(music, size: recordSize, short: true).frame(width: recordSize + 28)
                                MusicNowPlayingLyrics(centered: true, compact: true)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }.frame(maxHeight: .infinity).padding(.bottom, 8)
                        } else {
                            topArtwork(music, size: recordSize, short: short)
                            MusicNowPlayingLyrics(centered: true, compact: short)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .padding(.top, short ? 6 : 14).padding(.bottom, short ? 8 : 18)
                        }
                        VStack(spacing: 0) {
                            header(music, short: short)
                            MusicScrubber().padding(.top, short ? 6 : 12)
                            quality(music)
                            bottomBar
                        }.padding(.bottom, 4)
                    }
                    .frame(maxWidth: wide ? 760 : 620).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, geometry.size.width < 350 ? 18 : 26)
                    .padding(.top, 4)
                    .offset(y: pullDown * 0.2)
                }
            }
            .foregroundStyle(.white).tint(.white)
            .background { WithPerceptionTracking { backdrop.ignoresSafeArea() } }
            .environment(\.colorScheme, .dark)
            .task(id: music.track?.artwork) {
                guard let url = music.track?.artwork, let color = await PosterPalette.average(url), !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.6)) { tint = color }
            }
            .appOnChange(of: music.track == nil) { _, gone in if gone { dismiss() } }
            .accessibilityAction(.escape) { dismiss() }
            .musicMoreDialog(isPresented: $showsMore, showChannels: { showsChannels = true })
            .sheet(isPresented: $showsChannels) { WithPerceptionTracking { MusicChannelsView() } }
            .sheet(isPresented: $showsQueue) {
                NavigationStack {
                    MusicUpNext().padding(.horizontal, 22)
                        .navigationTitle(L10n.text("Up Next")).navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { showsQueue = false } } }
                        .background { WithPerceptionTracking { backdrop.ignoresSafeArea() } }
                }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
                    .environment(\.colorScheme, .dark).tint(.white)
            }
        }
    }

    private var backdrop: some View {
        GeometryReader { geometry in
            ZStack {
                tint.blend(with: .black, by: 0.4)
                PosterImage(url: store.music.track?.artwork, symbol: "music.note")
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .scaleEffect(1.06).blur(radius: 7)
                LinearGradient(colors: [tint.blend(with: .black, by: 0.4).opacity(0.45), .black.opacity(0.73)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }.clipped()
        }.allowsHitTesting(false).accessibilityHidden(true)
    }

    private func topArtwork(_ music: MusicPlaybackSession, size: CGFloat, short: Bool) -> some View {
        VStack(spacing: short ? 2 : 7) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                    .frame(width: 56, height: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("收起音乐播放器").accessibilityIdentifier("music.nowPlaying.dismiss")
            MusicVinylArtwork(url: music.track?.artwork, trackID: music.track?.id ?? "", size: size, playing: music.isPlaying)
                .padding(.bottom, short ? 2 : 6)
        }
        .frame(maxWidth: .infinity).contentShape(Rectangle())
        // Only the handle/record owns this gesture. Scrolling lyrics, queue and either slider never reaches it.
        .simultaneousGesture(DragGesture(minimumDistance: 16)
            .updating($pullDown) { value, state, _ in
                if value.translation.height > abs(value.translation.width) * 1.3 { state = max(0, value.translation.height) }
            }
            .onEnded { value in
                if MusicNowPlayingDismissal.shouldDismiss(x: value.translation.width, y: value.translation.height,
                                                          predictedY: value.predictedEndTranslation.height) { dismiss() }
            })
    }

    private func header(_ music: MusicPlaybackSession, short: Bool) -> some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 3) {
                Text(music.track?.title ?? "").font(.system(size: short ? 16 : 18, weight: .bold)).lineLimit(1)
                Text(music.track?.artistLine ?? "").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
            HStack(spacing: 0) {
                control("backward.fill", size: 18, label: "Previous") { music.previous() }
                if music.failure != nil {
                    control("arrow.clockwise", size: 21, label: "Retry") { music.retry() }
                } else if music.busy && !music.isPlaying {
                    ProgressView().controlSize(.small).frame(width: 44, height: 44)
                } else {
                    control(music.isPlaying ? "pause.fill" : "play.fill", size: 23, label: music.isPlaying ? "Pause" : "Play") { music.toggle() }
                }
                control("forward.fill", size: 18, label: "Next") { music.next() }.disabled(!music.canAdvance)
            }.fixedSize().accessibilityElement(children: .contain).accessibilityLabel("播放控制")
            Button { showsMore = true } label: {
                Image(systemName: "ellipsis").font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(L10n.text("More"))
                .accessibilityIdentifier("music.nowPlaying.more")
        }.frame(minHeight: 48)
    }

    private func quality(_ music: MusicPlaybackSession) -> some View {
        Button { showsChannels = true } label: {
            Group {
                if let failure = music.failure { Text(failure).foregroundStyle(Brand.amber) }
                else if music.phase == .resolving { Text(L10n.text("Finding the best channel…")) }
                else if let selection = music.selection {
                    let format = selection.probe.format.codec == .unknown ? L10n.text("Quality to be confirmed") : selection.probe.format.label
                    Text(selection.degraded ? format + " · " + L10n.text("Lossy quality") : format)
                } else { Text(" ") }
            }
            .font(.caption.weight(.semibold)).monospacedDigit().lineLimit(1).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(.white.opacity(music.selection == nil ? 0 : 0.1), in: Capsule())
        }.buttonStyle(.plain).frame(height: 26).padding(.top, 2)
    }
    private func control(_ symbol: String, size: CGFloat, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: size)).frame(width: 44, height: 44).contentShape(Rectangle()) }
            .buttonStyle(.plain).accessibilityLabel(L10n.text(label))
    }
    private var bottomBar: some View {
        HStack {
            Spacer()
            Button { store.music.cyclePlaybackMode() } label: {
                Image(systemName: store.music.playbackMode.symbol).font(.system(size: 19))
                    .foregroundStyle(.white.opacity(0.85)).frame(width: 48, height: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("播放模式")
                .accessibilityValue(store.music.playbackMode.label)
                .accessibilityHint("轻点切换为" + store.music.playbackMode.next.label)
                .accessibilityIdentifier("music.nowPlaying.playbackMode")
            Spacer()
            MusicRoutePicker().frame(width: 44, height: 44).accessibilityLabel("AirPlay")
            Spacer()
            Button { showsQueue = true } label: {
                Image(systemName: "list.bullet").font(.system(size: 20)).foregroundStyle(.white.opacity(0.65)).frame(width: 48, height: 44)
            }.buttonStyle(.plain).accessibilityLabel(L10n.text("Up Next")).accessibilityIdentifier("music.nowPlaying.queue")
            Spacer()
        }.frame(height: 48)
    }
}

extension View {
    /// The same raised glass actions serve the full player and the compact player card.
    func musicMoreDialog(isPresented: Binding<Bool>, showLyrics: (() -> Void)? = nil,
                         showChannels: @escaping () -> Void) -> some View {
        modifier(MusicMoreDialog(isPresented: isPresented, showLyrics: showLyrics, showChannels: showChannels))
    }
}

private struct MusicMoreDialog: ViewModifier {
    @Binding var isPresented: Bool
    var showLyrics: (() -> Void)?
    let showChannels: () -> Void
    @State private var selectedAction: (() -> Void)?

    func body(content: Content) -> some View {
        content.localGlassDialog(isPresented: $isPresented, title: L10n.text("More"), maxWidth: 380,
                                 maxHeight: 540, layout: .centered, onDismiss: {
            // Presenting Channels or Share while this modal is closing loses the new
            // presentation on iOS 16. Run the chosen action after dismissal completes.
            let action = selectedAction
            selectedAction = nil
            action?()
        }) {
            MusicMoreActions(showLyrics: showLyrics, showChannels: showChannels) { action in
                selectedAction = action
                isPresented = false
            }
        }
    }
}

private struct MusicMoreActions: View {
    @Environment(Store.self) private var store
    var showLyrics: (() -> Void)?
    let showChannels: () -> Void
    let perform: (@escaping () -> Void) -> Void

    var body: some View {
        WithPerceptionTracking {
            let music = store.music
            ScrollView {
                VStack(spacing: 10) {
                    if let track = music.track {
                        let favorite = store.favorites.contains(.music(track))
                        action(favorite ? "Unlike" : "Like", symbol: favorite ? "heart.slash" : "heart") {
                            store.favorites.toggle(.music(track))
                        }
                        .accessibilityLabel(L10n.text(favorite ? "Remove %@ from favorites" : "Add %@ to favorites", track.title))
                        .disabled(!store.favorites.isEnabled)
                    }
                    if let showLyrics { action("Lyrics", symbol: "quote.bubble", work: showLyrics) }
                    if music.sourceStream != nil {
                        action("Open in Video Player", symbol: "play.rectangle") { music.openInVideoPlayer() }
                    } else {
                        action("Channels", symbol: "antenna.radiowaves.left.and.right", work: showChannels)
                    }
                    if let track = music.track, track.source == nil {
                        let library = MusicDownloadLibrary.shared
                        if let saved = library.item(for: track) {
                            if let file = library.file(for: track) {
                                action("Save or Share", symbol: "square.and.arrow.up") {
                                    DownloadSharing.share(file, named: MusicDownloadLibrary.exportName(for: track))
                                }
                            }
                            action(saved.status == .completed ? "Remove Download" : "Cancel Download", symbol: "trash", destructive: true) {
                                library.remove([saved.id])
                            }
                        } else {
                            action("Download", symbol: "arrow.down.circle") { library.download([track]) }
                        }
                    }
                    action("Stop", symbol: "xmark", destructive: true) { music.stop() }
                }
                .padding(.horizontal, 18).padding(.top, 4).padding(.bottom, 20)
                .localDialogContentHeight()
            }
            .accessibilityIdentifier("music.nowPlaying.moreActions")
        }
    }

    private func action(_ title: String, symbol: String, destructive: Bool = false,
                        work: @escaping () -> Void) -> some View {
        Button(role: destructive ? .destructive : nil) { perform(work) } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).frame(width: 24)
                Text(L10n.text(title)).font(.body.weight(.medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(destructive ? Brand.rose : Color.primary)
        }.buttonStyle(MusicMoreActionStyle())
    }
}

private struct MusicMoreActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 14).frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .localGlassSurface(cornerRadius: 14)
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

/// The device volume, drawn like the scrubber: a thin bar between a quiet and a loud speaker that
/// thickens while dragged and follows the volume buttons. The system's own slider draws nothing in
/// the Simulator and looks unlike the rest; a hidden copy of it carries the changes, as players
/// do, and while it is on screen the system's volume overlay stays away.
struct MusicVolumeSlider: View {
    @State private var level = Double(AVAudioSession.sharedInstance().outputVolume)
    @State private var dragging = false
    @State private var system = SystemSlider()

    var body: some View {
        WithPerceptionTracking {
            HStack(spacing: 12) {
                Image(systemName: "speaker.fill")
                GeometryReader { proxy in
                    WithPerceptionTracking {
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.22))
                            Capsule().fill(.white.opacity(dragging ? 1 : 0.78)).frame(width: max(0, proxy.size.width * level))
                        }
                        .frame(height: dragging ? 12 : 7)
                        .frame(maxHeight: .infinity)
                        .contentShape(.rect)
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                dragging = true
                                level = min(1, max(0, value.location.x / proxy.size.width))
                                system.set(level)
                            }
                            .onEnded { _ in dragging = false })
                        .animation(.easeOut(duration: 0.15), value: dragging)
                    }
                }
                .frame(height: 22)
                Image(systemName: "speaker.wave.3.fill")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(height: 40)
            .background { WithPerceptionTracking { HiddenVolumeView(system: system).frame(width: 1, height: 1).opacity(0.01) } }
            .onReceive(AVAudioSession.sharedInstance().publisher(for: \.outputVolume)) { volume in
                if !dragging { withAnimation(.easeOut(duration: 0.15)) { level = Double(volume) } }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.text("Volume"))
            .accessibilityValue(Text(level, format: .percent.precision(.fractionLength(0))))
            .accessibilityAdjustableAction { direction in
                level = min(1, max(0, level + (direction == .increment ? 0.0625 : -0.0625)))
                system.set(level)
            }
        }
    }

    /// The system slider inside the hidden volume view, once it exists.
    @MainActor final class SystemSlider {
        weak var slider: UISlider?
        func set(_ value: Double) { slider?.setValue(Float(value), animated: false); slider?.sendActions(for: .valueChanged) }
    }

    /// Also carries the player's slides up and down for the volume.
    struct HiddenVolumeView: UIViewRepresentable {
        let system: SystemSlider
        func makeUIView(context: Context) -> MPVolumeView {
            let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            system.slider = view.subviews.compactMap { $0 as? UISlider }.first
            return view
        }
        func updateUIView(_ view: MPVolumeView, context: Context) {
            if system.slider == nil { system.slider = view.subviews.compactMap { $0 as? UISlider }.first }
        }
    }
}

/// The system's AirPlay button.
struct MusicRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = UIColor.white.withAlphaComponent(0.6)
        view.activeTintColor = .white
        view.prioritizesVideoDevices = false
        return view
    }
    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
#endif
