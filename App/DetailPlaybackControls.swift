import SwiftUI
import Foundation
import TVCore

#if os(iOS)
/// An unwatched episode has one action. Resumable history adds an explicit zero-time replay.
struct DetailPlaybackControls: View {
    let selection: DetailPlaybackSelection
    let busy: Bool
    let loadingMode: PlaybackResumeMode?
    let start: (PlaybackResumeMode) -> Void

    private var resumePosition: Double? { selection.position(for: .resume) }
    private var reading: ReadingHistoryProgress? { selection.readingProgress }
    private var canResume: Bool { selection.canResume }
    private var finishedReading: Bool { reading != nil && selection.history?.completed == true }
    private var beginningLabel: String { reading == nil ? "从 00:00 开始" : "从第 1 页开始" }
    private var progress: Double {
        guard let value = selection.history?.progress, value.isFinite else { return 0 }
        return min(1, max(0, value))
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if canResume && !finishedReading {
                    action(.beginning, title: reading == nil ? "重播" : "重新阅读", subtitle: beginningLabel, symbol: "arrow.counterclockwise")
                    Rectangle().fill(.primary.opacity(0.1)).frame(width: 1, height: 38).accessibilityHidden(true)
                }
                action(.resume, title: reading == nil ? (canResume ? "继续播放" : "开始播放") : (finishedReading ? "重新阅读" : "继续阅读"),
                       subtitle: context, symbol: reading == nil ? "play.fill" : "book.fill")
                    .background(Brand.accent.opacity(0.12))
            }
            if canResume {
                ProgressView(value: progress).tint(Brand.accent).frame(height: 3)
                    .accessibilityLabel(reading == nil ? "观看进度" : "阅读进度")
                    .accessibilityValue("\(Int((progress * 100).rounded()))%")
            }
        }
        .frame(maxWidth: .infinity)
        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5) }
        .accessibilityElement(children: .contain).accessibilityLabel("播放模式")
    }
    private var context: String {
        if finishedReading { return [selection.episode?.name, beginningLabel].compactMap { $0 }.joined(separator: " · ") }
        let position = reading.map { "第 \($0.page + 1) / \($0.totalPages) 页" } ?? resumePosition.map(time)
        return [selection.episode?.name, position].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
    private func action(_ mode: PlaybackResumeMode, title: String, subtitle: String, symbol: String) -> some View {
        Button { start(mode) } label: {
            HStack(spacing: 8) {
                if busy && loadingMode == mode { ProgressView().controlSize(.small) }
                else { Image(systemName: symbol).font(.system(size: 23, weight: .semibold)).foregroundStyle(Brand.accent) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 21, weight: .semibold)).lineLimit(1)
                    Text(subtitle).font(.system(size: 17)).foregroundStyle(.secondary).lineLimit(1)
                }
            }.frame(maxWidth: .infinity, minHeight: 64, alignment: .leading).padding(.horizontal, 13)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(busy || selection.episode == nil)
        .accessibilityLabel(title + " " + (selection.episode?.name ?? ""))
        .accessibilityValue(mode == .beginning ? beginningLabel : context)
        .accessibilityIdentifier(mode == .beginning ? "detail.playBeginning" : "detail.play")
    }
    private func time(_ position: Double) -> String {
        let value = Int(position.isFinite ? min(Double(Int.max / 2), max(0, position)) : 0)
        return value >= 3_600 ? String(format: "%d:%02d:%02d", value / 3_600, value / 60 % 60, value % 60)
                             : String(format: "%02d:%02d", value / 60, value % 60)
    }
}
#endif
