import Foundation
import Testing

// MARK: - PodcastSettingsWiringTests

/// Guards that the App composition root passes the Settings > Podcasts choices
/// on (#605). The meaning of each value is tested in the `Podcasts` module
/// (`PodcastSettingsTests`, `FeedRefreshSchedulerTests`); this pins the source
/// contract that the scheduler and the search adapter are given them at all.
/// Without this wiring the refresh interval, "Refresh on launch" and the
/// storefront country are saved and read by nothing.
@Suite("Podcast settings wiring")
struct PodcastSettingsWiringTests {
    private func appSource(_ file: String) throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // AppTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("App/\(file)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("The feed refresh scheduler is built from the stored settings")
    func schedulerTakesSettings() throws {
        let source = try self.appSource("BocanApp.swift")
        #expect(source.contains("settings: PodcastSettings(defaults: .standard)"))
    }

    @Test("The scheduler follows settings changes while the app runs")
    func schedulerFollowsChanges() throws {
        let source = try self.appSource("BocanApp.swift")
        #expect(source.contains("PodcastSettings.changes(in: .standard)"))
        #expect(source.contains("await feedRefreshScheduler.apply(settings)"))
    }

    @Test("Search and detail lookups carry the storefront country")
    func searchCarriesStorefront() throws {
        let source = try self.appSource("AppPodcastSearch.swift")
        #expect(source.contains("search(term: term, country: country)"))
        #expect(source.contains("detail(for: Self.unmap(hint), country: country)"))
        #expect(source.contains("PodcastSettings(defaults: .standard).storefront"))
    }
}
