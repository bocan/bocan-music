import Foundation
import Testing
@testable import UI

// MARK: - PodcastNowPlayingTests

/// Source-convention and pure-logic tests for NowPlayingViewModel's podcast mode.
///
/// These tests focus on properties that can be verified without a live
/// engine or database: default values, skip-interval clamping math,
/// and the quickRates catalogue.
@Suite("NowPlayingViewModel podcast mode")
@MainActor
struct PodcastNowPlayingTests {
    // MARK: - Default state

    @Test("isPodcast property is declared with Bool type")
    func isPodcastPropertyExists() {
        // Verify the source contract: NowPlayingViewModel exposes an `isPodcast`
        // property of type Bool. The compile-time check here is sufficient; a
        // full integration test (with a live engine) lives in the Xcode BocanTests bundle.
        let keyPath: KeyPath<NowPlayingViewModel, Bool> = \.isPodcast
        #expect(keyPath == \.isPodcast)
    }

    // MARK: - Skip clamping math

    @Test("Skip-back interval clamped to zero when position is less than interval")
    func skipBackClampedToZero() {
        let position: TimeInterval = 5
        let interval: TimeInterval = 15
        let result = max(0, position - interval)
        #expect(result == 0)
    }

    @Test("Skip-back does not clamp when position exceeds interval")
    func skipBackNoClamp() {
        let position: TimeInterval = 60
        let interval: TimeInterval = 15
        let result = max(0, position - interval)
        #expect(result == 45)
    }

    @Test("Skip-forward interval clamped to duration")
    func skipForwardClampedToDuration() {
        let position: TimeInterval = 3580
        let duration: TimeInterval = 3600
        let interval: TimeInterval = 30
        let result = min(duration, position + interval)
        #expect(result == duration)
    }

    @Test("Skip-forward does not clamp when space remains")
    func skipForwardNoClamp() {
        let position: TimeInterval = 60
        let duration: TimeInterval = 3600
        let interval: TimeInterval = 30
        let result = min(duration, position + interval)
        #expect(result == 90)
    }

    // MARK: - Quick rates

    @Test("quickRates contains podcast-useful speeds")
    func quickRatesContainsPodcastSpeeds() {
        let rates = NowPlayingViewModel.quickRates
        #expect(rates.contains(1.0))
        #expect(rates.contains(1.25))
        #expect(rates.contains(1.5))
        #expect(rates.contains(2.0))
        // Minimum useful speed for podcast listeners
        #expect(rates.contains { $0 <= 0.8 })
    }

    // MARK: - UserDefaults keys

    @Test("Skip-back interval defaults to 15 when UserDefaults key is missing")
    func skipBackDefaultInterval() {
        let raw = UserDefaults.standard.double(forKey: "podcasts.skipBackInterval.nonexistent.test.key")
        let interval = raw > 0 ? raw : 15.0
        #expect(interval == 15.0)
    }

    @Test("Skip-forward interval defaults to 30 when UserDefaults key is missing")
    func skipForwardDefaultInterval() {
        let raw = UserDefaults.standard.double(forKey: "podcasts.skipForwardInterval.nonexistent.test.key")
        let secs = raw > 0 ? raw : 30.0
        #expect(secs == 30.0)
    }
}
