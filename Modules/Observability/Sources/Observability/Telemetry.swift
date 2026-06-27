import os

/// Lightweight telemetry helpers backed by `OSSignposter` for Instruments integration.
///
/// In production these emit signpost events visible in Instruments.
/// In tests, use `Telemetry.noop` to avoid side-effects.
public enum Telemetry {
    // MARK: - Signposter

    /// Emit to the Points of Interest log. A custom signpost category is not
    /// enabled by the default os_signpost recording configuration, so
    /// beginInterval/emitEvent would silently no-op; the Points of Interest log
    /// is always enabled while Instruments (or `xctrace --instrument
    /// 'Points of Interest'`) is recording, so our spans reliably appear.
    private static let signposter = OSSignposter(
        logHandle: OSLog(subsystem: "io.cloudcauldron.bocan", category: .pointsOfInterest)
    )

    // MARK: - Counter

    /// Emit a signpost marking a discrete count event.
    public static func counter(
        _ name: StaticString,
        by amount: Int = 1,
        tags: [String: String] = [:]
    ) {
        let id = self.signposter.makeSignpostID()
        self.signposter.emitEvent(name, id: id, "\(name): +\(amount)")
    }

    // MARK: - Timer

    /// Begin a timed interval and return a closure that ends it.
    ///
    /// ```swift
    /// let end = Telemetry.timer("scan.duration")
    /// defer { end() }
    /// ```
    @discardableResult
    public static func timer(
        _ name: StaticString,
        tags: [String: String] = [:]
    ) -> @Sendable () -> Void {
        let id = self.signposter.makeSignpostID()
        let state = self.signposter.beginInterval(name, id: id)
        return {
            self.signposter.endInterval(name, state)
        }
    }
}
