import Foundation

/// Module-wide podcast playback constants.
///
/// Keep all episode-progress thresholds here so `PodcastService` (resume logic),
/// the player (ADR-042 position write-back), and the episode list indicator
/// (ADR-046) all agree on the same values without duplication.
public enum PodcastPlayback {
    /// Seconds from the end of an episode at which it is considered effectively
    /// complete. An episode with `position >= duration - completionTailSeconds`
    /// returns a resume position of 0 (start over) and is auto-marked played.
    public static let completionTailSeconds: TimeInterval = 15
}
