//
//  EmbedDataSouce.swift
//  KSPlayer-7de52535
//
//  Created by kintan on 2018/8/7.
//
import Foundation
import FFmpegKit
extension FFmpegAssetTrack: SubtitleInfo {
    public var subtitleID: String {
        String(trackID)
    }
}

extension FFmpegAssetTrack: KSSubtitleProtocol {
    public func search(for time: TimeInterval) -> [SubtitlePart] {
        // PGS/DVB display updates use an indefinite end followed by a replacement or an
        // empty clear cue. Keep one display update until the next starts; cues from the same
        // update share their start and must remain together.
        var replacementStart = -TimeInterval.infinity
        return subtitle?.outputRenderQueue.search(inspecting: {
            if $0.part.start <= time { replacementStart = max(replacementStart, $0.part.start) }
        }, removing: {
            $0.part.end < time || (!$0.part.end.isFinite && $0.part.start < replacementStart)
        }) { item -> Bool in
            item.part == time
        }.map(\.part) ?? []
    }
}

extension KSMEPlayer: SubtitleDataSouce {
    public var infos: [any SubtitleInfo] {
        tracks(mediaType: .subtitle).compactMap { $0 as? (any SubtitleInfo) }
    }
}
