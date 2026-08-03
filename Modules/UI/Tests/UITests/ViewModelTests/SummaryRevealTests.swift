import Foundation
import Testing
@testable import Persistence
@testable import UI

// MARK: - SummaryRevealTests

/// Regression coverage for Library Summary navigation: the stale-header bug
/// (a detail view whose task never re-fired when only its id changed, showing
/// album A's header over album B's tracks) and the reveal path that selects
/// and scrolls to the offending song.
@Suite("Summary reveal navigation")
@MainActor
struct SummaryRevealTests {
    private static func uiSource(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI/\(relativePath)")
    }

    @Test("Detail views re-load when only their id changes")
    func detailViewsUseTaskID() throws {
        let album = try String(
            contentsOf: Self.uiSource("Browse/AlbumDetailView.swift"),
            encoding: .utf8
        )
        #expect(
            album.contains(".task(id: self.albumID)"),
            "a plain .task never re-fires on .album(A) -> .album(B) and strands album A's header"
        )
        let artists = try String(
            contentsOf: Self.uiSource("Browse/ArtistsView.swift"),
            encoding: .utf8
        )
        #expect(
            artists.contains(".task(id: self.artistID)"),
            "ArtistDetailView has the same identity trap as AlbumDetailView"
        )
    }

    @Test("Offender rows with a track reveal it instead of just opening the album")
    func offenderRowsReveal() throws {
        let source = try String(
            contentsOf: Self.uiSource("Summary/SummaryRows.swift"),
            encoding: .utf8
        )
        #expect(
            source.contains("revealTrack(trackID, inAlbum: albumID)"),
            "a row that knows its track must land the user on that track"
        )
    }

    @Test("revealTrack navigates, selects, and targets the scroll")
    func revealTrackSelects() async throws {
        let db = try await Database(location: .inMemory)
        let (albumID, trackID) = try await db.write { db -> (Int64, Int64) in
            var artist = Artist(name: "Reveal")
            try artist.insert(db)
            var album = Album(title: "Target", albumArtistID: artist.id)
            try album.insert(db)
            var track = Track(
                fileURL: "file:///tmp/reveal.flac",
                fileFormat: "flac",
                duration: 200,
                title: "The One",
                addedAt: 0,
                updatedAt: 0
            )
            track.artistID = artist.id
            track.albumID = album.id
            try track.insert(db)
            return try (#require(album.id), #require(track.id))
        }

        let vm = LibraryViewModel(database: db, engine: MockTransport())
        let requestsBefore = vm.tracks.scrollRequest
        await vm.revealTrack(trackID, inAlbum: albumID)

        #expect(vm.selectedDestination == .album(albumID))
        #expect(vm.tracks.selection == [trackID])
        #expect(vm.tracks.scrollTargetTrackID == trackID)
        #expect(vm.tracks.scrollRequest == requestsBefore + 1)
        #expect(vm.tracks.tracks.map(\.id) == [trackID], "the album's tracks must be loaded")

        // The now-playing jump must clear the target so it scrolls to the
        // playing row again, not the last revealed offender.
        vm.tracks.requestScrollToNowPlaying()
        #expect(vm.tracks.scrollTargetTrackID == nil)
    }
}
