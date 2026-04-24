import Foundation
import Metadata
import Persistence
import Testing
@testable import Library

@Suite("MetadataEditService")
struct MetadataEditServiceTests {
    // MARK: - Helpers

    private func makeDatabase() async throws -> Persistence.Database {
        try await Persistence.Database(location: .inMemory)
    }

    /// Inserts a bare track and returns its row ID.
    private func insertTrack(
        in db: Persistence.Database,
        fileURL: String,
        title: String = "Track"
    ) async throws -> Int64 {
        let now = Int64(Date().timeIntervalSince1970)
        let track = Track(
            fileURL: fileURL,
            title: title,
            addedAt: now,
            updatedAt: now
        )
        return try await TrackRepository(database: db).insert(track)
    }

    /// Fixture MP3 (from sample-library) copied to a temp file; caller owns cleanup.
    private func tempMP3() throws -> URL {
        guard let libraryURL = Bundle.module.url(
            forResource: "sample-library",
            withExtension: nil,
            subdirectory: "Fixtures"
        ) else {
            throw FixtureError.notFound("sample-library")
        }
        // Find the first non-corrupt MP3
        let enumerator = FileManager.default.enumerator(at: libraryURL, includingPropertiesForKeys: nil)
        while let candidate = enumerator?.nextObject() as? URL {
            guard candidate.pathExtension == "mp3",
                  !candidate.lastPathComponent.lowercased().contains("corrupt") else { continue }
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString).mp3")
            try FileManager.default.copyItem(at: candidate, to: tmp)
            return tmp
        }
        throw FixtureError.notFound("mp3 in sample-library")
    }

    // MARK: - edit single track

    @Test func editSingleTrackUpdatesFile() async throws {
        let db = try await makeDatabase()
        let tmp = try tempMP3()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let trackID = try await insertTrack(in: db, fileURL: tmp.absoluteString)
        let svc = try MetadataEditService(database: db)

        var patch = TrackTagPatch()
        patch.genre = "Blues"
        try await svc.edit(trackID: trackID, patch: patch)

        // Verify file tag was updated
        let reread = try TagReader().read(from: tmp)
        #expect(reread.genre == "Blues")
    }

    @Test func editSingleTrackUpdatesDB() async throws {
        let db = try await makeDatabase()
        let tmp = try tempMP3()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let trackID = try await insertTrack(in: db, fileURL: tmp.absoluteString)
        let svc = try MetadataEditService(database: db)

        var patch = TrackTagPatch()
        patch.genre = "Classical"
        try await svc.edit(trackID: trackID, patch: patch)

        let updated = try await TrackRepository(database: db).fetch(id: trackID)
        #expect(updated.genre == "Classical")
        #expect(updated.userEdited == true)
    }

    @Test func editSetsUserEditedFlag() async throws {
        let db = try await makeDatabase()
        let tmp = try tempMP3()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let trackID = try await insertTrack(in: db, fileURL: tmp.absoluteString)
        let svc = try MetadataEditService(database: db)

        var patch = TrackTagPatch()
        patch.title = "Manually Edited"
        try await svc.edit(trackID: trackID, patch: patch)

        let track = try await TrackRepository(database: db).fetch(id: trackID)
        #expect(track.userEdited == true)
    }

    // MARK: - multi-track: only changed fields written

    @Test func multiEditOnlyWritesChangedFields() async throws {
        let db = try await makeDatabase()
        let tmp1 = try tempMP3()
        let tmp2 = try tempMP3()
        defer {
            try? FileManager.default.removeItem(at: tmp1)
            try? FileManager.default.removeItem(at: tmp2)
        }

        // Pre-set distinct artists
        var t1tags = try TagReader().read(from: tmp1)
        t1tags.artist = "Artist One"
        try TagWriter().write(t1tags, to: tmp1)

        var t2tags = try TagReader().read(from: tmp2)
        t2tags.artist = "Artist Two"
        try TagWriter().write(t2tags, to: tmp2)

        let id1 = try await insertTrack(in: db, fileURL: tmp1.absoluteString, title: "T1")
        let id2 = try await insertTrack(in: db, fileURL: tmp2.absoluteString, title: "T2")

        let svc = try MetadataEditService(database: db)

        // Edit album only — artist should remain distinct
        var patch = TrackTagPatch()
        patch.album = "Shared Album"
        try await svc.edit(trackIDs: [id1, id2], patch: patch)

        let rr1 = try TagReader().read(from: tmp1)
        let rr2 = try TagReader().read(from: tmp2)
        #expect(rr1.album == "Shared Album")
        #expect(rr2.album == "Shared Album")
        #expect(rr1.artist == "Artist One") // unchanged
        #expect(rr2.artist == "Artist Two") // unchanged
    }

    // MARK: - undo

    @Test func undoRestoresOriginalTags() async throws {
        let db = try await makeDatabase()
        let tmp = try tempMP3()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Read original title
        let originalTags = try TagReader().read(from: tmp)
        let originalTitle = originalTags.title

        let trackID = try await insertTrack(in: db, fileURL: tmp.absoluteString)
        let svc = try MetadataEditService(database: db)

        var patch = TrackTagPatch()
        patch.title = "Changed Title"
        let editID = try await svc.edit(trackID: trackID, patch: patch)

        // Verify the change happened
        let after = try TagReader().read(from: tmp)
        #expect(after.title == "Changed Title")

        // Undo
        try await svc.undo(editID: editID)

        // Verify original restored
        let restored = try TagReader().read(from: tmp)
        #expect(restored.title == originalTitle)
    }

    // MARK: - empty patch is a no-op

    @Test func emptyPatchDoesNothing() async throws {
        let db = try await makeDatabase()
        let tmp = try tempMP3()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let originalData = try Data(contentsOf: tmp)
        let trackID = try await insertTrack(in: db, fileURL: tmp.absoluteString)
        let svc = try MetadataEditService(database: db)

        let editID = try await svc.edit(trackID: trackID, patch: TrackTagPatch())
        #expect(editID.isEmpty)

        // File should be unmodified
        let afterData = try Data(contentsOf: tmp)
        #expect(afterData == originalData)
    }
}

private enum FixtureError: Error {
    case notFound(String)
}
