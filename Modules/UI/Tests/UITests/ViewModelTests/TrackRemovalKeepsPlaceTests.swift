import Foundation
import Testing
@testable import Persistence
@testable import UI

// MARK: - TrackRemovalKeepsPlaceTests

/// Deleting a song used to reload the whole destination. The table lost its
/// scroll position and its selection, because the rows array was replaced and
/// the view swapped the table for a loading state while the refetch ran (#543).
///
/// These cover the replacement: the rows go away in place, with one write to
/// `rows` per action however many tracks the action names.
@Suite("Track removal keeps the listener's place")
@MainActor
struct TrackRemovalKeepsPlaceTests {
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

    private func makeTrack(title: String) -> Track {
        Track(
            fileURL: "file:///tmp/\(title).flac",
            fileSize: 1024,
            fileMtime: 0,
            fileFormat: "flac",
            duration: 180,
            title: title,
            addedAt: 0,
            updatedAt: 0
        )
    }

    private func titles(_ vm: TracksViewModel) -> [String] {
        vm.rows.map(\.title)
    }

    // MARK: - The rows

    @Test("a removed track leaves, the rest keep their order")
    func removalKeepsTheRest() async throws {
        let db = try await self.makeDatabase()
        let repo = TrackRepository(database: db)
        _ = try await repo.insert(self.makeTrack(title: "A"))
        let middle = try await repo.insert(self.makeTrack(title: "B"))
        _ = try await repo.insert(self.makeTrack(title: "C"))
        let vm = self.makeVM(db: db)
        await vm.load()
        let before = self.titles(vm)

        vm.removeRows(ids: [middle])

        #expect(self.titles(vm) == before.filter { $0 != "B" })
    }

    @Test("one write to rows, however many tracks go")
    func oneWritePerRemoval() async throws {
        let db = try await self.makeDatabase()
        let repo = TrackRepository(database: db)
        let first = try await repo.insert(self.makeTrack(title: "A"))
        let second = try await repo.insert(self.makeTrack(title: "B"))
        _ = try await repo.insert(self.makeTrack(title: "C"))
        let vm = self.makeVM(db: db)
        await vm.load()
        let version = vm.rowsVersion

        vm.removeRows(ids: [first, second])

        // Each bump makes the table walk every row, so a batch that bumps once
        // per track is the expensive shape this replaced.
        #expect(vm.rowsVersion == version + 1)
        #expect(vm.rows.count == 1)
    }

    @Test("a removal that matches nothing leaves the rows and the version alone")
    func unmatchedRemovalIsANoOp() async throws {
        let db = try await self.makeDatabase()
        let repo = TrackRepository(database: db)
        _ = try await repo.insert(self.makeTrack(title: "A"))
        let vm = self.makeVM(db: db)
        await vm.load()
        let version = vm.rowsVersion

        vm.removeRows(ids: [9999])
        vm.removeRows(ids: [])

        #expect(vm.rowsVersion == version)
        #expect(vm.rows.count == 1)
    }

    @Test("the gone track leaves the selection, the rest of it stays")
    func removalPrunesTheSelection() async throws {
        let db = try await self.makeDatabase()
        let repo = TrackRepository(database: db)
        let doomed = try await repo.insert(self.makeTrack(title: "A"))
        let kept = try await repo.insert(self.makeTrack(title: "B"))
        let vm = self.makeVM(db: db)
        await vm.load()
        vm.selection = [doomed, kept]

        vm.removeRows(ids: [doomed])

        #expect(vm.selection == [kept])
    }

    // MARK: - The delete actions

    @Test("delete from disk takes the row out without a reload")
    func deleteFromDiskRemovesInPlace() async throws {
        let db = try await self.makeDatabase()
        let repo = TrackRepository(database: db)
        let doomed = try await repo.insert(self.makeTrack(title: "A"))
        _ = try await repo.insert(self.makeTrack(title: "B"))
        let library = LibraryViewModel(database: db, engine: MockTransport())
        await library.tracks.load()
        let version = library.tracks.rowsVersion

        await library.deleteTrackFromDisk(id: doomed, using: NoOpFileDeleter())

        #expect(self.titles(library.tracks) == ["B"])
        // A reload refetches and rewrites the array; one bump says it did not.
        #expect(library.tracks.rowsVersion == version + 1)
    }

    @Test("removing a selection from the library is one pass, not one per track")
    func removeFromLibraryIsOnePass() async throws {
        let db = try await self.makeDatabase()
        let repo = TrackRepository(database: db)
        let first = try await repo.insert(self.makeTrack(title: "A"))
        let second = try await repo.insert(self.makeTrack(title: "B"))
        _ = try await repo.insert(self.makeTrack(title: "C"))
        let library = LibraryViewModel(database: db, engine: MockTransport())
        await library.tracks.load()
        let version = library.tracks.rowsVersion

        await library.removeTracks(ids: [first, second])

        #expect(self.titles(library.tracks) == ["C"])
        #expect(library.tracks.rowsVersion == version + 1)
        let stillThere = try await repo.fetch(id: first)
        #expect(stillThere.disabled == true)
    }

    // MARK: - Navigation

    @Test("moving to another destination empties the list first")
    func navigationClearsTheRows() async throws {
        let db = try await self.makeDatabase()
        let repo = TrackRepository(database: db)
        _ = try await repo.insert(self.makeTrack(title: "A"))
        let library = LibraryViewModel(database: db, engine: MockTransport())
        await library.selectDestination(.songs)
        try #require(!library.tracks.rows.isEmpty)

        await library.selectDestination(.albums)

        // Otherwise the mounted table shows the songs of the place just left
        // until the new destination lands.
        #expect(library.tracks.rows.isEmpty)
    }

    @Test("a refresh of the same destination keeps the rows")
    func refreshKeepsTheRows() async throws {
        let db = try await self.makeDatabase()
        let repo = TrackRepository(database: db)
        _ = try await repo.insert(self.makeTrack(title: "A"))
        let library = LibraryViewModel(database: db, engine: MockTransport())
        await library.selectDestination(.songs)

        await library.selectDestination(.songs)

        #expect(self.titles(library.tracks) == ["A"])
    }

    // MARK: - The view

    @Test("the table branch comes before the loading branch")
    func tableOutranksTheSpinner() throws {
        let source = try String(
            contentsOf: URL(filePath: #filePath)
                .deletingLastPathComponent() // ViewModelTests/
                .deletingLastPathComponent() // UITests/
                .deletingLastPathComponent() // Tests/
                .deletingLastPathComponent() // Modules/UI/
                .appending(path: "Sources/UI/Browse/TracksView.swift"),
            encoding: .utf8
        )
        let table = try #require(source.range(of: "if !self.vm.rows.isEmpty"))
        let loading = try #require(source.range(of: "} else if self.vm.isLoading"))

        // Reversed, the spinner replaces the table on every refresh, AppKit
        // throws the NSTableView away, and the new one starts at the top.
        #expect(table.lowerBound < loading.lowerBound)
    }
}

// MARK: - Test doubles

/// Reports success for both on-disk operations without touching the file
/// system; the disk behaviour itself is covered by the delete-from-disk suite.
private struct NoOpFileDeleter: TrackFileDeleter {
    func trash(_: URL) throws {}
    func remove(_: URL) throws {}
}
