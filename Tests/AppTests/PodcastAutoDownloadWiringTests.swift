import Foundation
import Testing

// MARK: - PodcastAutoDownloadWiringTests

/// Guards that the App composition root wires podcast auto-download. The graph is
/// built in a non-async `buildGraph` and the policy lives in the `Podcasts` module,
/// so this pins the source contract: `BocanApp` registers the new-episodes observer
/// on `PodcastService` and feeds it through `AutoDownloadCoordinator`, reading the
/// `podcasts.autoDownloadCount` preference. Without this wiring the per-show
/// auto-download toggle is inert.
@Suite("Podcast auto-download wiring")
struct PodcastAutoDownloadWiringTests {
    private func bocanAppSource() throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // AppTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("App/BocanApp.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("BocanApp registers the new-episodes observer on PodcastService")
    func registersObserver() throws {
        let source = try self.bocanAppSource()
        #expect(source.contains("setNewEpisodesObserver"))
    }

    @Test("BocanApp drives auto-download through AutoDownloadCoordinator")
    func usesCoordinator() throws {
        let source = try self.bocanAppSource()
        #expect(source.contains("AutoDownloadCoordinator("))
        #expect(source.contains("handleRefresh"))
    }

    @Test("Auto-download count comes from the podcasts.autoDownloadCount preference")
    func readsCountPreference() throws {
        let source = try self.bocanAppSource()
        #expect(source.contains("podcasts.autoDownloadCount"))
    }
}
