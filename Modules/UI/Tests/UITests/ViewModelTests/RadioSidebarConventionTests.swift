import Foundation
import Testing
@testable import UI

// MARK: - RadioSidebarConventionTests

/// Guards the structural facts of the phase 27-3 Radio sidebar integration.
/// These are source-convention tests: they read the view source files directly
/// and assert that the required wiring is present, since the view internals
/// cannot be exercised host-less.
@Suite("Radio Sidebar Convention")
struct RadioSidebarConventionTests {
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

    @Test("Sidebar has a Radio row under Local Library")
    func sidebarHasRadioRow() throws {
        let sidebar = try self.source("AppRoot/Sidebar.swift")
        #expect(
            sidebar.contains(".radio"),
            "Sidebar must include a .radio destination row"
        )
        #expect(
            sidebar.contains("dot.radiowaves.left.and.right"),
            "Radio row must use the dot-radiowaves SF Symbol (Podcasts owns the antenna)"
        )
    }

    // MARK: - ContentPane

    @Test("ContentPane routes .radio to RadioView")
    func contentPaneRoutesRadio() throws {
        let pane = try self.source("AppRoot/ContentPane.swift")
        #expect(
            pane.contains("case .radio:"),
            "ContentPane must handle the .radio destination"
        )
        #expect(
            pane.contains("RadioView"),
            "ContentPane must route .radio to RadioView"
        )
    }

    // MARK: - SidebarDestination

    @Test("SidebarDestination declares the .radio case")
    func sidebarDestinationHasRadioCase() throws {
        let dest = try self.source("SidebarDestination.swift")
        #expect(
            dest.contains("case radio"),
            "SidebarDestination must declare a .radio case"
        )
    }

    // MARK: - Titles and navigation

    @Test("SmartFolders maps .radio to a localized window title")
    func smartFoldersTitlesRadio() throws {
        let folders = try self.source("Browse/SmartFolders.swift")
        #expect(
            folders.contains("case .radio:"),
            "SmartFolders title switch must cover .radio"
        )
    }

    @Test("loadDestination treats .radio as self-loading")
    func navigationTreatsRadioAsSelfLoading() throws {
        let nav = try self.source("ViewModels/LibraryViewModel+Navigation.swift")
        #expect(
            nav.contains(".radio"),
            "loadDestination must include .radio in its self-loading arm"
        )
    }

    // MARK: - Now Playing strip (phase 27-5)

    @Test("the strip's info button presents the station sheet for radio")
    func stripInfoButtonHandlesRadio() throws {
        let controls = try self.source("Transport/MusicTransportControls.swift")
        #expect(
            controls.contains("nowPlayingRadioStreamURL"),
            "MusicTransportControls must branch on the radio stream URL"
        )
        #expect(
            controls.contains("RadioStationInfoSheet"),
            "the info button must present the station sheet in radio mode"
        )
    }

    @Test("NowPlayingViewModel captures radio identity and live titles")
    func viewModelCapturesRadioIdentity() throws {
        let vmSource = try self.source("ViewModels/NowPlayingViewModel.swift")
        #expect(
            vmSource.contains("nowPlayingRadioStreamURL"),
            "the VM must expose the playing station's stream URL"
        )
        #expect(
            vmSource.contains("streamTitleUpdates"),
            "the VM must observe live ICY titles"
        )
    }
}
