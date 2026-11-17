#if !os(tvOS)
import SwiftUI
import Perception
import TVCore

/// Centered lyrics remain part of the iPhone player. Timed lines follow playback until the
/// listener scrolls to read ahead; tapping a line seeks and resumes following.
struct MusicNowPlayingLyrics: View {
    @Environment(Store.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var dragging = false
    @State private var followsPlayback = true
    @State private var returnRevision = 0
    var showsTranslation = true
    var centered = false
    var compact = false
    #if os(macOS)
    private let baseSize: CGFloat = 32, baseTranslation: CGFloat = 18, baseSpacing: CGFloat = 30
    #else
    private let baseSize: CGFloat = 24, baseTranslation: CGFloat = 14, baseSpacing: CGFloat = 20
    #endif
    private var size: CGFloat { compact ? baseSize - 3 : baseSize }
    private var lineSpacing: CGFloat { compact ? 16 : baseSpacing }
    private var anchor: UnitPoint { centered ? .center : UnitPoint(x: 0.5, y: 0.3) }

    var body: some View {
        WithPerceptionTracking {
            let music = store.music
            if let lyrics = music.lyrics, !lyrics.lines.isEmpty {
                GeometryReader { geometry in
                    ScrollViewReader { reader in
                        WithPerceptionTracking {
                            ScrollView(showsIndicators: false) {
                                LazyVStack(alignment: centered ? .center : .leading, spacing: lineSpacing) {
                                    ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { index, line in
                                        WithPerceptionTracking {
                                            lyricLine(line, index: index, synced: lyrics.synced, active: music.currentLyric) {
                                                guard lyrics.synced else { return }
                                                music.seek(toLyric: line); followsPlayback = true
                                                withAnimation(reduceMotion ? nil : .appSmooth(duration: 0.5)) { reader.scrollTo(index, anchor: anchor) }
                                            }.id(index)
                                        }
                                    }
                                    Text(L10n.text("Lyrics from %@", lyrics.platform.name)).font(.caption2).foregroundStyle(.white.opacity(0.3)).padding(.top, 8)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, centered ? max(20, geometry.size.height / 2 - 30) : 28)
                            }
                            .simultaneousGesture(DragGesture(minimumDistance: 8).updating($dragging) { _, dragging, _ in dragging = true }
                                .onChanged { _ in followsPlayback = false })
                            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12),
                                                         .init(color: .black, location: 0.86), .init(color: .clear, location: 1)],
                                                 startPoint: .top, endPoint: .bottom))
                            .task(id: lyrics) {
                                followsPlayback = true
                                try? await Task.sleep(for: .milliseconds(60))
                                guard !Task.isCancelled, !dragging else { return }
                                reader.scrollTo(music.currentLyric ?? 0, anchor: anchor)
                            }
                            .appOnChange(of: music.currentLyric) { _, index in
                                guard !dragging, followsPlayback else { return }
                                withAnimation(reduceMotion || music.seekingTo != nil ? nil : .appSmooth(duration: 0.45)) {
                                    reader.scrollTo(index ?? 0, anchor: anchor)
                                }
                            }
                            .appOnChange(of: music.timelineRevision) { _, _ in
                                // A scrubber/remote seek resumes following immediately, even
                                // within one line or back into the intro before the first line.
                                followsPlayback = true; returnRevision += 1
                                guard !dragging else { return }
                                reader.scrollTo(music.currentLyric ?? 0, anchor: anchor)
                            }
                            .appOnChange(of: dragging) { _, isDragging in
                                if !isDragging {
                                    returnRevision += 1
                                    if followsPlayback { reader.scrollTo(music.currentLyric ?? 0, anchor: anchor) }
                                }
                            }
                            .task(id: returnRevision) {
                                guard !followsPlayback else { return }
                                try? await Task.sleep(for: .seconds(4))
                                guard !Task.isCancelled, !dragging else { return }
                                followsPlayback = true
                                withAnimation(reduceMotion ? nil : .appSmooth(duration: 0.45)) {
                                    reader.scrollTo(music.currentLyric ?? 0, anchor: anchor)
                                }
                            }
                        }
                    }
                }
                .accessibilityIdentifier("music.nowPlaying.lyrics")
            } else if music.lyricsLoading || music.busy {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "music.note").font(.system(size: 25)).foregroundStyle(.white.opacity(0.4))
                    Text(L10n.text("No Lyrics")).font(.system(size: 16, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
    private func lyricLine(_ line: MusicLyricLine, index: Int, synced: Bool, active: Int?, seek: @escaping () -> Void) -> some View {
        let selected = !synced || index == active
        let distance = active.map { abs($0 - index) } ?? 1
        return VStack(alignment: centered ? .center : .leading, spacing: 5) {
            Text(line.text.isEmpty ? "♪" : line.text).font(.system(size: size, weight: selected ? .bold : .medium))
                .fixedSize(horizontal: false, vertical: true)
            if showsTranslation, let translation = line.translation, !translation.isEmpty {
                Text(translation).font(.system(size: compact ? 12 : baseTranslation, weight: .medium)).foregroundStyle(.white.opacity(selected ? 0.72 : 0.46))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showsTranslation, let romanization = line.romanization, !romanization.isEmpty,
               romanization != line.text, romanization != line.translation {
                Text(romanization).font(.system(size: compact ? 11 : baseTranslation, weight: .regular))
                    .foregroundStyle(.white.opacity(selected ? 0.64 : 0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .multilineTextAlignment(centered ? .center : .leading)
        .foregroundStyle(.white.opacity(selected ? 1 : distance == 1 ? 0.4 : 0.24))
        .blur(radius: centered && synced && !selected ? (distance > 1 ? 1.2 : 0.45) : 0)
        .scaleEffect(selected ? 1 : 0.96)
        .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: selected)
        .contentShape(Rectangle()).onTapGesture(perform: seek)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(synced ? .isButton : [])
        .accessibilityAddTraits(selected && synced ? .isSelected : [])
        .accessibilityHint(synced ? "轻点从此句播放" : "")
    }
}

/// The songs after this one in what is playing; tapping one plays it.
struct MusicUpNext: View {
    @Environment(Store.self) private var store

    var body: some View {
        WithPerceptionTracking {
            let music = store.music
            let queue = music.queue
            let upcoming = queue.map { queue in Array(queue.tracks.enumerated()).filter { $0.offset > queue.index } } ?? []
            if upcoming.isEmpty {
                AppContentUnavailableView(L10n.text("Nothing Up Next"), systemImage: "list.bullet",
                                       description: Text(L10n.text("Play a song from search results, an album or a playlist, and the songs after it play next.")))
            } else {
                ScrollView(showsIndicators: false) {
                    WithPerceptionTracking {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            WithPerceptionTracking {
                                Text(L10n.text("Up Next")).font(.headline).padding(.bottom, 6)
                                ForEach(upcoming, id: \.offset) { index, track in
                                    WithPerceptionTracking {
                                        Button { music.jump(to: index) } label: {
                                            HStack(spacing: 12) {
                                                MusicArtwork(url: track.artwork, size: 44)
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text(track.title).font(.body.weight(.medium)).lineLimit(1)
                                                    Text(track.artistLine).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                                }
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                if let duration = track.duration {
                                                    Text(MusicTime.text(duration)).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                                                }
                                            }
                                            .padding(.vertical, 6)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 12)
                    }
                }
            }
        }
    }
}
#endif
