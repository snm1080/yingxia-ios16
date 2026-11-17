import Foundation

/// Picture PTS is a fixed media timestamp, sampled at the video's cadence. Project only the
/// small interval between pictures; ordinary samples correct the rate without moving text back.
struct DanmakuTimelineClock: Sendable {
    private var media = 0.0
    private var wall = 0.0
    private var picture = Double.nan
    private var pictureWall = 0.0
    private var speed = 1.0
    private var correction = 1.0
    private var stopped = true
    private var revision: Int?
    private let maximumPictureAge = 0.35
    var playbackRate: Double { speed * correction }

    func isWaitingForPicture(at now: Double) -> Bool {
        revision == nil || stopped || now >= pictureWall + maximumPictureAge
    }

    func time(at now: Double) -> Double {
        guard revision != nil, !stopped else { return media }
        let end = min(now, pictureWall + maximumPictureAge)
        return media + max(0, end - wall) * speed * correction
    }

    mutating func sample(position: Double, stopped nextStopped: Bool, speed requestedSpeed: Double,
                         revision nextRevision: Int, at now: Double) -> Double {
        guard now.isFinite else { return media }
        let nextSpeed = requestedSpeed.isFinite && requestedSpeed > 0 ? min(8, max(0.25, requestedSpeed)) : 1
        guard position.isFinite, position >= 0 else { return time(at: now) }
        if revision != nextRevision {
            media = position; wall = now; picture = position; pictureWall = now
            speed = nextSpeed; correction = 1; stopped = nextStopped; revision = nextRevision
            return media
        }
        let predicted = time(at: now)
        let wasStopped = stopped
        if stopped != nextStopped || speed != nextSpeed {
            media = predicted; wall = now; stopped = nextStopped; speed = nextSpeed
        }
        if position != picture {
            let elapsed = max(0, now - pictureWall)
            let delta = position - picture
            let discontinuity = delta < -max(0.3, speed * 0.1) || delta > max(1, (elapsed + 0.5) * speed)
            let resumedAfterStall = elapsed > maximumPictureAge && abs(position - predicted) > maximumPictureAge * speed
            if discontinuity || resumedAfterStall || (stopped && wasStopped) {
                media = position; correction = 1
            } else {
                media = predicted
                correction = 1 + min(0.02, max(-0.02, (position - predicted) * 0.1 / speed))
            }
            wall = now; picture = position; pictureWall = now
        }
        return time(at: now)
    }
}

/// Timing values applied to a CoreAnimation parent layer. Ordinary repeated
/// samples do not commit a new layer tree; clock-rate changes and real drift
/// keep the compositor within one 120 Hz frame of the picture clock.
struct DanmakuLayerClock: Sendable {
    struct Anchor: Sendable {
        let media: Double, wall: Double, rate: Double
    }
    private var anchor: Anchor?
    private var revision: Int?
    mutating func invalidate() { anchor = nil }
    mutating func synchronize(media: Double, rate: Double, revision: Int, at wall: Double) -> Anchor? {
        guard media.isFinite, rate.isFinite, rate >= 0, wall.isFinite else { return nil }
        if let anchor, self.revision == revision, abs(anchor.rate - rate) < 0.000001,
           abs(anchor.media + max(0, wall - anchor.wall) * anchor.rate - media) <= 1.0 / 120 { return nil }
        let next = Anchor(media: media, wall: wall, rate: rate)
        anchor = next; self.revision = revision
        return next
    }
}
