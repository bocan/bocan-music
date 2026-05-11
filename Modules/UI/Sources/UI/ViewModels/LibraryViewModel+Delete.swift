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

        // Single reload for the whole batch.
        await self.tracks.load()
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
            await self.tracks.load()
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
            await self.tracks.load()
            self.log.debug("library.permanentlyDeleteFromDisk", ["id": id])
        } catch {
            self.log.error(
                "library.permanentlyDeleteFromDisk.failed",
                ["id": id, "error": String(reflecting: error)]
            )
            self.playbackErrorMessage = "Could not permanently delete the file: \(error.localizedDescription)"
        }
    }
}
