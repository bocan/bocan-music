import Foundation
import Testing
@testable import Persistence
@testable import UI

// MARK: - Mock TrackFileDeleter

/// Lets tests assert which on-disk operation was attempted and force either
/// step to throw a specific error.
private final class MockTrackFileDeleter: TrackFileDeleter, @unchecked Sendable {
    var trashError: (any Error)?
    var removeError: (any Error)?
    var trashErrorURLs: [URL: any Error] = [:]
    private(set) var trashedURLs: [URL] = []
    private(set) var removedURLs: [URL] = []

    func trash(_ url: URL) throws {
        self.trashedURLs.append(url)
        if let err = trashErrorURLs[url] { throw err }
        if let trashError { throw trashError }
    }

    func remove(_ url: URL) throws {
        self.removedURLs.append(url)
        if let removeError { throw removeError }
    }
}

// MARK: - Tests

/// Phase 5.5 audit M3 regression coverage: trashing must surface its failure
/// to the caller so a secondary "Delete Permanently" confirmation can be
/// offered, and the DB row must only be soft-deleted after the file actually
/// leaves disk.
@Suite("LibraryViewModel Delete-From-Disk Tests")
@MainActor
struct LibraryViewModelDeleteFromDiskTests {
    private func makeDatabase() async throws -> Database {
        try await Database(location: .inMemory)
    }

    private func makeTrack(fileURL: String = "file:///tmp/song.flac") -> Track {
        Track(
            fileURL: fileURL,
            fileSize: 1024,
            fileMtime: 0,
            fileFormat: "flac",
            duration: 120,
            title: "Song",
            addedAt: 0,
            updatedAt: 0
        )
    }

    @Test("Successful trash soft-deletes the row and reports .trashed")
    func trashSuccess() async throws {
        let db = try await self.makeDatabase()
        let repo = TrackRepository(database: db)
        let id = try await repo.insert(self.makeTrack())
        let vm = LibraryViewModel(database: db, engine: MockTransport())
        let deleter = MockTrackFileDeleter()

        let outcome = await vm.deleteTrackFromDisk(id: id, using: deleter)

        guard case .trashed = outcome else {
            Issue.record("expected .trashed, got \(outcome)")
            return
        }
        #expect(deleter.trashedURLs.count == 1)
        #expect(deleter.removedURLs.isEmpty)
        let updated = try await repo.fetch(id: id)
        #expect(updated.disabled == true)
    }

    @Test("Trash failure leaves DB row untouched and reports .trashFailed")
    func trashFailureLeavesRowAlone() async throws {
        let db = try await self.makeDatabase()
        let repo = TrackRepository(database: db)
        let id = try await repo.insert(self.makeTrack())
        let vm = LibraryViewModel(database: db, engine: MockTransport())
        let deleter = MockTrackFileDeleter()
        struct FakeTrashError: Error {}
        deleter.trashError = FakeTrashError()

        let outcome = await vm.deleteTrackFromDisk(id: id, using: deleter)

        guard case let .trashFailed(_, fileURL) = outcome else {
            Issue.record("expected .trashFailed, got \(outcome)")
            return
        }
        #expect(fileURL.absoluteString == "file:///tmp/song.flac")
        #expect(deleter.trashedURLs.count == 1)
        #expect(deleter.removedURLs.isEmpty)
        let after = try await repo.fetch(id: id)
        #expect(after.disabled == false)
    }

    @Test("Permanent delete soft-deletes the row when removeItem succeeds")
    func permanentDeleteSuccess() async throws {
        let db = try await self.makeDatabase()
        let repo = TrackRepository(database: db)
        let id = try await repo.insert(self.makeTrack())
        let vm = LibraryViewModel(database: db, engine: MockTransport())
        let deleter = MockTrackFileDeleter()

        await vm.permanentlyDeleteTrackFromDisk(id: id, using: deleter)

        #expect(deleter.removedURLs.count == 1)
        let updated = try await repo.fetch(id: id)
        #expect(updated.disabled == true)
    }

    @Test("Permanent delete failure surfaces an error and keeps the row")
    func permanentDeleteFailureKeepsRow() async throws {
        let db = try await self.makeDatabase()
        let repo = TrackRepository(database: db)
        let id = try await repo.insert(self.makeTrack())
        let vm = LibraryViewModel(database: db, engine: MockTransport())
        let deleter = MockTrackFileDeleter()
        struct FakeRemoveError: Error {}
        deleter.removeError = FakeRemoveError()

        await vm.permanentlyDeleteTrackFromDisk(id: id, using: deleter)

        #expect(deleter.removedURLs.count == 1)
        #expect(vm.playbackErrorMessage != nil)
        let after = try await repo.fetch(id: id)
        #expect(after.disabled == false)
    }

    @Test("Batch delete trashes all files and calls tracks.load once")
    func batchDeleteAllSucceed() async throws {
        let db = try await self.makeDatabase()
        let repo = TrackRepository(database: db)
        let id1 = try await repo.insert(self.makeTrack(fileURL: "file:///tmp/a.flac"))
        let id2 = try await repo.insert(self.makeTrack(fileURL: "file:///tmp/b.flac"))
        let id3 = try await repo.insert(self.makeTrack(fileURL: "file:///tmp/c.flac"))
        let vm = LibraryViewModel(database: db, engine: MockTransport())
        let deleter = MockTrackFileDeleter()
        let tracks = try await [
            repo.fetch(id: id1),
            repo.fetch(id: id2),
            repo.fetch(id: id3),
        ]

        let failures = await vm.deleteTracksFromDisk(tracks: tracks, using: deleter)

        #expect(failures.isEmpty)
        #expect(deleter.trashedURLs.count == 3)
        #expect(deleter.removedURLs.isEmpty)
        for id in [id1, id2, id3] {
            let updated = try await repo.fetch(id: id)
            #expect(updated.disabled == true)
        }
    }

    @Test("Batch delete returns only failed tracks, succeeds soft-deletes the rest")
    func batchDeletePartialFailure() async throws {
        let db = try await self.makeDatabase()
        let repo = TrackRepository(database: db)
        let id1 = try await repo.insert(self.makeTrack(fileURL: "file:///tmp/a.flac"))
        let id2 = try await repo.insert(self.makeTrack(fileURL: "file:///tmp/b.flac"))
        let vm = LibraryViewModel(database: db, engine: MockTransport())
        let deleter = MockTrackFileDeleter()
        struct FakeTrashError: Error {}
        // First trash call will fail; second will succeed.
        deleter.trashErrorURLs = try [#require(URL(string: "file:///tmp/a.flac")): FakeTrashError()]
        let tracks = try await [
            repo.fetch(id: id1),
            repo.fetch(id: id2),
        ]

        let failures = await vm.deleteTracksFromDisk(tracks: tracks, using: deleter)

        #expect(failures.count == 1)
        #expect(failures[0].0.id == id1)
        let row1 = try await repo.fetch(id: id1)
        #expect(row1.disabled == false) // trash failed — row untouched
        let row2 = try await repo.fetch(id: id2)
        #expect(row2.disabled == true) // trash succeeded — row soft-deleted
    }
}
