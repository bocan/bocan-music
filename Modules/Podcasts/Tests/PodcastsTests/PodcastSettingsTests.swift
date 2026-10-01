import Foundation
import Testing
@testable import Podcasts

/// The mapping from the raw values Settings > Podcasts stores to what the
/// scheduler and the search client act on (#605).
@Suite("PodcastSettings", .timeLimit(.minutes(1)))
struct PodcastSettingsTests {
    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "PodcastSettingsTests-\(UUID().uuidString)"
        return try (#require(UserDefaults(suiteName: suite)), suite)
    }

    @Test("Nothing stored gives the pane's defaults: 30 minutes, refresh on launch, US store")
    func defaultsWhenUnset() throws {
        let (defaults, suite) = try self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = PodcastSettings(defaults: defaults)
        #expect(settings.refreshInterval == 1800)
        #expect(settings.refreshOnLaunch)
        #expect(settings.storefront == "US")
        #expect(settings == PodcastSettings())
    }

    @Test("The stored minutes become the interval in seconds", arguments: [15, 30, 60])
    func intervalFollowsStoredMinutes(minutes: Int) throws {
        let (defaults, suite) = try self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(minutes, forKey: PodcastSettings.Key.refreshInterval)

        #expect(PodcastSettings(defaults: defaults).refreshInterval == TimeInterval(minutes * 60))
    }

    @Test("A stored 0 is Manual only: no interval")
    func zeroIsManualOnly() throws {
        let (defaults, suite) = try self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(0, forKey: PodcastSettings.Key.refreshInterval)

        #expect(PodcastSettings(defaults: defaults).refreshInterval == nil)
        #expect(PodcastSettings(refreshIntervalMinutes: -5).refreshInterval == nil)
    }

    @Test("Refresh on launch follows the stored toggle")
    func refreshOnLaunchFollowsToggle() throws {
        let (defaults, suite) = try self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: PodcastSettings.Key.refreshOnLaunch)

        #expect(!PodcastSettings(defaults: defaults).refreshOnLaunch)
    }

    @Test("The stored lower-case storefront becomes the upper-case country code")
    func storefrontFollowsStoredCountry() throws {
        let (defaults, suite) = try self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("gb", forKey: PodcastSettings.Key.storefront)

        #expect(PodcastSettings(defaults: defaults).storefront == "GB")
    }

    @Test("A storefront that is not a two-letter code falls back to the US store", arguments: ["", "gbr", "1x", "é!"])
    func malformedStorefrontFallsBack(raw: String) {
        #expect(PodcastSettings(storefront: raw).storefront == "US")
    }

    @Test("The stale gate is half the interval, and nothing in Manual only")
    func staleAgeFollowsInterval() {
        #expect(PodcastSettings(refreshIntervalMinutes: 15).staleAge == 450)
        #expect(PodcastSettings(refreshIntervalMinutes: 60).staleAge == 1800)
        #expect(PodcastSettings(refreshIntervalMinutes: 0).staleAge == 0)
    }

    @Test("The change stream emits a changed setting and ignores unrelated keys")
    func changesEmitOnlyRealChanges() async throws {
        let (defaults, suite) = try self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        var changes = PodcastSettings.changes(in: defaults).makeAsyncIterator()
        defaults.set(5, forKey: "podcasts.autoDownloadCount")
        defaults.set(30, forKey: PodcastSettings.Key.refreshInterval) // the default: no change
        defaults.set(0, forKey: PodcastSettings.Key.refreshInterval)

        // The first thing to arrive is the real change, not the two writes before it.
        let first = await changes.next()
        #expect(first == PodcastSettings(refreshIntervalMinutes: 0))
    }
}
