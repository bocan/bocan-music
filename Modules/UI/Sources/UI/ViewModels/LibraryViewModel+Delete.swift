import Foundation
import Observability
import Persistence

// MARK: - File-deletion injection

/// Abstraction over the two on-disk deletion modes used by ``LibraryViewModel``
/// when removing a track's backing file. Lives behind a protocol so tests can
/// inject failure modes (e.g. simulate `trashItem` failing on an external
/// volume) without touching the real file system.
public protocol TrackFileDeleter: Sendable {
    /// Move the file to the user's Trash. Throws on failure.
    func trash(_ url: URL) throws
    /// Permanently delete the file. Throws on failure.
    func remove(_ url: URL) throws
}

/// Default ``TrackFileDeleter`` backed by `FileManager.default`.
public struct SystemTrackFileDeleter: TrackFileDeleter {
    public init() {}
    public func trash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    public func remove(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

/// Result of ``LibraryViewModel/deleteTrackFromDisk(id:using:)``.
public enum DeleteFromDiskOutcome: Sendable {
    /// File was moved to Trash and the DB row soft-deleted.
    case trashed
    /// `trashItem` failed (external volume, permission denied, …). The DB row
    /// is unchanged. The caller should offer a "Delete Permanently"
    /// confirmation and, on confirm, call
    /// ``LibraryViewModel/permanentlyDeleteTrackFromDisk(id:using:)``.
    case trashFailed(error: any Error, fileURL: URL)
    /// Some other step failed (DB fetch, DB update, …). The DB row is
    /// unchanged and an error sheet has already been surfaced.
    case failed(error: any Error)
}

// MARK: - LibraryViewModel + Delete

/// Disk-deletion actions for ``LibraryViewModel``.
public extension LibraryViewModel {
    /// Moves multiple tracks' backing files to Trash and soft-deletes their
    /// library rows in one pass, calling `tracks.load()` exactly once at the end.
    ///
    /// Returns an array of `(track, error)` pairs for any files that could not
    /// be trashed, so the caller can offer a secondary "Delete Permanently"
    /// confirmation for each failure.
    func deleteTracksFromDisk(
        tracks: [Track],
        using fileOps: any TrackFileDeleter = SystemTrackFileDeleter()
    ) async -> [(Track, any Error)] {
        let trackRepo = TrackRepository(database: self.database)
        var failures: [(Track, any Error)] = []

        for track in tracks {
            guard let id = track.id else { continue }
            do {
                var row = try await trackRepo.fetch(id: id)
                if let url = URL(string: row.fileURL) {
                    do {
                        try fileOps.trash(url)
                    } catch {
                        self.log.error(
                            "library.deleteFromDisk.trashFailed",
                            ["id": id, "error": String(reflecting: error)]
                        )
                        failures.append((track, error))
                        continue
                    }
                }
                row.disabled = true
                try await trackRepo.update(row)
                self.log.debug("library.deleteFromDisk", ["id": id])
            } catch {
                self.log.error("library.deleteFromDisk.failed", ["id": id, "error": String(reflecting: error)])
            }
        }

        // Single reload for the whole batch, preserving any active search.
        await self.pruneOrphanAlbumsAndArtists()
        await self.loadCurrentDestination()
        return failures
    }

    /// Moves a track's backing file to Trash and soft-deletes the library row.
    ///
    /// Returns an outcome so the caller can offer a secondary "Delete
    /// Permanently" confirmation when trashing fails (e.g. external volume,
    /// permission denied). On a trash failure the database row is **not**
    /// touched — the soft-delete only happens after the file has actually
    /// left its original location.
    @discardableResult
    func deleteTrackFromDisk(
        id: Int64,
        using fileOps: any TrackFileDeleter = SystemTrackFileDeleter()
    ) async -> DeleteFromDiskOutcome {
        let trackRepo = TrackRepository(database: self.database)
        do {
            var track = try await trackRepo.fetch(id: id)
            if let url = URL(string: track.fileURL) {
                do {
                    try fileOps.trash(url)
                } catch {
                    self.log.error(
                        "library.deleteFromDisk.trashFailed",
                        ["id": id, "error": String(reflecting: error)]
                    )
                    return .trashFailed(error: error, fileURL: url)
                }
            }
            track.disabled = true
            try await trackRepo.update(track)
            await self.pruneOrphanAlbumsAndArtists()
            await self.loadCurrentDestination()
            self.log.debug("library.deleteFromDisk", ["id": id])
            return .trashed
        } catch {
            self.log.error("library.deleteFromDisk.failed", ["id": id, "error": String(reflecting: error)])
            self.playbackErrorMessage = "Could not delete the file from disk: \(error.localizedDescription)"
            return .failed(error: error)
        }
    }

    /// Permanently deletes a track's backing file (no Trash) and soft-deletes
    /// the library row. Used as the fallback after `deleteTrackFromDisk` reports
    /// a `.trashFailed` outcome and the user has explicitly confirmed permanent
    /// deletion. The DB row is only updated if the file removal succeeds.
    func permanentlyDeleteTrackFromDisk(
        id: Int64,
        using fileOps: any TrackFileDeleter = SystemTrackFileDeleter()
    ) async {
        let trackRepo = TrackRepository(database: self.database)
        do {
            var track = try await trackRepo.fetch(id: id)
            guard let url = URL(string: track.fileURL) else {
                self.playbackErrorMessage = "Could not delete: the file path is invalid."
                return
            }
            try fileOps.remove(url)
            track.disabled = true
            try await trackRepo.update(track)
            await self.pruneOrphanAlbumsAndArtists()
            await self.loadCurrentDestination()
            self.log.debug("library.permanentlyDeleteFromDisk", ["id": id])
        } catch {
            self.log.error(
                "library.permanentlyDeleteFromDisk.failed",
                ["id": id, "error": String(reflecting: error)]
            )
            self.playbackErrorMessage = "Could not permanently delete the file: \(error.localizedDescription)"
        }
    }

    // MARK: - Remove from Library (soft-delete by album / artist)

    /// Soft-deletes every track in the given albums and prunes orphan metadata rows.
    func removeAlbumsFromLibrary(albumIDs: [Int64]) async {
        let trackRepo = TrackRepository(database: self.database)
        for albumID in albumIDs {
            do {
                let albumTracks = try await trackRepo.fetchAll(albumID: albumID)
                for var track in albumTracks {
                    track.disabled = true
                    try await trackRepo.update(track)
                }
                self.log.debug("library.removeAlbum", ["albumID": albumID])
            } catch {
                self.log.error("library.removeAlbum.failed", ["albumID": albumID, "error": String(reflecting: error)])
            }
        }
        await self.pruneOrphanAlbumsAndArtists()
        await self.albums.load()
        await self.loadCurrentDestination()
    }

    /// Soft-deletes every track by this artist and prunes orphan metadata rows.
    func removeArtistFromLibrary(artistID: Int64) async {
        let trackRepo = TrackRepository(database: self.database)
        do {
            let artistTracks = try await trackRepo.fetchAll(artistID: artistID)
            for var track in artistTracks {
                track.disabled = true
                try await trackRepo.update(track)
            }
            self.log.debug("library.removeArtist", ["artistID": artistID])
        } catch {
            self.log.error("library.removeArtist.failed", ["artistID": artistID, "error": String(reflecting: error)])
        }
        await self.pruneOrphanAlbumsAndArtists()
        await self.artists.load()
        await self.loadCurrentDestination()
    }

    // MARK: - Private helpers

    /// Removes album and artist rows that have no remaining active (non-disabled) tracks.
    private func pruneOrphanAlbumsAndArtists() async {
        do {
            let (prunedAlbums, prunedArtists): (Int, Int) = try await self.database.write { db in
                try db.execute(sql: """
                DELETE FROM albums
                WHERE id NOT IN (
                    SELECT DISTINCT album_id FROM tracks
                    WHERE album_id IS NOT NULL
                      AND (disabled IS NULL OR disabled = 0)
                )
                """)
                let albums = db.changesCount
                try db.execute(sql: """
                DELETE FROM artists
                WHERE id NOT IN (
                    SELECT DISTINCT artist_id FROM tracks
                    WHERE artist_id IS NOT NULL
                      AND (disabled IS NULL OR disabled = 0)
                    UNION
                    SELECT DISTINCT album_artist_id FROM tracks
                    WHERE album_artist_id IS NOT NULL
                      AND (disabled IS NULL OR disabled = 0)
                    UNION
                    SELECT DISTINCT album_artist_id FROM albums
                    WHERE album_artist_id IS NOT NULL
                )
                """)
                let artists = db.changesCount
                return (albums, artists)
            }
            self.log.debug("library.pruneOrphans", ["albums": prunedAlbums, "artists": prunedArtists])
        } catch {
            self.log.error("library.pruneOrphans.failed", ["error": String(reflecting: error)])
        }
    }
}
