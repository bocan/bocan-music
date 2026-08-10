import Testing
@testable import UI

// MARK: - PlaybackRateLabelTests

/// Regression: `%.2g` displayed 1.25× as "1.2×" (the Playback ▸ Playback
/// Speed menu item set a rate its own label misstated) and 1.75× as
/// "1.8×" in Podcast settings. Three significant digits keep every rate
/// the app can actually set labelled exactly.
@Suite("Playback rate labels")
struct PlaybackRateLabelTests {
    @Test(
        "every quick rate is labelled exactly",
        arguments: [
            (Float(0.75), "0.75×"),
            (Float(1.0), "1×"),
            (Float(1.25), "1.25×"),
            (Float(1.5), "1.5×"),
            (Float(2.0), "2×"),
        ]
    )
    func quickRates(rate: Float, expected: String) {
        #expect(PlaybackRateLabel.string(for: rate) == expected)
    }

    @MainActor
    @Test("the menu covers the view model's quick rates")
    func menuQuickRatesRoundTrip() {
        // The Playback menu builds its items from this array; every value
        // must survive formatting without losing a digit.
        for rate in NowPlayingViewModel.quickRates {
            let label = PlaybackRateLabel.string(for: rate)
            #expect(Float(label.dropLast()) == rate, "\(rate) rendered as \(label)")
        }
    }

    @Test(
        "podcast preset and slider-step rates keep their final digit",
        arguments: [
            (0.8, "0.8×"),
            (1.25, "1.25×"),
            (1.75, "1.75×"),
            (1.15, "1.15×"),
            (1.05, "1.05×"),
            (0.5, "0.5×"),
        ]
    )
    func doubleRates(rate: Double, expected: String) {
        #expect(PlaybackRateLabel.string(for: rate) == expected)
    }
}
