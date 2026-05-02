import Foundation
import Metadata
import Observability
import Persistence

// MARK: - MetadataEditService

/// Actor-isolated orchestrator for all tag-editing operations.
///
/// Wires together `EditTransaction`, `BackupRing`, and the persistence layer.
/// UI view models call into this service; it never touches SwiftUI state.
public actor MetadataEditService {
    // MARK: - Dependencies

    private let database: Persistence.Database
    private let trackRepo: TrackRepository
    private let artistRepo: ArtistRepository
    private let albumRepo: AlbumRepository
    private let rootRepo: LibraryRootRepository
    private let backupRing: BackupRing
    private let coverArtCache: CoverArtCache
    private let log = AppLogger.make(.library)

    // MARK: - Init

    public init(database: Persistence.Database) throws {
        self.database = database
        self.trackRepo = TrackRepository(database: database)
        self.artistRepo = ArtistRepository(database: database)
        self.albumRepo = AlbumRepository(database: database)
        self.rootRepo = LibraryRootRepository(database: database)
        self.coverArtCache = CoverArtCache.make(database: database)
        let ringDir = Self.backupRingDirectory()
        self.backupRing = try BackupRing(directory: ringDir)
    }

    // MARK: - Public API

    /// Applies `patch` to the single track `trackID`.
    ///
    /// - Returns: the edit ID for later undo.
    @discardableResult
    public func edit(trackID: Int64, patch: TrackTagPatch) async throws -> String {
        try await self.edit(trackIDs: [trackID], patch: patch)
    }

    /// Applies `patch` to all tracks in `trackIDs` (multi-edit).
    ///
    /// - Returns: the edit ID for later undo.
    @discardableResult
    public func edit(
        trackIDs: [Int64],
        patch: TrackTagPatch,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> String {
        guard !patch.isEmpty else { return "" }

        let coverArtRepo = CoverArtRepository(database: self.database)
        let tx = EditTransaction(
            database: self.database,
            trackRepo: self.trackRepo,
            artistRepo: self.artistRepo,
            albumRepo: self.albumRepo,
            coverArtRepo: coverArtRepo,
            coverArtCache: self.coverArtCache,
            backupRing: self.backupRing,
            rootRepo: self.rootRepo
        )

        self.log.debug("edit.start", ["count": trackIDs.count])
        let start = Date()

        let embedCoverArt = UserDefaults.standard.bool(forKey: "metadata.embedCoverArt")
        try await tx.execute(patch: patch, trackIDs: trackIDs, embedCoverArt: embedCoverArt, onProgress: onProgress)

        let ms = Int(Date().timeIntervalSince(start) * 1000)
        self.log.debug("edit.end", ["count": trackIDs.count, "ms": ms])

        // Return the most-recent backup editID for the first track
        if let firstID = trackIDs.first,
           let track = try? await self.trackRepo.fetch(id: firstID),
           let entry = try? await self.backupRing.lastEntry(forFileURL: track.fileURL) {
            return entry.editID
        }
        return ""
    }

    /// Undoes the edit identified by `editID`.
    ///
    /// Restores the original tags to the file and re-saves the DB row.
    public func undo(editID: String) async throws {
        guard let entry = try await self.backupRing.load(editID: editID) else {
            self.log.warning("undo.not_found", ["editID": editID])
            return
        }

        guard let url = URL(string: entry.fileURL) else {
            throw EditError.fileWriteFailed(
                URL(fileURLWithPath: entry.fileURL), "Invalid file URL"
            )
        }

        // Restore original tags to the file
        let originalTags = entry.originalTags.toTrackTags()
        try await Task.detached(priority: .userInitiated) {
            try TagWriter().write(originalTags, to: url)
        }.value

        // Update DB: clear userEdited flag since we're reverting to pre-edit state
        if let track = try? await self.trackRepo.fetchOne(fileURL: entry.fileURL) {
            var reverted = track
            reverted.userEdited = false
            reverted.updatedAt = Int64(Date().timeIntervalSince1970)
            try await self.trackRepo.update(reverted)
        }

        await self.backupRing.delete(editID: editID)
        self.log.debug("undo.complete", ["editID": editID])
    }

    /// Fetches the `Track` database records for `ids` (skips any not found).
    public func readTracks(ids: [Int64]) async throws -> [Track] {
        var tracks: [Track] = []
        for id in ids {
            if let track = try? await self.trackRepo.fetch(id: id) {
                tracks.append(track)
            }
        }
        return tracks
    }

    /// Reads the current `TrackTags` from disk for `trackID`.
    public func readTags(trackID: Int64) async throws -> TrackTags {
        let track = try await self.trackRepo.fetch(id: trackID)
        guard let url = URL(string: track.fileURL) else {
            throw EditError.trackNotFound(trackID)
        }
        // Use the per-file security-scoped bookmark when available so that
        // the sandboxed process can open the file outside its container.
        if let bookmarkData = track.fileBookmark {
            return try await SecurityScope.withAccess(bookmarkData) { scopedURL in
                try await Task.detached(priority: .userInitiated) {
                    try TagReader().read(from: scopedURL)
                }.value
            }
        }
        return try await Task.detached(priority: .userInitiated) {
            try TagReader().read(from: url)
        }.value
    }

    // MARK: - Conflict resolution

    /// Clears the `needs_conflict_review` flag for `trackID` (user chose "Keep My Edits").
    /// The track remains `user_edited = 1`; the disk change is acknowledged but discarded.
    public func clearConflictFlag(trackID: Int64) async throws {
        var track = try await self.trackRepo.fetch(id: trackID)
        guard track.needsConflictReview else { return }
        track.needsConflictReview = false
        try await self.trackRepo.update(track)
        self.log.debug("conflict.cleared", ["trackID": trackID])
    }

    /// Clears both `user_edited` and `needs_conflict_review` for `trackID` (user chose
    /// "Take Disk Version"). On the next library scan the track tags will be re-imported
    /// from disk, overwriting any stored user edits.
    public func acceptDiskVersion(trackID: Int64) async throws {
        var track = try await self.trackRepo.fetch(id: trackID)
        track.needsConflictReview = false
        track.userEdited = false
        try await self.trackRepo.update(track)
        self.log.debug("conflict.accepted_disk", ["trackID": trackID])
    }

    // MARK: - Helpers

    private static func backupRingDirectory() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Bocan", isDirectory: true)
            .appendingPathComponent("EditBackups", isDirectory: true)
    }
}
