import Foundation
import Testing
@testable import UI

// MARK: - PodcastsSidebarConventionTests

/// Guards the structural facts of the ADR-044 Podcasts sidebar integration.
/// These are source-convention tests: they read the view source files directly
/// and assert that the required wiring is present, since the view internals
/// cannot be exercised host-less.
@Suite("Podcasts Sidebar Convention")
struct PodcastsSidebarConventionTests {
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

    // MARK: - Sidebar

    @Test("Sidebar has a Podcasts row under Local Library")
    func sidebarHasPodcastsRow() throws {
        let sidebar = try self.source("AppRoot/Sidebar.swift")
        #expect(
            sidebar.contains(".podcasts"),
            "Sidebar must include a .podcasts destination row"
        )
        #expect(
            sidebar.contains("antenna.radiowaves.left.and.right"),
            "Podcasts row must use the antenna SF Symbol"
        )
    }

    // MARK: - ContentPane

    @Test("ContentPane routes .podcasts to PodcastsHomeView")
    func contentPaneRoutesPodcasts() throws {
        let pane = try self.source("AppRoot/ContentPane.swift")
        #expect(
            pane.contains("case .podcasts:"),
            "ContentPane must handle the .podcasts destination"
        )
        #expect(
            pane.contains("PodcastsHomeView"),
            "ContentPane must route .podcasts to PodcastsHomeView"
        )
    }

    @Test("ContentPane routes .podcastShow to PodcastShowView")
    func contentPaneRoutesPodcastShow() throws {
        let pane = try self.source("AppRoot/ContentPane.swift")
        #expect(
            pane.contains("case let .podcastShow(id):"),
            "ContentPane must handle .podcastShow(id)"
        )
        #expect(
            pane.contains("PodcastShowView"),
            "ContentPane must route .podcastShow to PodcastShowView"
        )
    }

    @Test("Downloaded is the other side of a Podcasts toolbar switch, not a sidebar row (#651)")
    func downloadedSwitchWiring() throws {
        let pane = try self.source("AppRoot/ContentPane.swift")
        #expect(pane.contains("case .podcastDownloads:"), "ContentPane must route .podcastDownloads")
        #expect(pane.contains("mode: .downloaded"), "it must open the home view on its Downloaded side")

        let home = try self.source("Browse/Podcasts/PodcastsHomeView.swift")
        #expect(home.contains(".pickerStyle(.segmented)"), "the switch is a segmented control")
        #expect(
            home.contains("Label(L10n.string(\"Shows\"), systemImage:")
                && home.contains("Label(L10n.string(\"Downloaded\"), systemImage:"),
            "each segment needs an icon, or the overflow menu's palette draws it blank"
        )
        #expect(home.contains("ToolbarItem(placement: .principal)"), "it lives in the toolbar, costing no content space")
        #expect(
            home.contains("selectDestination(newMode == .shows ? .podcasts : .podcastDownloads)"),
            "each side is a destination, so Back undoes a switch"
        )
        #expect(home.contains("DownloadedEpisodesView("), "the Downloaded side shows the downloads list")

        let sidebar = try self.source("AppRoot/Sidebar.swift")
        #expect(
            sidebar.contains("self.vm.selectedDestination == .podcastDownloads ? .podcasts"),
            "the Podcasts sidebar row stays lit on the Downloaded side"
        )

        let list = try self.source("Browse/Podcasts/DownloadedEpisodesView.swift")
        #expect(
            list.contains(".task { await self.vm.observeDownloaded() }"),
            "the downloads observation must end when the list leaves the screen"
        )
        #expect(
            list.contains("sortOrder: self.sortOrder"),
            "the column headings sort the list, and the stored sort survives a relaunch"
        )
    }

    // MARK: - SidebarDestination

    @Test("SidebarDestination declares .podcasts and .podcastShow cases")
    func sidebarDestinationHasPodcastCases() throws {
        let dest = try self.source("SidebarDestination.swift")
        #expect(
            dest.contains("case podcasts"),
            "SidebarDestination must declare a .podcasts case"
        )
        #expect(
            dest.contains("case podcastShow(Int64)"),
            "SidebarDestination must declare a .podcastShow(Int64) case"
        )
    }

    // MARK: - Seams

    @Test("UI module does not import Podcasts (seam purity)")
    func noImportPodcastsInUI() throws {
        let seams = try self.source("Browse/Podcasts/PodcastSeams.swift")
        #expect(
            !seams.contains("import Podcasts"),
            "PodcastSeams.swift must not import the Podcasts module"
        )
    }

    @Test("PodcastSeams declares PodcastLibraryDataSource and PodcastActions")
    func seamsDeclaresProtocols() throws {
        let seams = try self.source("Browse/Podcasts/PodcastSeams.swift")
        #expect(
            seams.contains("protocol PodcastLibraryDataSource"),
            "PodcastSeams must declare PodcastLibraryDataSource"
        )
        #expect(
            seams.contains("protocol PodcastActions"),
            "PodcastSeams must declare PodcastActions"
        )
    }
}
