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

        // Build a minimal coordinator. The TrackTable parent is needed for init;
        // we only exercise the rows array — no SwiftUI rendering occurs.
        var selectionStub = Set<Track.ID>()
        var sortStub = [KeyPathComparator<TrackRow>]()
        let noopTrack: (Track) -> Void = { _ in }
        let actions = TrackContextMenuActions(
            playNow: noopTrack,
            playSingle: noopTrack,
            playAlbum: noopTrack,
            shuffleAlbum: noopTrack,
            playArtist: noopTrack,
            playNext: { _ in },
            addToQueue: { _ in },
            addToPlaylist: { _, _ in },
            newPlaylistFromSelection: { _ in },
            love: { _ in },
            goToArtist: { _ in },
            goToAlbum: { _ in },
            showInFinder: noopTrack,
            rescanFile: noopTrack,
            getInfo: { _ in },
            identify: noopTrack,
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
        let table = TrackTable(
            rows: [],
            selection: Binding(get: { selectionStub }, set: { selectionStub = $0 }),
            sortOrder: Binding(get: { sortStub }, set: { sortStub = $0 }),
            nowPlayingTrackID: nil,
            sortable: false,
            playlistNodes: [],
            actions: actions,
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
    @Test("accessibilityLabelForRow returns nil for out-of-bounds row")
    func trackRowAccessibilityLabelOutOfBounds() {
        var selectionStub = Set<Track.ID>()
        var sortStub = [KeyPathComparator<TrackRow>]()
        let noop: (Track) -> Void = { _ in }
        let actions = TrackContextMenuActions(
            playNow: noop, playSingle: noop, playAlbum: noop, shuffleAlbum: noop,
            playArtist: noop, playNext: { _ in }, addToQueue: { _ in },
            addToPlaylist: { _, _ in }, newPlaylistFromSelection: { _ in }, love: { _ in },
            goToArtist: { _ in }, goToAlbum: { _ in }, showInFinder: noop, rescanFile: noop,
            getInfo: { _ in }, identify: noop, removeFromLibrary: { _ in },
            deleteFromDisk: { _ in }, copy: { _ in }, toggleShuffle: { _, _ in },
            computeReplayGain: { _ in }, rate: { _, _ in },
            removeFromPlaylist: nil, editLyrics: nil, fetchLyricsFromLRClib: nil
        )
        let table = TrackTable(
            rows: [],
            selection: Binding(get: { selectionStub }, set: { selectionStub = $0 }),
            sortOrder: Binding(get: { sortStub }, set: { sortStub = $0 }),
            nowPlayingTrackID: nil, sortable: false, playlistNodes: [],
            actions: actions, scrollRequest: 0, onMove: nil
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
        #expect(
            source.contains("accessibilityHint(\"Double-tap to open album\")"),
            "AlbumCell must declare accessibilityHint(\"Double-tap to open album\")"
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
}
