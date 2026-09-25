import AudioEngine
import Foundation
import Observability

// MARK: - CrossfadeScheduler

/// Decides which track boundaries crossfade, and for how long (ADR-013,
/// ADR-095).
///
/// The crossfade itself is mixed inside the engine's buffer pump: the next
/// track fades in while the current one fades out, on the one player node.
/// This actor holds the user's setting and answers, per boundary, whether it
/// crossfades; `QueuePlayer` arms the overlap through
/// `AudioEngine.enableCrossfadeNext`.
///
/// **When `durationSeconds = 0`:** no boundary crossfades, and every boundary
/// takes ADR-006's plain gapless path.
///
/// **`albumGapless = true`:** tracks from the same album stay gapless; only a
/// boundary between albums crossfades.
public actor CrossfadeScheduler {
    // MARK: - Configuration

    public struct Config: Sendable {
        /// Crossfade duration in seconds (0 = disabled).
        public var durationSeconds: Double = 0
        /// When `true`, tracks from the same album keep the gapless path even if crossfade > 0.
        public var albumGapless = true

        public init(durationSeconds: Double = 0, albumGapless: Bool = true) {
            self.durationSeconds = durationSeconds
            self.albumGapless = albumGapless
        }
    }

    // MARK: - State

    /// The configuration in effect.
    public private(set) var config = Config()
    private let log = AppLogger.make(.playback)

    // MARK: - Init

    public init() {}

    // MARK: - Public API

    /// Update the crossfade configuration.
    public func setConfig(_ config: Config) {
        self.config = config
        self.log.debug("crossfade.config", [
            "durationSeconds": config.durationSeconds,
            "albumGapless": config.albumGapless,
        ])
    }

    /// Returns `true` when the setting and the album rule allow a crossfade
    /// between two consecutive tracks.
    ///
    /// - Parameters:
    ///   - currentAlbumID: Album ID of the outgoing track (`nil` = unknown).
    ///   - nextAlbumID:    Album ID of the incoming track (`nil` = unknown).
    public func crossfadeAllowed(
        currentAlbumID: Int64?,
        nextAlbumID: Int64?
    ) -> Bool {
        Self.crossfadeAllowed(self.config, currentAlbumID: currentAlbumID, nextAlbumID: nextAlbumID)
    }

    /// The crossfade setting to arm at the boundary from `current` to `next`,
    /// or `nil` when the boundary follows the plain gapless rules instead.
    public func crossfadeSeconds(from current: QueueItem?, to next: QueueItem) -> TimeInterval? {
        Self.crossfadeSeconds(self.config, from: current, to: next)
    }

    /// The full crossfade setting in seconds; 0 when crossfade is off. The
    /// engine shortens it at a boundary where a track is too short for it.
    public var overlapSeconds: TimeInterval {
        self.config.durationSeconds
    }

    public var isEnabled: Bool {
        self.config.durationSeconds > 0
    }

    // MARK: - Decisions

    static func crossfadeAllowed(_ config: Config, currentAlbumID: Int64?, nextAlbumID: Int64?) -> Bool {
        guard config.durationSeconds > 0 else { return false }
        if config.albumGapless,
           let cur = currentAlbumID, let nxt = nextAlbumID, cur == nxt {
            // Same album: use sample-accurate gapless instead.
            return false
        }
        return true
    }

    /// ADR-095, "Which boundaries crossfade": both items are local files, the
    /// setting and the album rule allow it, and the two queue durations leave
    /// an overlap of at least `CrossfadeMix.minimumOverlapSeconds`.
    ///
    /// Returns the full setting, not the overlap: the engine works the overlap
    /// out again from the decoders' own durations. The length check is here
    /// too so that a boundary too short to mix keeps the gapless rules (the
    /// format gate and the cross-album toggle), which the crossfade path
    /// skips.
    static func crossfadeSeconds(_ config: Config, from current: QueueItem?, to next: QueueItem) -> TimeInterval? {
        guard let current,
              !current.playableSource.isRemote,
              !next.playableSource.isRemote,
              crossfadeAllowed(config, currentAlbumID: current.albumID, nextAlbumID: next.albumID),
              CrossfadeMix.overlapSeconds(
                  setting: config.durationSeconds,
                  outgoing: current.duration,
                  incoming: next.duration
              ) != nil else {
            return nil
        }
        return config.durationSeconds
    }
}
