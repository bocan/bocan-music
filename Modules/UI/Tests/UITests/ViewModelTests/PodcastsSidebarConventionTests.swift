import Foundation
import Testing
@testable import UI

// MARK: - PodcastsSidebarConventionTests

/// Guards the structural facts of the Phase 21-7 Podcasts sidebar integration.
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
