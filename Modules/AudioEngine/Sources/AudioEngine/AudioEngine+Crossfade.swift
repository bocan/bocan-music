import Foundation

/// Crossfade volume-ramp helpers used by `QueuePlayer` when `CrossfadeScheduler`
/// determines a gapless boundary should have an audible fade transition.
///
/// Both methods fire a background `Task` and return immediately so they do not
/// block the caller.  The tasks reference `graph.playerNode` through the actor,
/// which is safe under `@preconcurrency`.  Any in-flight ramp is cancelled by
/// `load()` and `stop()` so it cannot race a freshly-started track.
public extension AudioEngine {
    // MARK: - Cancel

    /// Cancel any in-flight crossfade ramp and restore the player-node volume to 1
    /// so subsequent anti-pop fades in `load()` and `stop()` start from a known state.
    func cancelCrossfade() {
        self.crossfadeTask?.cancel()
        self.crossfadeTask = nil
        self.graph.playerNode.volume = 1.0
    }

    // MARK: - Crossfade fade-out

    /// Ramp the player-node volume from its current level to 0 over `durationSeconds`.
    ///
    /// Uses ~30 Hz update rate for a smooth, perceptually transparent ramp.
    /// Fire-and-forget: returns immediately; the ramp runs in a background `Task`.
    func beginCrossfadeOut(durationSeconds: TimeInterval) {
        self.crossfadeTask?.cancel()
        let steps = max(1, Int(durationSeconds * 30))
        let interval = durationSeconds / Double(steps)
        let log = self.log
        self.crossfadeTask = Task { [weak self] in
            log.debug("crossfade.out.start", ["durationSeconds": durationSeconds, "steps": steps])
            for step in 0 ..< steps {
                guard !Task.isCancelled, let self else { break }
                let t = Double(step + 1) / Double(steps)
                self.graph.playerNode.volume = Float(1.0 - t)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
            if !Task.isCancelled, let self {
                self.graph.playerNode.volume = 0
            }
            log.debug("crossfade.out.end")
        }
    }

    // MARK: - Crossfade fade-in

    /// Set the player-node volume to 0, then ramp it to 1 over `durationSeconds`.
    ///
    /// Call this immediately after a gapless transition fires to reveal the incoming
    /// track from silence.  Fire-and-forget: returns immediately.
    func beginCrossfadeIn(durationSeconds: TimeInterval) {
        self.crossfadeTask?.cancel()
        let steps = max(1, Int(durationSeconds * 30))
        let interval = durationSeconds / Double(steps)
        let log = self.log
        self.crossfadeTask = Task { [weak self] in
            log.debug("crossfade.in.start", ["durationSeconds": durationSeconds, "steps": steps])
            if let self { self.graph.playerNode.volume = 0 }
            for step in 0 ..< steps {
                guard !Task.isCancelled, let self else { break }
                let t = Double(step + 1) / Double(steps)
                self.graph.playerNode.volume = Float(t)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
            if !Task.isCancelled, let self {
                self.graph.playerNode.volume = 1.0
            }
            log.debug("crossfade.in.end")
        }
    }
}
