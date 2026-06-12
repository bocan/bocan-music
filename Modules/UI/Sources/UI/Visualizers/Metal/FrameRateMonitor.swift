import Foundation

// MARK: - FrameRateMonitor

/// Rolling frame-rate watchdog. Accumulates time spent below an FPS floor and
/// signals exactly once when the slow stretch has lasted long enough to warrant
/// simplifying the visualizer.
///
/// A pure value type on purpose: it is driven from a per-frame callback, and the
/// Metal path must not measure frame rate by mutating SwiftUI `@State` every
/// frame. Doing so forces a `body` re-evaluation (and an IOKit power query via
/// `effectiveFPS`) per frame, an update storm that starves the very draw loop it
/// is timing and makes the watchdog fire against a renderer that is actually
/// fast. Measuring here keeps it off the SwiftUI update cycle entirely.
struct FrameRateMonitor {
    /// Frames slower than this (FPS) count toward the slow accumulator.
    static let fpsFloor = 30.0
    /// Sustained slow time (seconds) before the monitor trips.
    static let sustainedSeconds = 3.0

    private var lastTime: TimeInterval?
    private var slowAccumulator: TimeInterval = 0
    private(set) var hasTripped = false

    /// Records a presented-frame timestamp (seconds). Returns `true` exactly
    /// once, on the frame where the sustained-slow threshold is first crossed.
    mutating func record(time: TimeInterval) -> Bool {
        defer { self.lastTime = time }
        guard let last = self.lastTime else { return false }
        let elapsed = time - last
        // Ignore outliers: the first tick after a resume, or an extreme stall.
        guard elapsed > 0, elapsed < 1.0 else {
            self.slowAccumulator = 0
            return false
        }
        guard 1.0 / elapsed < Self.fpsFloor else {
            self.slowAccumulator = 0
            return false
        }
        self.slowAccumulator += elapsed
        if self.slowAccumulator >= Self.sustainedSeconds, !self.hasTripped {
            self.hasTripped = true
            return true
        }
        return false
    }
}
