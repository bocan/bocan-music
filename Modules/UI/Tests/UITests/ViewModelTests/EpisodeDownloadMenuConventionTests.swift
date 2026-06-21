import Foundation
import Testing
@testable import UI

// MARK: - EpisodeDownloadMenuConventionTests

/// Source-convention guards for the podcast episode download menu. The `EpisodeList`
/// `Table` and its context menu cannot be exercised host-less, so we assert by
/// reading source that manual single-episode and bulk multi-selection downloads are
/// wired through the `PodcastActions` seam, and that the status cell reflects
/// download state.
@Suite("Episode Download Menu Convention")
struct EpisodeDownloadMenuConventionTests {
    private var uiSourcesURL: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI")
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: self.uiSourcesURL.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test("Episode context menu wires manual download and removal through the actions seam")
    func singleEpisodeActions() throws {
        let list = try self.source("Browse/Podcasts/EpisodeList.swift")
        #expect(list.contains("actions?.download(podcastID:"))
        #expect(list.contains("actions?.removeDownload(podcastID:"))
        #expect(list.contains("Download"))
        #expect(list.contains("Remove Download"))
        #expect(list.contains("Cancel Download"))
    }

    @Test("Episode context menu offers bulk download for a multi-row selection")
    func bulkSelectionActions() throws {
        let list = try self.source("Browse/Podcasts/EpisodeList.swift")
        #expect(list.contains("ids.count > 1"))
        #expect(list.contains("Download Selected"))
        #expect(list.contains("Remove Downloads"))
    }

    @Test("Status indicator badges downloaded and in-flight episodes")
    func statusBadge() throws {
        let indicator = try self.source("Browse/Podcasts/EpisodeStatusIndicator.swift")
        #expect(indicator.contains("downloadState"))
        #expect(indicator.contains("arrow.down.circle.fill"))
        #expect(indicator.contains("arrow.down.circle"))
    }

    @Test("Podcast settings surface the auto-download count preference")
    func settingsAutoDownloadCount() throws {
        let settings = try self.source("Settings/PodcastSettingsView.swift")
        #expect(settings.contains("autoDownloadCount"))
        #expect(settings.contains("$autoDownloadCount"))
        #expect(settings.contains("newest episode"))
    }
}
