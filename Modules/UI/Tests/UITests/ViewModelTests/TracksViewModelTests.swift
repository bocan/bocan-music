import Foundation
import Testing
@testable import Persistence
@testable import UI

// MARK: - TracksViewModelTests

@Suite("TracksViewModel Tests")
@MainActor
struct TracksViewModelTests {
    private func makeDatabase() async throws -> Database {
        try await Database(location: .inMemory)
    }

    private func makeVM(db: Database) -> TracksViewModel {
        TracksViewModel(
            repository: TrackRepository(database: db),
            artistRepository: ArtistRepository(database: db),
            albumRepository: AlbumRepository(database: db)
        )
    }

    private func makeTrack(
        id: Int64? = nil,
        title: String = "Track",
        duration: TimeInterval = 180,
        playCount: Int = 0,
        rating: Int = 0,
        addedAt: Int64 = 0,
        genre: String? = nil
    ) -> Track {
        var t = Track(
            fileURL: "file:///tmp/\(title).flac",
            fileSize: 1024,
            fileMtime: 0,
            fileFormat: "flac",
            duration: duration,
            title: title,
            addedAt: addedAt,
            updatedAt: 0
        )
        t.id = id
        t.playCount = playCount
        t.rating = rating
        t.genre = genre
        return t
    }

    // MARK: - Sort

    @Test("Default sort is addedAt descending")
    func defaultSortOrder() async throws {
        let db = try await makeDatabase()
        let repo = TrackRepository(database: db)
        _ = try await repo.insert(self.makeTrack(title: "A", addedAt: 100))
        _ = try await repo.insert(self.makeTrack(title: "B", addedAt: 200))
        let vm = self.makeVM(db: db)
        await vm.load()
        // Descending: B (200) before A (100)
        #expect(vm.tracks.first?.title == "B")
    }

    @Test("Sort by title ascending")
    func sortByTitleAscending() async throws {
        let db = try await makeDatabase()
        let repo = TrackRepository(database: db)
        _ = try await repo.insert(self.makeTrack(title: "Zebra"))
        _ = try await repo.insert(self.makeTrack(title: "Apple"))
        let vm = self.makeVM(db: db)
        await vm.load()
        vm.setSort(column: .title, ascending: true)
        #expect(vm.tracks.first?.title == "Apple")
    }

    @Test("Sort by duration descending")
    func sortByDurationDescending() async throws {
        let db = try await makeDatabase()
        let repo = TrackRepository(database: db)
        _ = try await repo.insert(self.makeTrack(title: "Short", duration: 60))
        _ = try await repo.insert(self.makeTrack(title: "Long", duration: 360))
        let vm = self.makeVM(db: db)
        await vm.load()
        vm.setSort(column: .duration, ascending: false)
        #expect(vm.tracks.first?.title == "Long")
    }

    @Test("Sort by playCount ascending")
    func sortByPlayCountAscending() async throws {
        let db = try await makeDatabase()
        let repo = TrackRepository(database: db)
        _ = try await repo.insert(self.makeTrack(title: "Frequent", playCount: 42))
        _ = try await repo.insert(self.makeTrack(title: "Rare", playCount: 1))
        let vm = self.makeVM(db: db)
        await vm.load()
        vm.setSort(column: .playCount, ascending: true)
        #expect(vm.tracks.first?.title == "Rare")
    }

    // MARK: - Filter

    @Test("Client-side filter narrows results")
    func filterNarrowsResults() async throws {
        let db = try await makeDatabase()
        let repo = TrackRepository(database: db)
        _ = try await repo.insert(self.makeTrack(title: "Hello World"))
        _ = try await repo.insert(self.makeTrack(title: "Goodbye"))
        let vm = self.makeVM(db: db)
        await vm.load()
        vm.filterText = "hello"
        // The filter is applied by applyFilter; we trigger it via setSort (no direct setter)
        // Alternatively, set via setTracks which calls applyFilter
        vm.setTracks(vm.tracks) // re-apply filter
        #expect(vm.tracks.count == 1)
        #expect(vm.tracks.first?.title == "Hello World")
    }

    // MARK: - Selection

    @Test("Selection stores track IDs")
    func selectionStoresIDs() async throws {
        let db = try await makeDatabase()
        let repo = TrackRepository(database: db)
        let id1 = try await repo.insert(self.makeTrack(title: "One"))
        let id2 = try await repo.insert(self.makeTrack(title: "Two"))
        let vm = self.makeVM(db: db)
        await vm.load()
        vm.selection = [id1, id2]
        #expect(vm.selection.count == 2)
        #expect(vm.selection.contains(id1))
    }

    @Test("Empty library produces empty tracks array")
    func emptyLibrary() async throws {
        let db = try await makeDatabase()
        let repo = TrackRepository(database: db)
        let vm = self.makeVM(db: db)
        await vm.load()
        #expect(vm.tracks.isEmpty)
        #expect(!vm.isLoading)
    }

    @Test("setTracks replaces backing array")
    func setTracksReplaces() async throws {
        let db = try await makeDatabase()
        let repo = TrackRepository(database: db)
        let vm = self.makeVM(db: db)
        let tracks = [makeTrack(id: 1, title: "Custom")]
        vm.setTracks(tracks)
        #expect(vm.tracks.count == 1)
        #expect(vm.tracks.first?.title == "Custom")
    }

    // MARK: - Artist / Album name lookups (regression for blank columns bug)

    @Test("artistNames and albumNames are populated after load()")
    func nameLookupsMaterialiseOnLoad() async throws {
        let db = try await makeDatabase()
        let artistRepo = ArtistRepository(database: db)
        let albumRepo = AlbumRepository(database: db)
        let trackRepo = TrackRepository(database: db)

        var artist = Artist(name: "The Beatles", sortName: "Beatles, The")
        let artistID = try await artistRepo.insert(artist)
        artist.id = artistID

        var album = Album(title: "Abbey Road", albumArtistID: artistID)
        let albumID = try await albumRepo.insert(album)
        album.id = albumID

        var track = Track(
            fileURL: "file:///tmp/cometogethertrack.flac",
            fileSize: 1024,
            fileMtime: 0,
            fileFormat: "flac",
            duration: 259,
            title: "Come Together",
            addedAt: 0,
            updatedAt: 0
        )
        track.artistID = artistID
        track.albumID = albumID
        _ = try await trackRepo.insert(track)

        let vm = self.makeVM(db: db)
        await vm.load()

        #expect(vm.artistNames[artistID] == "The Beatles")
        #expect(vm.albumNames[albumID] == "Abbey Road")
    }
}
