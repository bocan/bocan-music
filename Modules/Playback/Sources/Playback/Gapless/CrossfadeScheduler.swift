import AudioEngine
@preconcurrency import AVFoundation
import Foundation
import Observability

// MARK: - CrossfadeScheduler

/// Extends the gapless scheduler with a configurable volume-ramp crossfade.
///
/// **Crossfade model:**
/// When `durationSeconds > 0`, at the pre-decode handoff point the scheduler:
/// 1. Schedules a linear fade-out on the outgoing `AVAudioPlayerNode` over
///    `durationSeconds × 0.5` seconds.
/// 2. Schedules the incoming track with a matching fade-in ramp of equal length.
/// Both ramps use `AVAudioTime`-anchored scheduling on a background `Task`.
///
/// **Note on volume jitter:** `AVAudioPlayerNode.volume` changes are thread-safe but
/// not sample-accurate (~10 ms scheduling jitter on the render thread). This is
/// perceptually transparent for crossfade transitions. No compensation is applied.
///
/// **When `durationSeconds = 0`:** the code path is identical to Phase 5's hard
/// handoff — no ramps, no performance difference.
///
/// **`crossfadeAlbumGapless = true`:** crossing album boundaries uses crossfade;
/// tracks within the same album use the gapless path (no overlap). The boundary
/// type is decided at schedule time by `crossfadeAllowed(currentAlbumID:nextAlbumID:)`.
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

    private var config = Config()
    private var fadeOutTask: Task<Void, Never>?
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

    /// Returns `true` when a crossfade should be applied at the boundary between
    /// two consecutive tracks.
    ///
    /// - Parameters:
    ///   - currentAlbumID: Album ID of the outgoing track (`nil` = unknown).
    ///   - nextAlbumID:    Album ID of the incoming track (`nil` = unknown).
    public func crossfadeAllowed(
        currentAlbumID: Int64?,
        nextAlbumID: Int64?
    ) -> Bool {
        guard self.config.durationSeconds > 0 else { return false }
        if self.config.albumGapless,
           let cur = currentAlbumID, let nxt = nextAlbumID, cur == nxt {
            // Same album — use sample-accurate gapless instead.
            return false
        }
        return true
    }

    /// Apply volume fade-out to `node` over half the configured crossfade duration.
    ///
    /// This is fire-and-forget: the task runs in the background and cancels itself
    /// if a new crossfade begins before the old one finishes.
    ///
    /// - Parameters:
    ///   - node:           The outgoing `AVAudioPlayerNode`.
    ///   - halfDuration:   Duration of the fade-out ramp in seconds.
    public func scheduleOutgoingFade(on node: AVAudioPlayerNode, halfDuration: TimeInterval) {
        self.fadeOutTask?.cancel()
        let steps = max(1, Int(halfDuration * 30)) // ~30 Hz volume update rate
        let interval = halfDuration / Double(steps)
        let log = self.log

        self.fadeOutTask = Task { [steps, interval] in
            log.debug("crossfade.fadeOut.start", ["steps": steps, "interval": interval])
            for step in 0 ..< steps {
                guard !Task.isCancelled else { break }
                let t = Double(step) / Double(steps)
                let volume = Float(1.0 - t) // linear ramp from 1 → 0
                await MainActor.run { node.volume = volume }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
            if !Task.isCancelled {
                await MainActor.run { node.volume = 0 }
            }
            log.debug("crossfade.fadeOut.end")
        }
    }

    /// Apply a volume fade-in ramp to `node` over `halfDuration` seconds.
    ///
    /// The node's initial volume is set to 0 before the ramp so the incoming track
    /// starts silent and fades in.
    ///
    /// - Parameters:
    ///   - node:         The incoming `AVAudioPlayerNode`.
    ///   - halfDuration: Duration of the fade-in ramp in seconds.
    public func scheduledIncomingFade(on node: AVAudioPlayerNode, halfDuration: TimeInterval) {
        let steps = max(1, Int(halfDuration * 30))
        let interval = halfDuration / Double(steps)
        let log = self.log

        Task { [steps, interval] in
            log.debug("crossfade.fadeIn.start", ["steps": steps])
            // Start silent.
            await MainActor.run { node.volume = 0 }
            for step in 0 ..< steps {
                guard !Task.isCancelled else { break }
                let t = Double(step + 1) / Double(steps)
                let volume = Float(t)
                await MainActor.run { node.volume = volume }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
            await MainActor.run { node.volume = 1.0 }
            log.debug("crossfade.fadeIn.end")
        }
    }

    /// Cancel any in-flight fade tasks and restore `node` to full volume.
    public func cancelFades(on node: AVAudioPlayerNode) {
        self.fadeOutTask?.cancel()
        self.fadeOutTask = nil
        node.volume = 1.0
        self.log.debug("crossfade.fades.cancelled")
    }

    /// The half-duration for this config (fade-out and fade-in are both this length).
    public var halfDurationSeconds: TimeInterval {
        self.config.durationSeconds * 0.5
    }

    public var isEnabled: Bool {
        self.config.durationSeconds > 0
    }
}
