import Foundation
import Metadata
import Persistence
import Testing
@testable import Library

@Suite("MetadataEditService MusicBrainz IDs, multi-track edits and undo")
struct MetadataEditServiceIDsAndUndoTests: MetadataEditServiceFixtures {
    // MARK: - MusicBrainz IDs + ISRC (ADR-012)

    @Test func editWritesMusicBrainzIDsToFileAndDB() async throws {
        let db = try await makeDatabase()
        let tmp = try tempMP3()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let trackID = try await insertTrack(in: db, fileURL: tmp.absoluteString)
        let svc = try MetadataEditService(database: db)

        var patch = TrackTagPatch()
        patch.isrc = "GBAYE0601696"
        patch.musicbrainzTrackID = "7fe8e13a-7ae0-3ff6-8429-52ddf31e6e1b"
        patch.musicbrainzRecordingID = "485bbe7f-d0f7-4ffe-8adb-0f1093dd2dbf"
        patch.musicbrainzReleaseID = "9e53c190-5621-3848-8ae4-39ad9f7d9ace"
        patch.musicbrainzReleaseGroupID = "9162580e-5df4-32de-80cc-f45a8d8a9b1d"
        patch.musicbrainzAlbumArtistID = "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d"
        #expect(!patch.isEmpty)
        try await svc.edit(trackID: trackID, patch: patch)

        // File bytes carry the identifiers…
        let reread = try TagReader().read(from: tmp)
        #expect(reread.isrc == "GBAYE0601696")
        #expect(reread.musicbrainzTrackID == "7fe8e13a-7ae0-3ff6-8429-52ddf31e6e1b")
        #expect(reread.musicbrainzRecordingID == "485bbe7f-d0f7-4ffe-8adb-0f1093dd2dbf")
        #expect(reread.musicbrainzReleaseID == "9e53c190-5621-3848-8ae4-39ad9f7d9ace")
        #expect(reread.musicbrainzReleaseGroupID == "9162580e-5df4-32de-80cc-f45a8d8a9b1d")
        #expect(reread.musicbrainzAlbumArtistID == "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d")

        // …and so does the DB row, in the same edit.
        let updated = try await TrackRepository(database: db).fetch(id: trackID)
        #expect(updated.isrc == "GBAYE0601696")
        #expect(updated.musicbrainzTrackID == "7fe8e13a-7ae0-3ff6-8429-52ddf31e6e1b")
        #expect(updated.musicbrainzRecordingID == "485bbe7f-d0f7-4ffe-8adb-0f1093dd2dbf")
        #expect(updated.musicbrainzReleaseID == "9e53c190-5621-3848-8ae4-39ad9f7d9ace")
        #expect(updated.musicbrainzReleaseGroupID == "9162580e-5df4-32de-80cc-f45a8d8a9b1d")
        #expect(updated.musicbrainzAlbumArtistID == "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d")
    }

    @Test func clearingMusicBrainzIDsRemovesThem() async throws {
        let db = try await makeDatabase()
        let tmp = try tempMP3()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let trackID = try await insertTrack(in: db, fileURL: tmp.absoluteString)
        let svc = try MetadataEditService(database: db)

        var set = TrackTagPatch()
        set.musicbrainzRecordingID = "485bbe7f-d0f7-4ffe-8adb-0f1093dd2dbf"
        try await svc.edit(trackID: trackID, patch: set)

        // `.some(nil)` means "clear this field".
        var clear = TrackTagPatch()
        clear.musicbrainzRecordingID = .some(nil)
        try await svc.edit(trackID: trackID, patch: clear)

        let reread = try TagReader().read(from: tmp)
        #expect(reread.musicbrainzRecordingID == nil)
        let updated = try await TrackRepository(database: db).fetch(id: trackID)
        #expect(updated.musicbrainzRecordingID == nil)
    }

    @Test func undoPreservesPreexistingMusicBrainzIDs() async throws {
        let db = try await makeDatabase()
        let tmp = try tempMP3()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let trackID = try await insertTrack(in: db, fileURL: tmp.absoluteString)
        let svc = try MetadataEditService(database: db)

        // The file already carries an MBID (e.g. tagged by Picard) before the edit.
        var mbPatch = TrackTagPatch()
        mbPatch.musicbrainzRecordingID = "485bbe7f-d0f7-4ffe-8adb-0f1093dd2dbf"
        try await svc.edit(trackID: trackID, patch: mbPatch)

        // An unrelated edit, then undo: the snapshot must round-trip the MBID
        // or the restore write erases it from the file.
        var titlePatch = TrackTagPatch()
        titlePatch.title = "Retitled"
        let editID = try await svc.edit(trackID: trackID, patch: titlePatch)
        try await svc.undo(editID: editID)

        let restored = try TagReader().read(from: tmp)
        #expect(restored.musicbrainzRecordingID == "485bbe7f-d0f7-4ffe-8adb-0f1093dd2dbf")
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

        // Edit album only: artist should remain distinct
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
