import Foundation
import GRDB
import Metadata
import Observability
import Persistence

// MARK: - EditTransaction

/// Executes an atomic metadata edit: file write → DB update.
///
/// For a batch of N tracks:
/// 1. Back up each track's current tags into the `BackupRing`.
/// 2. Write new tags to the file (copy → write → fsync → rename).
/// 3. Re-read the file to confirm persistence.
/// 4. Update all DB rows in a single database transaction.
/// 5. On any per-file failure, restore that file from the backup.
///
/// The DB transaction rolls back automatically if the `database.write` closure
/// throws, so file and DB stay in sync on success.
actor EditTransaction {
    // MARK: - Dependencies

    // The per-file phase lives in `EditTransaction+TrackPhase.swift`, so the
    // dependencies it uses are internal rather than private.
    private let database: Persistence.Database
    let trackRepo: TrackRepository
    let artistRepo: ArtistRepository
    let albumRepo: AlbumRepository
    private let coverArtRepo: CoverArtRepository
    let coverArtCache: CoverArtCache
    let backupRing: BackupRing
    private let rootRepo: LibraryRootRepository
    private let writer: TagWriter
    private let reader: TagReader
    let log = AppLogger.make(.library)

    // MARK: - Init

    init(
        database: Persistence.Database,
        trackRepo: TrackRepository,
        artistRepo: ArtistRepository,
        albumRepo: AlbumRepository,
        coverArtRepo: CoverArtRepository,
        coverArtCache: CoverArtCache,
        backupRing: BackupRing,
        rootRepo: LibraryRootRepository
    ) {
        self.database = database
        self.trackRepo = trackRepo
        self.artistRepo = artistRepo
        self.albumRepo = albumRepo
        self.coverArtRepo = coverArtRepo
        self.coverArtCache = coverArtCache
        self.backupRing = backupRing
        self.rootRepo = rootRepo
        self.writer = TagWriter()
        self.reader = TagReader()
    }

    // MARK: - Execute

    /// Applies `patch` to every track in `trackIDs`.
    ///
    /// - Parameter embedCoverArt: When `true`, cover art changes are written
    ///   directly into the audio file bytes in addition to the app cache.
    /// - Parameter onProgress: Called after each file completes (0-based index, total count).
    /// - Throws: `EditError.partial` if some but not all files succeeded.
    func execute(
        patch: TrackTagPatch,
        trackIDs: [Int64],
        embedCoverArt: Bool = false,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws {
        guard !patch.isEmpty else { return }

        var errors: [Int64: String] = [:]
        var successfulUpdates: [(track: Track, coverArtHash: String?)] = []

        // --- Per-file phase ---
        for (idx, trackID) in trackIDs.enumerated() {
            try Task.checkCancellation()
            do {
                let result = try await self.processOneTrack(
                    trackID: trackID,
                    patch: patch,
                    embedCoverArt: embedCoverArt
                )
                successfulUpdates.append(result)
            } catch {
                self.log.error("edit.track.failed", ["id": trackID, "error": String(reflecting: error)])
                errors[trackID] = error.localizedDescription
            }
            onProgress?(idx, trackIDs.count)
        }

        // --- DB phase: write all successful updates in one transaction ---
        if !successfulUpdates.isEmpty {
            let updates = successfulUpdates // let-copy for Sendable capture
            try await self.commit(updates, patch: patch)
            self.log.debug("edit.committed", ["count": successfulUpdates.count])

            // Link patched cover art to the affected albums. The track list's
            // leading thumbnail renders the ALBUM's art, not the track's —
            // without this, saved art shows on the play bar (which reads the
            // track) but never in the list or the albums grid.
            if case let .some(.some(artData)) = patch.coverArt {
                try await self.linkAlbumArt(artData: artData, updates: updates.map(\.track))
            }
        }

        try await self.rollUpAlbums(patch: patch, successfulUpdates: successfulUpdates)

        if !errors.isEmpty {
            throw EditError.partial(errors)
        }
    }

    /// Writes every successful update, and the lyrics row that goes with it,
    /// in one database transaction.
    private func commit(_ updates: [(track: Track, coverArtHash: String?)], patch: TrackTagPatch) async throws {
        try await self.database.write { db in
            for (track, coverHash) in updates {
                var mutable = track
                if let hash = coverHash {
                    mutable.coverArtHash = hash
                }
                try mutable.update(db)

                // Keep the lyrics table in sync with the edited text so
                // ADR-015 (lyrics display) sees the updated isSynced flag
                // immediately, without waiting for the next rescan.
                if let trackID = mutable.id {
                    try Self.syncLyricsRow(trackID: trackID, patch: patch, db: db)
                }
            }
        }
    }

    /// Saves or deletes the lyrics row of `trackID` to match the patch. A
    /// patch that touches no lyrics field leaves the row alone.
    private static func syncLyricsRow(trackID: Int64, patch: TrackTagPatch, db: GRDB.Database) throws {
        if let text = patch.syncedLyrics {
            // nil text means "clear synced lyrics"
            if let lyricsText = text {
                let row = Lyrics(
                    trackID: trackID,
                    lyricsText: lyricsText,
                    isSynced: true,
                    source: "user"
                )
                try row.save(db)
            } else {
                try db.execute(
                    sql: "DELETE FROM lyrics WHERE track_id = ?",
                    arguments: [trackID]
                )
            }
        } else if let text = patch.lyrics {
            // nil text means "clear plain lyrics"
            if let lyricsText = text {
                let row = Lyrics(
                    trackID: trackID,
                    lyricsText: lyricsText,
                    isSynced: false,
                    source: "user"
                )
                try row.save(db)
            } else {
                try db.execute(
                    sql: "DELETE FROM lyrics WHERE track_id = ?",
                    arguments: [trackID]
                )
            }
        }
    }

    /// Roll totals (#404) and MusicBrainz IDs (#402) up to every album
    /// touched when the edit changed one of them or moved tracks between
    /// albums. The identify flow lands here too via MetadataEditService.
    private func rollUpAlbums(
        patch: TrackTagPatch,
        successfulUpdates: [(track: Track, coverArtHash: String?)]
    ) async throws {
        let regrouped = patch.album != nil || patch.albumArtist != nil
        let totalsChanged = patch.trackTotal != nil || patch.discTotal != nil
        let mbidsChanged = patch.musicbrainzReleaseID != nil || patch.musicbrainzReleaseGroupID != nil
        if !successfulUpdates.isEmpty, regrouped || totalsChanged || mbidsChanged {
            let albumIDs = Set(successfulUpdates.compactMap(\.track.albumID))
            for albumID in albumIDs {
                if regrouped || totalsChanged {
                    try await self.albumRepo.recomputeTotals(albumID: albumID)
                }
                if regrouped || mbidsChanged {
                    try await self.albumRepo.recomputeMusicBrainzIDs(albumID: albumID)
                }
            }
        }
    }

    /// Album-art semantics for a batch edit:
    /// - The batch covers **every** track of an album (e.g. Get Info on the
    ///   album itself) → the user is editing the album's art: **replace** it.
    /// - Partial coverage (fixing one track of many) → fill a **missing**
    ///   album link only; never hijack deliberate album-level art.
    /// Throws when the art cannot be cached: the user asked for this image, the
    /// edit reported success, and swallowing the failure left the art nowhere
    /// the album could show it (#481).
    private func linkAlbumArt(artData: Data, updates: [Track]) async throws {
        let extracted = CoverArtExtractor.extract(from: [
            RawCoverArt(data: artData, mimeType: Self.mimeType(for: artData), pictureType: 3),
        ])
        // persist() is idempotent (content-hash keyed); reuse from step 7 is free.
        let persisted = try await self.coverArtCache.persist(extracted, source: "user")
        // nil means the bytes held no usable image, so there is nothing to link.
        guard let persisted else { return }

        var touchedByAlbum: [Int64: Int] = [:]
        for track in updates {
            if let albumID = track.albumID {
                touchedByAlbum[albumID, default: 0] += 1
            }
        }

        for (albumID, touched) in touchedByAlbum {
            let album: Album
            do {
                album = try await self.albumRepo.fetch(id: albumID)
            } catch {
                // The art reaches the tracks but not the album the grid and
                // the track list actually draw from (#492).
                self.log.warning("edit.albumArt.albumLookupFailed", [
                    "album": albumID,
                    "error": String(reflecting: error),
                ])
                continue
            }
            // A failed count keeps the old meaning: assume partial coverage,
            // so deliberate album art is never hijacked.
            var total = Int.max
            do {
                total = try await self.trackRepo.count(albumID: albumID)
            } catch {
                self.log.warning("edit.albumArt.countFailed", [
                    "album": albumID,
                    "error": String(reflecting: error),
                ])
            }
            let coversWholeAlbum = touched >= total
            let albumHasNoArt = album.coverArtPath == nil || album.coverArtHash == nil
            guard coversWholeAlbum || albumHasNoArt else { continue }
            do {
                try await self.albumRepo.setCoverArt(
                    albumID: albumID,
                    hash: persisted.hash,
                    path: persisted.path
                )
            } catch {
                self.log.error("edit.albumArt.link_failed", ["album": albumID, "error": String(reflecting: error)])
            }
        }
    }

    // MARK: - Per-file phase support

    // The methods below are internal rather than private: the per-file phase
    // in `EditTransaction+TrackPhase.swift` calls them.

    /// 8a. Stamp the DB row with the file's post-write mtime/size so the
    ///     next scan sees them as identical and does NOT raise a false-positive
    ///     "file changed after your last edit" conflict.
    func stampFileFacts(on updated: inout Track, fileURL: URL) {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            if let modDate = attrs[.modificationDate] as? Date {
                updated.fileMtime = Int64(modDate.timeIntervalSince1970)
            }
            if let sz = attrs[.size] as? Int {
                updated.fileSize = Int64(sz)
            }
        } catch {
            // Without this stamp the next scan sees a changed file and raises
            // a false "changed since your last edit" conflict (#492).
            self.log.warning("edit.mtimeStamp.failed", [
                "file": fileURL.lastPathComponent,
                "error": String(reflecting: error),
            ])
        }
    }

    /// The album row, or nil with a log line rather than silence (#492).
    func albumOrNil(_ id: Int64?, context: String) async -> Album? {
        guard let id else { return nil }
        do {
            return try await self.albumRepo.fetch(id: id)
        } catch {
            self.log.warning("edit.fallbackRow.albumLookupFailed", [
                "album": id,
                "context": context,
                "error": String(reflecting: error),
            ])
            return nil
        }
    }

    /// The artist row, or nil with a log line rather than silence (#492).
    func artistOrNil(_ id: Int64?, context: String) async -> Artist? {
        guard let id else { return nil }
        do {
            return try await self.artistRepo.fetch(id: id)
        } catch {
            self.log.warning("edit.fallbackRow.artistLookupFailed", [
                "artist": id,
                "context": context,
                "error": String(reflecting: error),
            ])
            return nil
        }
    }

    // MARK: - Security scope

    /// Resolves the track's own bookmark and starts its security scope.
    ///
    /// - Returns: The URL whose scope the caller must stop, or `nil` when the
    ///   bookmark did not resolve or the scope did not start.
    func startPerFileScope(bookmark: Data, track: Track) -> URL? {
        var perFileURL: URL?
        var isStale = false
        do {
            let resolved = try URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if resolved.startAccessingSecurityScopedResource() {
                perFileURL = resolved
            }
        } catch {
            // Without the scope the write fails later with a permission
            // error naming the file, never this cause (#492).
            self.log.warning("edit.perFileScope.bookmarkUnresolvable", [
                "track": track.id ?? -1,
                "error": String(reflecting: error),
            ])
        }
        return perFileURL
    }

    /// Acquires the security scope of the library root that contains
    /// `fileURLString` and returns an RAII handle whose `deinit` releases it.
    /// Caller binds the handle to a `let` for the duration of the operation;
    /// no manual `defer` is required.
    ///
    /// Returns `nil` when no matching root exists (e.g. in-memory test DBs) or
    /// when the bookmark cannot be resolved; file I/O is then attempted with
    /// the raw URL, which works outside the sandbox.
    func acquireRootScope(for fileURLString: String) async throws -> RootScopeHandle? {
        let roots: [LibraryRoot]
        do {
            roots = try await self.rootRepo.fetchAll()
        } catch {
            // No scope means the raw write is attempted instead, and its
            // failure names the file rather than this cause (#492).
            self.log.warning("edit.root_scope.rootsUnavailable", ["error": String(reflecting: error)])
            return nil
        }
        guard let filePath = URL(string: fileURLString)?.path else { return nil }
        guard let root = roots.first(where: { $0.contains(filePath: filePath) }) else { return nil }
        var isStale = false
        let rootURL: URL
        do {
            rootURL = try URL(
                resolvingBookmarkData: root.bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            self.log.warning("edit.root_scope.bookmark_unresolvable", [
                "filePath": filePath,
                "error": String(reflecting: error),
            ])
            return nil
        }
        guard let handle = RootScopeHandle(url: rootURL) else {
            self.log.warning("edit.root_scope.failed", ["filePath": filePath])
            return nil
        }
        return handle
    }
}
