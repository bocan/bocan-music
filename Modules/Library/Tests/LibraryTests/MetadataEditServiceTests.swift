import Foundation
import Metadata
import Persistence
import Testing
@testable import Library

@Suite("MetadataEditService")
struct MetadataEditServiceTests: MetadataEditServiceFixtures {
    // The fixture builders are in `MetadataEditServiceTestSupport.swift`. The
    // MusicBrainz ID, multi-track and undo tests are in
    // `MetadataEditServiceIDsAndUndoTests`.

    // MARK: - markers (read-only surface for the Get Info Markers tab)

    @Test func markersReturnsPositionSortedMarkersAndEmptyForBareTracks() async throws {
        let db = try await makeDatabase()
        let withMarkers = try await insertTrack(in: db, fileURL: "file:///m/a.flac")
        let bare = try await insertTrack(in: db, fileURL: "file:///m/b.flac")
        try await TrackMarkerRepository(database: db).replaceMarkers(forTrack: withMarkers, with: [
            TrackMarker(trackID: withMarkers, positionMs: 60000, title: "Two", performer: "P"),
            TrackMarker(trackID: withMarkers, positionMs: 0, title: "One"),
        ])

        let svc = try MetadataEditService(database: db)
        let markers = await svc.markers(trackID: withMarkers)
        #expect(markers.map(\.title) == ["One", "Two"], "position-sorted")
        #expect(await svc.markers(trackID: bare).isEmpty)
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

    // MARK: - Cover art → album link

    /// Inserts an artist + album and a track belonging to them.
    private func insertAlbumTrack(
        in db: Persistence.Database,
        fileURL: String
    ) async throws -> (trackID: Int64, albumID: Int64) {
        let artist = try await ArtistRepository(database: db).findOrCreate(name: "The Beatles")
        let album = try await AlbumRepository(database: db).findOrCreate(
            title: "Abbey Road",
            albumArtistID: artist.id
        )
        let albumID = try #require(album.id)
        let now = Int64(Date().timeIntervalSince1970)
        var track = Track(fileURL: fileURL, title: "Track", addedAt: now, updatedAt: now)
        track.albumID = albumID
        let trackID = try await TrackRepository(database: db).insert(track)
        return (trackID, albumID)
    }

    @Test func savedArtworkLinksToAlbumMissingArt() async throws {
        let db = try await makeDatabase()
        let tmp = try tempMP3()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let (trackID, albumID) = try await insertAlbumTrack(in: db, fileURL: tmp.absoluteString)
        let svc = try MetadataEditService(database: db)

        var patch = TrackTagPatch()
        patch.coverArt = .some(Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 0x42, count: 64))
        try await svc.edit(trackID: trackID, patch: patch)

        // The track row carries the hash…
        let track = try await TrackRepository(database: db).fetch(id: trackID)
        #expect(track.coverArtHash != nil)

        // …and the album — which the track list actually renders — is linked too.
        let album = try await AlbumRepository(database: db).fetch(id: albumID)
        #expect(album.coverArtHash == track.coverArtHash)
        #expect(album.coverArtPath != nil)
    }

    /// An `EditTransaction` wired to `db`, so a test can choose the embedding
    /// setting instead of inheriting whatever the user default holds.
    private func makeTransaction(db: Persistence.Database) throws -> EditTransaction {
        let ringDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditTransactionTests-\(UUID().uuidString)")
        return try EditTransaction(
            database: db,
            trackRepo: TrackRepository(database: db),
            artistRepo: ArtistRepository(database: db),
            albumRepo: AlbumRepository(database: db),
            coverArtRepo: CoverArtRepository(database: db),
            coverArtCache: CoverArtCache.make(database: db),
            backupRing: BackupRing(directory: ringDir),
            rootRepo: LibraryRootRepository(database: db)
        )
    }

    /// The file's modification time, for asserting that an edit left it alone.
    private func modificationDate(of url: URL) throws -> Date {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let date = attrs[.modificationDate] as? Date else {
            throw FixtureError.notFound("modification date for \(url.lastPathComponent)")
        }
        return date
    }

