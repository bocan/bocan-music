import Foundation
import Persistence
import SwiftUI
import Testing
@testable import UI

// MARK: - TrackTableDragTests

/// Covers the file-URL resolution that lets a track be dragged out to Finder (#311).
@Suite("TrackTable drag-out")
@MainActor
struct TrackTableDragTests {
    private func makeCoordinator() -> TrackTableCoordinator {
        var selection = Set<Track.ID>()
        var sort = [KeyPathComparator<TrackRow>]()
        let noop: (Track) -> Void = { _ in }
        let actions = TrackContextMenuActions(
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
        let table = TrackTable(
            rows: [],
            selection: Binding(get: { selection }, set: { selection = $0 }),
            sortOrder: Binding(get: { sort }, set: { sort = $0 }),
            nowPlayingTrackID: nil,
            sortable: false,
            playlistNodes: [],
            actions: actions,
            scrollRequest: 0,
            onMove: nil
        )
        return TrackTableCoordinator(parent: table)
    }

    private func makeRow(id: Int64, fileURL: String) -> TrackRow {
        let now = Int64(Date().timeIntervalSince1970)
        let track = Track(
            id: id,
            fileURL: fileURL,
            fileSize: 0,
            fileMtime: now,
            fileFormat: "flac",
            duration: 100,
            title: "Track \(id)",
            addedAt: now,
            updatedAt: now
        )
        return TrackRow(track: track, artistName: "Artist", albumName: "Album")
    }

    @Test("fileURL(forTrackID:) returns the on-disk URL for a local track (#311)")
    func resolvesLocalFileURL() {
        let coordinator = self.makeCoordinator()
        coordinator.updateRows([self.makeRow(id: 1, fileURL: "file:///Users/me/Music/song.flac")])
        let url = coordinator.fileURL(forTrackID: 1)
        #expect(url?.isFileURL == true)
        #expect(url?.path == "/Users/me/Music/song.flac")
    }

    @Test("fileURL(forTrackID:) returns nil for a non-file (streamed) source (#311)")
    func rejectsNonFileURL() {
        let coordinator = self.makeCoordinator()
        coordinator.updateRows([self.makeRow(id: 2, fileURL: "https://stream.example.com/song.mp3")])
        #expect(coordinator.fileURL(forTrackID: 2) == nil)
    }

    @Test("fileURL(forTrackID:) returns nil for an unknown track id (#311)")
    func unknownIDReturnsNil() {
        let coordinator = self.makeCoordinator()
        coordinator.updateRows([self.makeRow(id: 1, fileURL: "file:///tmp/a.flac")])
        #expect(coordinator.fileURL(forTrackID: 999) == nil)
    }
}
