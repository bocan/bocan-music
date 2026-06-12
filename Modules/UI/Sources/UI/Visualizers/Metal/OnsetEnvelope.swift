import Foundation

// MARK: - OnsetEnvelope

/// A normalised 0...1 envelope that jumps to 1.0 on a newly-seen onset and
/// decays exponentially. Re-triggering resets to 1.0 (clamped, no stacking).
///
/// The `frameIndex` edge-detection lives here once: rendering at up to 60 Hz
/// against ~43 Hz analysis means the same onset-flagged `Analysis` is seen by
/// more than one render, and each onset must fire exactly once. Both Starfield's
/// warp kick and Nebula's pressure wave are this envelope with different `tau`.
struct OnsetEnvelope {
    /// Decay time constant in seconds. After one `tau`, an undisturbed envelope
    /// has fallen to `1/e` of its peak.
    let tau: TimeInterval

    /// Current envelope value, 0...1.
    private(set) var value: Double = 0

    private var lastFrameIndex: UInt64 = 0
    private var lastTime: TimeInterval?

    /// Frame-to-frame `dt` is clamped so a pause/resume gap cannot zero the
    /// envelope in a single step; in steady state `dt` is well under this.
    private static let maxDeltaTime: TimeInterval = 0.1

    init(tau: TimeInterval) {
        self.tau = tau
    }

    /// Call once per render. Decays by `exp(-dt / tau)` (with `dt` clamped), then
    /// re-arms to 1.0 if this is a new analysis frame carrying an onset.
    mutating func update(analysis: Analysis, time: TimeInterval) {
        let dt = self.lastTime.map { min(max(0, time - $0), Self.maxDeltaTime) } ?? 0
        self.lastTime = time
        self.value *= exp(-dt / self.tau)
        if analysis.frameIndex != self.lastFrameIndex {
            self.lastFrameIndex = analysis.frameIndex
            if analysis.onset {
                self.value = 1.0
            }
        }
    }
}