    /// #469: a user saw "The operation couldn't be completed. (Library.EditError
    /// error 3.)" when adding cover art. Code 3 is `.partial`, and the per-file
    /// reason inside it was itself an opaque "MetadataError error N", so the
    /// dialog could never say what went wrong. Both enums now carry their
    /// reason through `localizedDescription`.
    ///
    /// Embedding is switched on here because that is the case that still writes
    /// the file, and so still fails on a file the user cannot write (#472).
    @Test func failedArtworkSaveReportsTheFileAndReasonNotAnErrorCode() async throws {
        let db = try await makeDatabase()
        let tmp = try tempMP3()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: tmp.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tmp.path) }

        let trackID = try await insertTrack(in: db, fileURL: tmp.absoluteString)
        let tx = try makeTransaction(db: db)
        var patch = TrackTagPatch()
        patch.coverArt = .some(Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 0x42, count: 64))

        do {
            try await tx.execute(patch: patch, trackIDs: [trackID], embedCoverArt: true)
            Issue.record("embedding art into a read-only file must fail")
        } catch {
            let message = error.localizedDescription
            #expect(message.contains("1 file(s) failed"), "the wrapper names the count: \(message)")
            #expect(message.contains("read-only"), "the wrapper carries the per-file reason: \(message)")
            #expect(message.contains(tmp.lastPathComponent), "the wrapper names the file: \(message)")
            #expect(!message.contains("error 3"), "no Foundation error code: \(message)")
        }
    }

    /// #472: with embedding off the art belongs to Bòcan's cache and the rows
    /// only, so the audio file is never opened. It used to be rewritten for
    /// every track, which failed outright when the user cannot write the file.
    @Test func artOnlySaveLeavesTheFileAloneWhenEmbeddingIsOff() async throws {
        let db = try await makeDatabase()
        let tmp = try tempMP3()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: tmp.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tmp.path) }

        let (trackID, albumID) = try await insertAlbumTrack(in: db, fileURL: tmp.absoluteString)
        let before = try modificationDate(of: tmp)

        let tx = try makeTransaction(db: db)
        var patch = TrackTagPatch()
        patch.coverArt = .some(Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 0x42, count: 64))
        try await tx.execute(patch: patch, trackIDs: [trackID], embedCoverArt: false)

        let track = try await TrackRepository(database: db).fetch(id: trackID)
        #expect(track.coverArtHash != nil, "the art still reaches the track row")
        let album = try await AlbumRepository(database: db).fetch(id: albumID)
        #expect(album.coverArtHash == track.coverArtHash, "and the album the grid draws")
        let after = try modificationDate(of: tmp)
        #expect(after == before, "the audio file was never rewritten")
    }

    /// #472: a rating carries no file tag either, so it is a database-only edit.
    @Test func ratingOnlySaveLeavesTheFileAlone() async throws {
        let db = try await makeDatabase()
        let tmp = try tempMP3()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let trackID = try await insertTrack(in: db, fileURL: tmp.absoluteString)
        let before = try modificationDate(of: tmp)

        let svc = try MetadataEditService(database: db)
        var patch = TrackTagPatch()
        patch.rating = 80
        try await svc.edit(trackID: trackID, patch: patch)

        let track = try await TrackRepository(database: db).fetch(id: trackID)
        #expect(track.rating == 80)
        let after = try modificationDate(of: tmp)
        #expect(after == before, "the audio file was never rewritten")
    }

    /// #472: such an edit has no file tags to put back, so undo restores the
    /// track's hash and the album's art link instead, and still leaves the
    /// file alone.
    @Test func undoOfAnArtOnlyEditRestoresThePreviousArtRows() async throws {
        let db = try await makeDatabase()
        let tmp = try tempMP3()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let (trackID, albumID) = try await insertAlbumTrack(in: db, fileURL: tmp.absoluteString)
        let svc = try MetadataEditService(database: db)

        var first = TrackTagPatch()
        first.coverArt = .some(Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 0x42, count: 64))
        try await svc.edit(trackID: trackID, patch: first)
        let establishedTrack = try await TrackRepository(database: db).fetch(id: trackID).coverArtHash
        let establishedAlbum = try await AlbumRepository(database: db).fetch(id: albumID).coverArtHash
        #expect(establishedTrack != nil)
        let before = try modificationDate(of: tmp)

        var second = TrackTagPatch()
        second.coverArt = .some(Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 0x99, count: 64))
        let editID = try await svc.edit(trackID: trackID, patch: second)
        #expect(!editID.isEmpty, "the edit is undoable")
        let replaced = try await TrackRepository(database: db).fetch(id: trackID).coverArtHash
        #expect(replaced != establishedTrack, "the second image really landed")

        try await svc.undo(editID: editID)

        let track = try await TrackRepository(database: db).fetch(id: trackID)
        #expect(track.coverArtHash == establishedTrack, "the previous hash is back")
        let album = try await AlbumRepository(database: db).fetch(id: albumID)
        #expect(album.coverArtHash == establishedAlbum, "and the previous album link")
        let after = try modificationDate(of: tmp)
        #expect(after == before, "undo wrote no tags to the file")
    }

    @Test func partialAlbumEditNeverClobbersExistingAlbumArt() async throws {
        let db = try await makeDatabase()
        let tmpA = try tempMP3()
        let tmpB = try tempMP3()
        defer {
            try? FileManager.default.removeItem(at: tmpA)
            try? FileManager.default.removeItem(at: tmpB)
        }

        // Two-track album: editing one track is PARTIAL coverage.
        let (trackA, albumID) = try await insertAlbumTrack(in: db, fileURL: tmpA.absoluteString)
        let now = Int64(Date().timeIntervalSince1970)
        var trackB = Track(fileURL: tmpB.absoluteString, title: "B", addedAt: now, updatedAt: now)
        trackB.albumID = albumID
        _ = try await TrackRepository(database: db).insert(trackB)

        let svc = try MetadataEditService(database: db)

        // Establish album art via track A…
        var first = TrackTagPatch()
        first.coverArt = .some(Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 0x42, count: 64))
        try await svc.edit(trackID: trackA, patch: first)
        let established = try await AlbumRepository(database: db).fetch(id: albumID).coverArtHash
        #expect(established != nil)

        // …then re-edit only track A with different art. One of two tracks is
        // partial coverage, so deliberate album-level art must survive.
        var second = TrackTagPatch()
        second.coverArt = .some(Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 0x99, count: 64))
        try await svc.edit(trackID: trackA, patch: second)

        let album = try await AlbumRepository(database: db).fetch(id: albumID)
        #expect(album.coverArtHash == established)
        // The track itself carries the new art.
        let track = try await TrackRepository(database: db).fetch(id: trackA)
        #expect(track.coverArtHash != established)
    }

    @Test func fullAlbumEditReplacesAlbumArt() async throws {
        let db = try await makeDatabase()
        let tmp = try tempMP3()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Single-track album: editing that track covers the WHOLE album, e.g.
        // Get Info on the album itself — the user is changing the album's art.
        let (trackID, albumID) = try await insertAlbumTrack(in: db, fileURL: tmp.absoluteString)
        let svc = try MetadataEditService(database: db)

        var first = TrackTagPatch()
        first.coverArt = .some(Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 0x42, count: 64))
        try await svc.edit(trackID: trackID, patch: first)
        let established = try await AlbumRepository(database: db).fetch(id: albumID).coverArtHash

        var second = TrackTagPatch()
        second.coverArt = .some(Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 0x99, count: 64))
        try await svc.edit(trackID: trackID, patch: second)

        let album = try await AlbumRepository(database: db).fetch(id: albumID)
        #expect(album.coverArtHash != established)
        let track = try await TrackRepository(database: db).fetch(id: trackID)
        #expect(album.coverArtHash == track.coverArtHash)
    }

    // MARK: - Stored lyrics (Get Info merge)

    @Test func storedLyricsTextReturnsDBRows() async throws {
        let db = try await makeDatabase()
        let withRow = try await insertTrack(in: db, fileURL: "file:///tmp/a.mp3")
        let withoutRow = try await insertTrack(in: db, fileURL: "file:///tmp/b.mp3")

        let row = Lyrics(
            trackID: withRow,
            lyricsText: "Here come old flat-top",
            isSynced: false,
            source: "lrclib"
        )
        try await LyricsRepository(database: db).save(row)

        let svc = try MetadataEditService(database: db)
        let stored = await svc.storedLyricsText(ids: [withRow, withoutRow])

        #expect(stored[withRow] == "Here come old flat-top")
        #expect(stored[withoutRow] == nil)
    }
}
