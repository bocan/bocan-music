import AppKit
import Foundation
import Persistence
import SwiftUI
import Testing
@testable import UI

// MARK: - VoiceOverTests

/// Verifies VoiceOver accessibility support added in Phase 1.
///
/// Tests cover:
///  - `TrackTableCoordinator.tableView(_:accessibilityLabelForRow:)` label format
///  - Source-convention checks that key a11y modifiers exist in UI source files
@Suite("VoiceOver Accessibility")
struct VoiceOverTests {
    // MARK: - Helpers

    /// Root of the UI package Sources directory.
    private var uiSourcesURL: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI")
    }

    private func sourceContents(at relativePath: String) throws -> String {
        let url = self.uiSourcesURL.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Returns a `TrackContextMenuActions` with all handlers set to no-ops.
    /// Shared by tests that need a valid `TrackTable` parent but don't exercise actions.
    private func makeNoopActions() -> TrackContextMenuActions {
        let noop: (Track) -> Void = { _ in }
        return TrackContextMenuActions(
            playNow: noop,
            playSingle: noop,
            playAlbum: noop,
            shuffleAlbum: noop,
            playArtist: noop,
            playNext: { _ in },
            addToQueue: { _ in },
            addToPlaylist: { _, _ in },
            newPlaylistFromSelection: { _ in },
            love: { _ in },
            goToArtist: { _ in },
            goToAlbum: { _ in },
            showInFinder: noop,
            rescanFile: noop,
            getInfo: { _ in },
            identify: noop,
            removeFromLibrary: { _ in },
            deleteFromDisk: { _ in },
            copy: { _ in },
            toggleShuffle: { _, _ in },
            computeReplayGain: { _ in },
            rate: { _, _ in },
            removeFromPlaylist: nil,
            editLyrics: nil,
            fetchLyricsFromLRClib: nil
        )
    }

    // MARK: - TrackTableCoordinator

    @MainActor
    @Test("accessibilityLabelForRow returns Title, Artist, Album, Duration")
    func trackRowAccessibilityLabel() {
        let now = Int64(Date().timeIntervalSince1970)
        let track = Track(
            fileURL: "file:///tmp/inMyLife.mp3",
            fileSize: 0,
            fileMtime: now,
            fileFormat: "mp3",
            duration: 167.0, // 2:47
            title: "In My Life",
            addedAt: now,
            updatedAt: now
        )
        let row = TrackRow(track: track, artistName: "The Beatles", albumName: "Rubber Soul")

        var selectionStub = Set<Track.ID>()
        var sortStub = [KeyPathComparator<TrackRow>]()
        let table = TrackTable(
            rows: [],
            selection: Binding(get: { selectionStub }, set: { selectionStub = $0 }),
            sortOrder: Binding(get: { sortStub }, set: { sortStub = $0 }),
            nowPlayingTrackID: nil,
            sortable: false,
            playlistNodes: [],
            actions: self.makeNoopActions(),
            scrollRequest: 0,
            onMove: nil
        )
        let coordinator = TrackTableCoordinator(parent: table)
        coordinator.rows = [row]

        let tv = NSTableView()
        let label = coordinator.tableView(tv, accessibilityLabelForRow: 0)
        #expect(label == "In My Life, The Beatles, Rubber Soul, 2:47")
    }

    @MainActor
    @Test("accessibilityLabelForRow prefixes 'Now playing, ' for the current track (#300)")
    func trackRowAccessibilityLabelNowPlaying() {
        let now = Int64(Date().timeIntervalSince1970)
        let track = Track(
            fileURL: "file:///tmp/inMyLife.mp3",
            fileSize: 0,
            fileMtime: now,
            fileFormat: "mp3",
            duration: 167.0,
            title: "In My Life",
            addedAt: now,
            updatedAt: now
        )
        let row = TrackRow(track: track, artistName: "The Beatles", albumName: "Rubber Soul")
        let trackID = row.id

        var selectionStub = Set<Track.ID>()
        var sortStub = [KeyPathComparator<TrackRow>]()
        let table = TrackTable(
            rows: [],
            selection: Binding(get: { selectionStub }, set: { selectionStub = $0 }),
            sortOrder: Binding(get: { sortStub }, set: { sortStub = $0 }),
            nowPlayingTrackID: trackID,
            sortable: false,
            playlistNodes: [],
            actions: self.makeNoopActions(),
            scrollRequest: 0,
            onMove: nil
        )
        let coordinator = TrackTableCoordinator(parent: table)
        coordinator.rows = [row]

        let tv = NSTableView()
        let label = coordinator.tableView(tv, accessibilityLabelForRow: 0)
        #expect(
            label?.hasPrefix("Now playing, ") == true,
            "Row label for the now-playing track must begin with 'Now playing, '; got: \(label ?? "nil")"
        )
    }

    @MainActor
    @Test("accessibilityLabelForRow returns nil for out-of-bounds row")
    func trackRowAccessibilityLabelOutOfBounds() {
        var selectionStub = Set<Track.ID>()
        var sortStub = [KeyPathComparator<TrackRow>]()
        let table = TrackTable(
            rows: [],
            selection: Binding(get: { selectionStub }, set: { selectionStub = $0 }),
            sortOrder: Binding(get: { sortStub }, set: { sortStub = $0 }),
            nowPlayingTrackID: nil,
            sortable: false,
            playlistNodes: [],
            actions: self.makeNoopActions(),
            scrollRequest: 0,
            onMove: nil
        )
        let coordinator = TrackTableCoordinator(parent: table)
        // rows is empty — row 0 is out of bounds
        let tv = NSTableView()
        #expect(coordinator.tableView(tv, accessibilityLabelForRow: 0) == nil)
    }

    // MARK: - Source convention: album cell hints

    @Test("AlbumsGridView AlbumCell has accessibilityHint for opening album")
    func albumsGridViewHasOpenHint() throws {
        let source = try self.sourceContents(at: "Browse/AlbumsGridView.swift")
        // Copy may be wrapped in L10n.string(...) for localization (#314); match the text itself.
        #expect(
            source.contains("accessibilityHint(L10n.string(\"Double-tap to open album\"))")
                || source.contains("accessibilityHint(\"Double-tap to open album\")"),
            "AlbumCell must declare the Double-tap to open album accessibility hint"
        )
    }

    @Test("ArtistsView album cell has accessibilityHint for opening album")
    func artistsViewAlbumCellHasOpenHint() throws {
        let source = try self.sourceContents(at: "Browse/ArtistsView.swift")
        #expect(
            source.contains("accessibilityHint(\"Double-tap to open album\")"),
            "ArtistsView album cell must declare accessibilityHint(\"Double-tap to open album\")"
        )
    }

    @Test("ArtistsView artist row uses .combine accessibility element")
    func artistsViewArtistRowUsesCombine() throws {
        let source = try self.sourceContents(at: "Browse/ArtistsView.swift")
        #expect(
            source.contains("accessibilityElement(children: .combine)"),
            "ArtistsView artist list rows must use .accessibilityElement(children: .combine)"
        )
    }

    // MARK: - Source convention: NowPlayingStrip

    @Test("NowPlayingStrip announces track changes to VoiceOver")
    func nowPlayingStripHasLiveAnnouncement() throws {
        let source = try self.sourceContents(at: "AppRoot/NowPlayingStrip.swift")
        #expect(
            source.contains("announcementRequested"),
            "NowPlayingStrip must post .announcementRequested on track change"
        )
    }

    @Test("NowPlayingStrip title has updatesFrequently trait")
    func nowPlayingStripTitleHasUpdatesFrequently() throws {
        let source = try self.sourceContents(at: "AppRoot/NowPlayingStrip.swift")
        #expect(
            source.contains(".updatesFrequently"),
            "NowPlayingStrip title button must carry .accessibilityAddTraits(.updatesFrequently)"
        )
    }

    @Test("NowPlayingStrip volume slider has accessibilityValue")
    func nowPlayingStripVolumeHasValue() throws {
        let source = try self.sourceContents(at: "AppRoot/NowPlayingStrip.swift")
        #expect(
            source.contains("percent"),
            "Volume slider must expose percentage as accessibilityValue"
        )
    }

    // MARK: - Source convention: EQ band sliders

    @Test("EQView band sliders use .1f dB format in accessibilityValue")
    func eqBandSliderAccessibilityValueFormat() throws {
        let source = try self.sourceContents(at: "DSP/EQView.swift")
        // Look for the BandSliderView's .1f format (not the .0f that was there before)
        #expect(
            source.contains("%+.1f dB"),
            "BandSliderView must use \"%+.1f dB\" format in accessibilityValue"
        )
    }

    // MARK: - Source convention: TrackTableCoordinator

    @Test("TrackTableCoordinator implements accessibilityLabelForRow delegate method")
    func coordinatorHasAccessibilityLabelForRow() throws {
        let source = try self.sourceContents(at: "Browse/TrackTableCoordinator.swift")
        #expect(
            source.contains("accessibilityLabelForRow"),
            "TrackTableCoordinator must implement tableView(_:accessibilityLabelForRow:)"
        )
    }

    // MARK: - Differentiate Without Color (#298)

    @Test("ActiveToggleIndicator reads accessibilityDifferentiateWithoutColor")
    func activeToggleIndicatorReadsDifferentiateWithoutColor() throws {
        let source = try self.sourceContents(at: "Theme/ActiveToggleIndicator.swift")
        #expect(
            source.contains("accessibilityDifferentiateWithoutColor"),
            "ActiveToggleIndicator must gate its shape affordance on accessibilityDifferentiateWithoutColor"
        )
    }

    @Test("NowPlayingStrip transport toggles apply activeToggleIndicator")
    func nowPlayingStripTogglesUseActiveIndicator() throws {
        let source = try self.sourceContents(at: "AppRoot/NowPlayingStrip.swift")
        #expect(
            source.contains("activeToggleIndicator"),
            "Shuffle/repeat/stop-after toggles must apply .activeToggleIndicator so on/off isn't colour-only"
        )
    }

    @Test("SubsonicStatusDot reads accessibilityDifferentiateWithoutColor")
    func subsonicStatusDotReadsDifferentiateWithoutColor() throws {
        let source = try self.sourceContents(at: "AppRoot/SubsonicSidebarSection.swift")
        #expect(
            source.contains("accessibilityDifferentiateWithoutColor"),
            "SubsonicStatusDot must render a per-status glyph when differentiate-without-colour is on"
        )
    }
}
