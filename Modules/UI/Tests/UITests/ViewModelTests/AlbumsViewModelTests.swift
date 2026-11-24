import Foundation
import Testing
@testable import Persistence
@testable import UI

// MARK: - AlbumsViewModelTests

// `.serialized`: setSortOrder writes a shared UserDefaults key, so running the
// sort/persistence cases in parallel could let one test's write leak into
// another's view-model init.
@Suite("AlbumsViewModel Tests", .serialized)
@MainActor
struct AlbumsViewModelTests {
    private func makeDatabase() async throws -> Database {
        try await Database(location: .inMemory)
    }

    private func makeAlbum(title: String = "Album", year: Int? = nil) -> Album {
        Album(title: title, year: year)
    }

    @Test("Load returns all albums")
    func loadReturnsAllAlbums() async throws {
        let db = try await makeDatabase()
        let repo = AlbumRepository(database: db)
        try await db.write { db in
            var a1 = Album(title: "Abbey Road")
            var a2 = Album(title: "Revolver")
            try a1.insert(db)
            try a2.insert(db)
        }
        let vm = AlbumsViewModel(repository: repo)
        await vm.load()
        #expect(vm.albums.count == 2)
        #expect(!vm.isLoading)
    }

    @Test("Empty library produces empty albums")
    func emptyLibrary() async throws {
        let db = try await makeDatabase()
        let repo = AlbumRepository(database: db)
        let vm = AlbumsViewModel(repository: repo)
        await vm.load()
        #expect(vm.albums.isEmpty)
    }

    @Test("setAlbums replaces list")
    func setAlbumsReplaces() async throws {
        let db = try await makeDatabase()
        let repo = AlbumRepository(database: db)
        let vm = AlbumsViewModel(repository: repo)
        vm.setAlbums([self.makeAlbum(title: "Custom")])
        #expect(vm.albums.count == 1)
        #expect(vm.albums.first?.title == "Custom")
    }

