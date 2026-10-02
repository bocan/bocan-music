import Foundation
import Metadata
import Observability
import Persistence

// MARK: - Per-file phase

extension EditTransaction {
    func processOneTrack(
        trackID: Int64,
        patch: TrackTagPatch,
        embedCoverArt: Bool
    ) async throws -> (track: Track, coverArtHash: String?) {
        // 1. Fetch DB row
        let track = try await self.trackRepo.fetch(id: trackID)
        guard let fileURL = URL(string: track.fileURL) else {
            throw EditError.fileWriteFailed(
                URL(fileURLWithPath: track.fileURL),
                "Invalid file URL"
            )
        }

        // A patch that changes no tag inside the audio file has nothing to
        // write there: cover art with embedding off goes to Bòcan's cache and
        // the rows, and the rating and shuffle flags never leave the database.
        // Rewriting the file anyway cost a backup, a full TagLib rewrite and a
        // watcher conflict for every track, and failed outright on a file the
        // user cannot write (#472).
        guard Self.needsFileWrite(patch: patch, embedCoverArt: embedCoverArt) else {
            return try await self.applyWithoutFileWrite(track: track, patch: patch)
        }

        // Start the root-folder security scope so TagReader / TagWriter can
        // access this file and create temp siblings in the same directory.
        // The scope must remain active for the entire read-write-verify cycle.
        // The handle's `deinit` releases the scope when this function returns.
        let rootScope = try await self.acquireRootScope(for: track.fileURL)

        // Fallback: if no folder root covers this file (e.g. it was added via
        // "Add Files…" as an individual root), activate its per-file bookmark.
        // This grants the sandbox read+write access to the specific file so that
        // TagReader/TagWriter can open it and FileManager can replace it.
        var perFileURL: URL?
        if rootScope == nil, let bookmark = track.fileBookmark {
            perFileURL = self.startPerFileScope(bookmark: bookmark, track: track)
        }

        defer {
            // `rootScope` releases automatically via `deinit`; only the
            // per-file fallback URL needs a manual stop.
            perFileURL?.stopAccessingSecurityScopedResource()
            _ = rootScope // keep alive until end of function
        }

        try await self.rewriteFileTags(at: fileURL, track: track, patch: patch, embedCoverArt: embedCoverArt)

        // 7. Handle cover art
        let coverArtHash = try await self.patchedCoverArtHash(for: track, patch: patch)

        // 8. Build updated Track record, normalising artist/album FKs when changed.
        var updated = patch.applying(to: track)
        updated.userEdited = true

        self.stampFileFacts(on: &updated, fileURL: fileURL)

        if patch.artist != nil || patch.albumArtist != nil || patch.album != nil {
            updated = try await self.relinkArtistAndAlbum(updated, track: track, patch: patch)
        }

        return (updated, coverArtHash)
    }

    /// Steps 2 to 6 of the file phase: read the tags, back them up, apply the
    /// patch, write the file and read it back. The caller holds the security
    /// scope for the whole call.
    private func rewriteFileTags(
        at fileURL: URL,
        track: Track,
        patch: TrackTagPatch,
        embedCoverArt: Bool
    ) async throws {
        // 2. Read current tags from file
        let currentTags = try await Task.detached(priority: .userInitiated) {
            try TagReader().read(from: fileURL)
        }.value

        // 3. Back up original tags
        let snapshot = TagsSnapshot(from: currentTags)
        try await self.backupRing.save(fileURL: track.fileURL, tags: snapshot)

        // 4. Build the new tags by applying the patch
        var newTags = currentTags
        Self.applyPatch(patch, to: &newTags)

        // 4b. If embedding is enabled, include the patched cover art bytes in the
        //     file tags so TagWriter writes them into the audio file.
        if embedCoverArt, let artPatch = patch.coverArt {
            if let artData = artPatch {
                let rawArts = [
                    RawCoverArt(
                        data: artData,
                        mimeType: Self.mimeType(for: artData),
                        pictureType: 3 // APIC type 3 = front cover
                    ),
                ]
                newTags.coverArt = CoverArtExtractor.extract(from: rawArts)
            } else {
                // Patch explicitly clears the art → remove from file as well.
                newTags.coverArt = []
            }
        }

        // 5. Write file atomically
        try await Task.detached(priority: .userInitiated) {
            try TagWriter().write(newTags, to: fileURL)
        }.value

        // 6. Re-read to confirm persistence
        let verified = try await Task.detached(priority: .userInitiated) {
            try TagReader().read(from: fileURL)
        }.value
        _ = verified // read confirmed; we use the patch-applied track for the DB update
    }

