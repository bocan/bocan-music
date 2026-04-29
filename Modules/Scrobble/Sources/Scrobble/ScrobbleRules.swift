import Foundation

// MARK: - ScrobbleRules

/// The classic Last.fm scrobble eligibility rule, replicated for our local queue.
///
/// A play is **scrobble-eligible** when both:
/// 1. The track's `duration ≥ 30s` (services reject anything shorter).
/// 2. The user listened for `≥ 50%` of the track *or* `≥ 4 minutes`,
///    whichever comes first.
///
/// "Listened for" excludes time spent paused. Pauses during play are allowed
/// but their duration does not contribute to elapsed playtime.
///
/// This is a pure value type so it can be tested deterministically without
/// reaching for a real engine clock.
public enum ScrobbleRules {
    /// Tracks shorter than this are ineligible regardless of completion.
    public static let minimumDuration: TimeInterval = 30

    /// Fraction of `duration` that must be played.
    public static let minimumFraction = 0.50

    /// Absolute play time that always qualifies (long tracks).
    public static let minimumAbsoluteSeconds: TimeInterval = 240

    /// Returns `true` if the play meets the eligibility threshold.
    ///
    /// - Parameters:
    ///   - elapsed: Wall-clock seconds the user actually heard (paused time excluded).
    ///   - duration: Track duration in seconds.
    public static func isEligible(elapsed: TimeInterval, duration: TimeInterval) -> Bool {
        guard duration >= self.minimumDuration else { return false }
        if elapsed >= self.minimumAbsoluteSeconds { return true }
        guard duration > 0 else { return false }
        return (elapsed / duration) >= self.minimumFraction
    }

    /// Returns `true` if `playedAt` is within Last.fm's accepted backdate window.
    /// Last.fm rejects timestamps more than 14 days in the past or 1 day in the future.
    public static func isWithinBackdateWindow(_ playedAt: Date, now: Date = Date()) -> Bool {
        let delta = now.timeIntervalSince(playedAt)
        return delta >= -86400 && delta <= 14 * 86400
    }
}

// MARK: - PlayAccumulator

/// Tracks how long the user has *actually heard* a single track,
/// excluding time spent paused. Reset for each new track.
///
/// The accumulator is driven by external state callbacks rather than a
/// timer of its own — that keeps it deterministic and testable.
public struct PlayAccumulator: Sendable, Equatable {
    /// Total elapsed *playing* time, in seconds.
    public private(set) var elapsed: TimeInterval

    /// `true` while playback is active and the clock should advance.
    public private(set) var isPlaying: Bool

    /// Last instant the elapsed counter was advanced.
    private var lastTick: Date?

    public init() {
        self.elapsed = 0
        self.isPlaying = false
        self.lastTick = nil
    }

    /// Mark the start of a new track. Resets all counters.
    public mutating func reset(at now: Date = Date()) {
        self.elapsed = 0
        self.isPlaying = true
        self.lastTick = now
    }

    /// Pause: stop accumulating elapsed time.
    public mutating func pause(at now: Date = Date()) {
        if self.isPlaying, let last = lastTick {
            self.elapsed += now.timeIntervalSince(last)
        }
        self.isPlaying = false
        self.lastTick = now
    }

    /// Resume after a pause.
    public mutating func resume(at now: Date = Date()) {
        self.isPlaying = true
        self.lastTick = now
    }

    /// Refresh `elapsed` to "now" without changing play state. Useful before reads.
    public mutating func tick(at now: Date = Date()) {
        if self.isPlaying, let last = lastTick {
            self.elapsed += now.timeIntervalSince(last)
            self.lastTick = now
        }
    }
}
