import os

/// Lightweight telemetry helpers backed by `OSSignposter` for Instruments integration.
///
/// In production these emit signpost events visible in Instruments.
/// In tests, use `Telemetry.noop` to avoid side-effects.
public enum Telemetry {
    // MARK: - Signposter

    private static let signposter = OSSignposter(
        subsystem: "io.cloudcauldron.bocan",
        category: "Telemetry"
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
