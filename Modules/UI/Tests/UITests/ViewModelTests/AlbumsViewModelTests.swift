import Foundation
import Testing
@testable import Persistence
@testable import UI

// MARK: - AlbumsViewModelTests

@Suite("AlbumsViewModel Tests")
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

    // MARK: - Keyboard focus (Accessibility Phase 5)

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
