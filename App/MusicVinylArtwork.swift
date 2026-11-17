import Foundation

/// Integrate elapsed playing time, rather than restarting an animation when playback pauses.
struct MusicVinylPhase {
    private var elapsed: TimeInterval = 0
    private var started: TimeInterval?
    mutating func setRunning(_ running: Bool, at time: TimeInterval) {
        if running, started == nil { started = time }
        else if !running, let started { elapsed += max(0, time - started); self.started = nil }
    }
    mutating func reset(running: Bool, at time: TimeInterval) { elapsed = 0; started = running ? time : nil }
    func degrees(at time: TimeInterval) -> Double {
        (elapsed + (started.map { max(0, time - $0) } ?? 0)).truncatingRemainder(dividingBy: 24) * 15
    }
}

enum MusicNowPlayingDismissal {
    static func shouldDismiss(x: Double, y: Double, predictedY: Double) -> Bool {
        y > 28 && y > abs(x) * 1.3 && (y > 84 || predictedY > 180)
    }
}

#if os(iOS)
import SwiftUI
import Perception

struct MusicVinylArtwork: View {
    let url: URL?
    let trackID: String
    let size: CGFloat
    let playing: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = MusicVinylPhase()
    @State private var visible = false
    private var running: Bool { visible && playing && scenePhase == .active && !reduceMotion }
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !running)) { _ in
            WithPerceptionTracking {
                record.rotationEffect(.degrees(phase.degrees(at: now)))
            }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.4), radius: 16, y: 10)
        .onAppear { visible = true; phase.setRunning(playing && scenePhase == .active && !reduceMotion, at: now) }
        .onDisappear { phase.setRunning(false, at: now); visible = false }
        .appOnChange(of: running) { _, active in phase.setRunning(active, at: now) }
        .appOnChange(of: trackID) { _, _ in phase.reset(running: running, at: now) }
        .accessibilityLabel("黑胶唱片封面").accessibilityValue(playing ? "正在播放" : "已暂停")
    }
    private var record: some View {
        ZStack {
            Circle().fill(Color(red: 0.07, green: 0.075, blue: 0.075))
            ForEach(0..<7) { ring in
                Circle().strokeBorder(.white.opacity(ring.isMultiple(of: 2) ? 0.055 : 0.025), lineWidth: 1)
                    .padding(CGFloat(ring) * 3 + 6)
            }
            AngularGradient(colors: [.clear, .white.opacity(0.08), .clear, .black.opacity(0.2), .clear], center: .center)
                .clipShape(Circle())
            PosterImage(url: url, symbol: "music.note")
                .frame(width: size * 0.68, height: size * 0.68).clipShape(Circle())
            Circle().fill(Color(red: 0.09, green: 0.09, blue: 0.075))
                .frame(width: 11, height: 11)
                .overlay { Circle().strokeBorder(Color(red: 0.8, green: 0.7, blue: 0.54), lineWidth: 2) }
        }
        .overlay { Circle().strokeBorder(Color(red: 0.25, green: 0.22, blue: 0.18), lineWidth: 1.5) }
        .overlay { Circle().strokeBorder(.black.opacity(0.5), lineWidth: 3).padding(-3) }
    }
}
#endif
