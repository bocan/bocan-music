import Foundation

// MARK: - PlaybackRateLabel

/// Formats playback-rate values for display ("0.75×", "1×", "1.25×").
///
/// Three significant digits, so quarter rates (1.25, 1.75) and the
/// 0.05-step slider values (1.15) keep their final digit. The previous
/// per-site `%.2g` rounded to two digits and shipped wrong labels (1.25 as
/// "1.2×", 1.75 as "1.8×") across the Playback menu, the transport speed
/// popover, and both Settings speed controls; found by the ADR-081 menu
/// crawl. The numeral-plus-sign form is locale-neutral by design, matching
/// the previous format strings, so this stays out of the string catalog.
public enum PlaybackRateLabel {
    /// The display label for a rate ("1.25×").
    public static func string(for rate: Double) -> String {
        String(format: "%.3g×", rate)
    }

    /// The display label for a rate ("1.25×").
    public static func string(for rate: Float) -> String {
        self.string(for: Double(rate))
    }
}