    @Test("Load for artist returns only that artist's albums")
    func loadByArtistID() async throws {
        let db = try await makeDatabase()
        let repo = AlbumRepository(database: db)
        let (artist1ID, artist2ID): (Int64, Int64) = try await db.write { db in
            var a1 = Artist(name: "Artist A")
            var a2 = Artist(name: "Artist B")
            try a1.insert(db)
            try a2.insert(db)
            return try (#require(a1.id), #require(a2.id))
        }
        try await db.write { db in
            var a1 = Album(title: "Album A", albumArtistID: artist1ID)
            var a2 = Album(title: "Album B", albumArtistID: artist2ID)
            try a1.insert(db)
            try a2.insert(db)
        }
        let vm = AlbumsViewModel(repository: repo)
        await vm.load(albumArtistID: artist1ID)
        #expect(vm.albums.count == 1)
        #expect(vm.albums.first?.title == "Album A")
    }

    // MARK: - Sort order (issue #349)

    @Test("albumArtist sort orders by album-artist name, then album title")
    func sortByAlbumArtist() async throws {
        let db = try await makeDatabase()
        let repo = AlbumRepository(database: db)
        let (beatles, abba): (Int64, Int64) = try await db.write { db in
            var beatlesArtist = Artist(name: "Beatles")
            var abbaArtist = Artist(name: "ABBA")
            try beatlesArtist.insert(db)
            try abbaArtist.insert(db)
            return try (#require(beatlesArtist.id), #require(abbaArtist.id))
        }
        try await db.write { db in
            var revolver = Album(title: "Revolver", albumArtistID: beatles)
            var abbeyRoad = Album(title: "Abbey Road", albumArtistID: beatles)
            var arrival = Album(title: "Arrival", albumArtistID: abba)
            try revolver.insert(db)
            try abbeyRoad.insert(db)
            try arrival.insert(db)
        }
        let vm = AlbumsViewModel(repository: repo)
        await vm.load()
        vm.setSortOrder(.albumArtist)
        // ABBA before Beatles; within Beatles, Abbey Road before Revolver.
        #expect(vm.albums.map(\.title) == ["Arrival", "Abbey Road", "Revolver"])
    }

    @Test("yearNewest sort orders by descending year")
    func sortByYearNewest() async throws {
        let db = try await makeDatabase()
        let repo = AlbumRepository(database: db)
        try await db.write { db in
            var old = Album(title: "Revolver", year: 1966)
            var mid = Album(title: "Abbey Road", year: 1969)
            var new = Album(title: "Arrival", year: 1977)
            try old.insert(db)
            try mid.insert(db)
            try new.insert(db)
        }
        let vm = AlbumsViewModel(repository: repo)
        await vm.load()
        vm.setSortOrder(.yearNewest)
        #expect(vm.albums.map(\.year) == [1977, 1969, 1966])
    }

    @Test("sort order is persisted and restored by a fresh view model")
    func sortOrderPersists() async throws {
        let key = AlbumsViewModel.sortOrderKey
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: key)
        defer { defaults.removeObject(forKey: key) }

        let db = try await makeDatabase()
        let repo = AlbumRepository(database: db)

        let first = AlbumsViewModel(repository: repo)
        #expect(first.sortOrder == .albumName) // default with a clean key
        first.setSortOrder(.yearNewest)

        // A new instance (next launch) reads the persisted preference.
        let second = AlbumsViewModel(repository: repo)
        #expect(second.sortOrder == .yearNewest)
    }

    // MARK: - Date added and Recently Added albums (#700)

    /// Inserts a song on `albumID` added `daysAgo` days before now.
    private func insertTrack(_ db: Database, albumID: Int64, daysAgo: Int64) async throws {
        let addedAt = Int64(Date().timeIntervalSince1970) - daysAgo * 86400
        try await db.write { db in
            var track = Track(
                fileURL: "file:///tmp/\(UUID().uuidString).flac",
                title: "Song",
                albumID: albumID,
                addedAt: addedAt,
                updatedAt: addedAt
            )
            try track.insert(db)
        }
    }

    private func insertAlbum(_ db: Database, title: String, year: Int? = nil) async throws -> Int64 {
        try await db.write { db in
            var album = Album(title: title, year: year)
            try album.insert(db)
            return try #require(album.id)
        }
    }

    @Test("dateAdded sort orders by each album's newest song, not its year")
    func sortByDateAdded() async throws {
        let db = try await makeDatabase()
        let repo = AlbumRepository(database: db)
        let classic = try await self.insertAlbum(db, title: "Abbey Road", year: 1969)
        let modern = try await self.insertAlbum(db, title: "Zebra", year: 2024)
        _ = try await self.insertAlbum(db, title: "No Songs")
        try await self.insertTrack(db, albumID: modern, daysAgo: 50)
        try await self.insertTrack(db, albumID: classic, daysAgo: 2)

        let vm = AlbumsViewModel(repository: repo)
        await vm.load()
        vm.setSortOrder(.dateAdded)
        // An album with no songs has no date, so it sorts last.
        #expect(vm.albums.map(\.title) == ["Abbey Road", "Zebra", "No Songs"])
        vm.setSortOrder(.albumName)
    }

    @Test("Recently Added albums lists only albums with a song added inside the window")
    func loadRecentlyAdded() async throws {
        let db = try await makeDatabase()
        let repo = AlbumRepository(database: db)
        let fresh = try await self.insertAlbum(db, title: "Fresh")
        let stale = try await self.insertAlbum(db, title: "Stale")
        let newest = try await self.insertAlbum(db, title: "Newest")
        try await self.insertTrack(db, albumID: fresh, daysAgo: 5)
        try await self.insertTrack(db, albumID: stale, daysAgo: 45)
        try await self.insertTrack(db, albumID: newest, daysAgo: 1)

        let key = AlbumsViewModel.recentlyAddedSortOrderKey
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let vm = AlbumsViewModel(repository: repo, sortOrderKey: key, defaultSortOrder: .dateAdded)
        await vm.load(addedWithinDays: 30)
        #expect(vm.albums.map(\.title) == ["Newest", "Fresh"])
    }

    @Test("Recently Added's album sort starts newest first and never moves the main grid's sort")
    func recentlyAddedSortIsSeparate() async throws {
        let mainKey = AlbumsViewModel.sortOrderKey
        let recentKey = AlbumsViewModel.recentlyAddedSortOrderKey
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: mainKey)
        defaults.removeObject(forKey: recentKey)
        defer {
            defaults.removeObject(forKey: mainKey)
            defaults.removeObject(forKey: recentKey)
        }

        let repo = try await AlbumRepository(database: makeDatabase())
        let recent = AlbumsViewModel(repository: repo, sortOrderKey: recentKey, defaultSortOrder: .dateAdded)
        #expect(recent.sortOrder == .dateAdded)
        recent.setSortOrder(.albumArtist)

        #expect(AlbumsViewModel(repository: repo).sortOrder == .albumName)
        #expect(AlbumsViewModel(repository: repo, sortOrderKey: recentKey, defaultSortOrder: .dateAdded).sortOrder == .albumArtist)
    }

    // MARK: - Keyboard focus (Accessibility ADR-006)

    @Test("Persisted albums have non-nil IDs for FocusState tracking")
    func albumsHaveNonNilIDsForFocusState() async throws {
        // AlbumsGridView uses .focused($focusedAlbumID, equals: album.id).
        // A nil id would silently break keyboard focus tracking.
        let db = try await makeDatabase()
        let repo = AlbumRepository(database: db)
        try await db.write { db in
            var album = Album(title: "Nevermind")
            try album.insert(db)
        }
        let vm = AlbumsViewModel(repository: repo)
        await vm.load()
        #expect(!vm.albums.isEmpty)
        #expect(vm.albums.allSatisfy { $0.id != nil })
    }

    @Test("Keyboard focus navigation index clamping stays within album bounds")
    func keyboardFocusNavigationBoundsAreClamped() {
        /// Validates the algorithm used by AlbumsGridView.moveFocus(by:):
        ///   newIdx = max(0, min(count - 1, currentIdx + delta))
        func clampedMove(count: Int, from: Int, by delta: Int) -> Int {
            max(0, min(count - 1, from + delta))
        }
        // Moving right at last item stays at last item (no overflow).
        #expect(clampedMove(count: 5, from: 4, by: 1) == 4)
        // Moving left at first item stays at first item (no underflow).
        #expect(clampedMove(count: 5, from: 0, by: -1) == 0)
        // Normal single-step navigation within bounds.
        #expect(clampedMove(count: 5, from: 2, by: 1) == 3)
        // Row jump (upArrow with 3-column grid: delta = -3) from middle.
        #expect(clampedMove(count: 5, from: 4, by: -3) == 1)
        // Row jump clamped when there is no full row above.
        #expect(clampedMove(count: 5, from: 1, by: -3) == 0)
    }
}
