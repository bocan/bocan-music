import Foundation

/// Controls which ReplayGain value is used during playback.
public enum ReplayGainMode: String, Sendable, Codable, CaseIterable, Hashable {
    /// No ReplayGain applied.
    case off
    /// Always apply track gain.
    case track
    /// Always apply album gain (falls back to track gain if album gain is absent).
    case album
    /// Album gain when playing a contiguous album span; track gain otherwise.
    case auto
}
