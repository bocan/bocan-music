import Foundation
import GRDB

/// A soft-deleted track that a newly found file may be the same recording as.
public struct HiddenTrackCandidate: Sendable, Equatable {
    /// The track's row id.
    public let id: Int64
    /// The stored `file_url`, where the file was when the track was hidden.
    public let fileURL: String
    /// The stored size in bytes.
    public let fileSize: Int64
    /// The stored modification time.
    public let fileMtime: Int64
    /// The whole-file SHA-256, when the background pass had reached the track.
    public let contentHash: String?

    public init(id: Int64, fileURL: String, fileSize: Int64, fileMtime: Int64, contentHash: String?) {
        self.id = id
        self.fileURL = fileURL
        self.fileSize = fileSize
        self.fileMtime = fileMtime
        self.contentHash = contentHash
    }
}

/// Re-linking a soft-deleted track to a file found at a new path (#647).
///
/// The library knows a file by its path, so a library moved to a new drive or
/// folder arrives as new tracks, and the play counts, ratings, playlist
/// entries and history stay on the hidden rows. Pointing the hidden row at the
/// new path keeps the row id, and with it everything that refers to the track.
public extension TrackRepository {
    /// Every soft-deleted track, as a re-link candidate. For a whole scan,
    /// which reads the list once and not once per file.
    func hiddenTrackCandidates() async throws -> [HiddenTrackCandidate] {
        try await self.database.read { db in
            try Self.candidates(db, where: "disabled = 1", arguments: [])
        }
    }

    /// The soft-deleted tracks whose file was `fileSize` bytes.
    func hiddenTrackCandidates(fileSize: Int64) async throws -> [HiddenTrackCandidate] {
        try await self.database.read { db in
            try Self.candidates(db, where: "disabled = 1 AND file_size = ?", arguments: [fileSize])
        }
    }

    /// Points the soft-deleted track `id` at the file `fileURL` and shows it
    /// again. Returns `false`, and changes nothing, when the track is no
    /// longer hidden: another file took it first, or it came back by itself.
    ///
    /// The tags, the listener's state and the content hash stay as they were;
    /// the import that follows refreshes what the file itself decides. The
    /// bookmark is cleared, because the old one names the old place: the
    /// import mints one for a row that has none.
    ///
    /// - Parameters:
    ///   - fileURL: The new `file_url`, as `URL.absoluteString` gives it.
    ///   - pathDisplay: The new plain path, for display.
    ///   - fileMtime: The new file's modification time. The caller has
    ///     established that the bytes are the same, so a different time on
    ///     the copy must not read as a changed file.
    func relinkHiddenTrack(
        id: Int64,
        toFileURL fileURL: String,
        pathDisplay: String,
        fileMtime: Int64
    ) async throws -> Bool {
        let normalised = fileURL.precomposedStringWithCanonicalMapping
        let changed: Int = try await self.database.write { db in
            try db.execute(
                sql: """
                UPDATE tracks
                SET file_url = ?, file_path_display = ?, file_bookmark = NULL, file_mtime = ?, disabled = 0
                WHERE id = ? AND disabled = 1
                """,
                arguments: [normalised, pathDisplay, fileMtime, id]
            )
            return db.changesCount
        }
        if changed == 1 {
            self.log.info("track.relinked", ["id": id])
        }
        return changed == 1
    }

    private static func candidates(
        _ db: GRDB.Database,
        where condition: String,
        arguments: StatementArguments
    ) throws -> [HiddenTrackCandidate] {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT id, file_url, file_size, file_mtime, content_hash FROM tracks WHERE \(condition) ORDER BY id",
            arguments: arguments
        )
        return rows.map { row in
            HiddenTrackCandidate(
                id: row["id"],
                fileURL: row["file_url"],
                fileSize: row["file_size"],
                fileMtime: row["file_mtime"],
                contentHash: row["content_hash"]
            )
        }
    }
}