    /// The cover art hash the track row must carry after the edit: the cached
    /// hash of the patched image, `nil` when the patch clears the art, or the
    /// track's current hash when the patch leaves the art alone.
    private func patchedCoverArtHash(for track: Track, patch: TrackTagPatch) async throws -> String? {
        var coverArtHash: String? = track.coverArtHash
        if let artPatch = patch.coverArt {
            if let artData = artPatch {
                let extracted = CoverArtExtractor.extract(from: [
                    RawCoverArt(data: artData, mimeType: Self.mimeType(for: artData), pictureType: 3),
                ])
                if let persisted = try await self.coverArtCache.persist(extracted, source: "user") {
                    coverArtHash = persisted.hash
                }
            } else {
                coverArtHash = nil // cleared
            }
        }
        return coverArtHash
    }

    /// Points the edited row at the artist and album the patch names, creating
    /// them when needed, and returns the row with the new foreign keys.
    private func relinkArtistAndAlbum(
        _ edited: Track,
        track: Track,
        patch: TrackTagPatch
    ) async throws -> Track {
        var updated = edited
        // Fallback values for the edit. A failed read is not the same as
        // "the track had no album or artist", which is how it used to
        // read, so each one is logged (#492).
        let currentAlbum = await self.albumOrNil(track.albumID, context: "currentAlbum")
        let currentAlbumArtist = await self.artistOrNil(currentAlbum?.albumArtistID, context: "currentAlbumArtist")
        let currentTrackArtist = await self.artistOrNil(track.artistID, context: "currentTrackArtist")

        // Resolve track-artist FK.
        let artistName: String = if let patched = patch.artist {
            patched ?? "Unknown Artist"
        } else {
            currentTrackArtist?.name ?? "Unknown Artist"
        }
        let artist = try await self.artistRepo.findOrCreate(
            name: artistName,
            sortName: patch.sortArtist.flatMap(\.self),
            musicbrainzID: patch.musicbrainzArtistID.flatMap(\.self)
        )
        updated.artistID = artist.id

        // Resolve album-artist (may differ from track artist).
        let albumArtistName: String = if let patched = patch.albumArtist {
            patched ?? artistName
        } else {
            currentAlbumArtist?.name ?? artistName
        }
        let albumArtist = albumArtistName == artistName
            ? artist
            : try await self.artistRepo.findOrCreate(
                name: albumArtistName,
                sortName: patch.sortAlbumArtist.flatMap(\.self),
                musicbrainzID: patch.musicbrainzAlbumArtistID.flatMap(\.self)
            )

        // Resolve album FK.
        let albumTitle: String = if let patched = patch.album {
            patched ?? "Unknown Album"
        } else {
            currentAlbum?.title ?? "Unknown Album"
        }
        let album = try await self.albumRepo.findOrCreate(title: albumTitle, albumArtistID: albumArtist.id)
        updated.albumID = album.id

        // Propagate the edited year to the album row when the patch
        // explicitly includes a year change (outer optional non-nil means
        // the field was deliberately patched; inner optional nil means
        // the user cleared the year).
        if let newYear = patch.year, let albumID = album.id {
            try await self.albumRepo.setYear(albumID: albumID, year: newYear)
        }
        return updated
    }

    /// Whether `patch` has anything to write into the audio file: a tag the
    /// file carries, or cover art while the user has embedding switched on.
    private static func needsFileWrite(patch: TrackTagPatch, embedCoverArt: Bool) -> Bool {
        patch.touchesFileTags || (embedCoverArt && patch.coverArt != nil)
    }

    /// Applies a patch that touches no file tag: the art is cached, the row
    /// carries the change, and the audio file is never opened (#472).
    ///
    /// The backup entry records the art rows rather than the file's tags, so
    /// undo restores the previous hash and album link.
    private func applyWithoutFileWrite(
        track: Track,
        patch: TrackTagPatch
    ) async throws -> (track: Track, coverArtHash: String?) {
        var coverArtHash: String? = track.coverArtHash
        if let artPatch = patch.coverArt {
            if let artData = artPatch {
                let extracted = CoverArtExtractor.extract(from: [
                    RawCoverArt(data: artData, mimeType: Self.mimeType(for: artData), pictureType: 3),
                ])
                if let persisted = try await self.coverArtCache.persist(extracted, source: "user") {
                    coverArtHash = persisted.hash
                }
            } else {
                coverArtHash = nil // cleared
            }
        }

        try await self.backupRing.save(
            fileURL: track.fileURL,
            tags: nil,
            databaseOnly: self.artRestorePoint(for: track)
        )

        var updated = patch.applying(to: track)
        updated.userEdited = true
        self.log.debug("edit.track.databaseOnly", ["id": track.id ?? -1])
        return (updated, coverArtHash)
    }

    /// The cover-art rows as they stand before a database-only edit, so undo
    /// can put them back (#472).
    private func artRestorePoint(for track: Track) async -> BackupRing.DatabaseOnlyRestore {
        var album: Album?
        if let albumID = track.albumID {
            album = await self.albumOrNil(albumID, context: "artRestorePoint")
        }
        return BackupRing.DatabaseOnlyRestore(
            trackCoverArtHash: track.coverArtHash,
            albumID: track.albumID,
            albumCoverArtHash: album?.coverArtHash,
            albumCoverArtPath: album?.coverArtPath
        )
    }
}
