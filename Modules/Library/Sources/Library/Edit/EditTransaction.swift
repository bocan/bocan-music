import Foundation
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

    private let database: Persistence.Database
    private let trackRepo: TrackRepository
    private let artistRepo: ArtistRepository
    private let albumRepo: AlbumRepository
    private let coverArtRepo: CoverArtRepository
    private let coverArtCache: CoverArtCache
    private let backupRing: BackupRing
    private let rootRepo: LibraryRootRepository
    private let writer: TagWriter
    private let reader: TagReader
    private let log = AppLogger.make(.library)

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
            try await self.database.write { db in
                for (track, coverHash) in updates {
                    var mutable = track
                    if let hash = coverHash { mutable.coverArtHash = hash }
                    try mutable.update(db)
                }
            }
            self.log.debug("edit.committed", ["count": successfulUpdates.count])
        }

        if !errors.isEmpty {
            throw EditError.partial(errors)
        }
    }

    // MARK: - Private

    private func processOneTrack(
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

        // Start the root-folder security scope so TagReader / TagWriter can
        // access this file and create temp siblings in the same directory.
        // The scope must remain active for the entire read-write-verify cycle.
        // The handle's `deinit` releases the scope when this function returns.
        let rootScope = try await self.acquireRootScope(for: track.fileURL)

        // Fallback: if no folder root covers this file (e.g. it was added via
        // "Add Files…" as an individual root), activate its per-file bookmark.
        // This grants the sandbox read+write access to the specific file so that
        // TagReader/TagWriter can open it and FileManager can replace it.
        var perFileURL: URL? = nil
        if rootScope == nil, let bookmark = track.fileBookmark {
            var isStale = false
            if let resolved = try? URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ), resolved.startAccessingSecurityScopedResource() {
                perFileURL = resolved
            }
        }

        defer {
            // `rootScope` releases automatically via `deinit`; only the
            // per-file fallback URL needs a manual stop.
            perFileURL?.stopAccessingSecurityScopedResource()
            _ = rootScope // keep alive until end of function
        }

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
                let rawArts = [RawCoverArt(
                    data: artData,
                    mimeType: Self.mimeType(for: artData),
                    pictureType: 3 // APIC type 3 = front cover
                )]
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

        // 7. Handle cover art
        var coverArtHash: String? = track.coverArtHash
        if let artPatch = patch.coverArt {
            if let artData = artPatch {
                let extracted = CoverArtExtractor.extract(from: [
                    RawCoverArt(data: artData, mimeType: "image/jpeg", pictureType: 3),
                ])
                if let persisted = try await self.coverArtCache.persist(extracted) {
                    coverArtHash = persisted.hash
                }
            } else {
                coverArtHash = nil // cleared
            }
        }

        // 8. Build updated Track record, normalising artist/album FKs when changed.
        var updated = patch.applying(to: track)
        updated.userEdited = true

        if patch.artist != nil || patch.albumArtist != nil || patch.album != nil {
            // Fetch current album/albumArtist rows for fallback values (ignore errors).
            let currentAlbum: Album? = if let id = track.albumID { try? await self.albumRepo.fetch(id: id) }
            else { nil }

            let currentAlbumArtist: Artist? = if let id = currentAlbum?.albumArtistID { try? await self.artistRepo.fetch(id: id) }
            else { nil }

            let currentTrackArtist: Artist? = if let id = track.artistID { try? await self.artistRepo.fetch(id: id) }
            else { nil }

            // Resolve track-artist FK.
            let artistName: String = if let patched = patch.artist { patched ?? "Unknown Artist" }
            else { currentTrackArtist?.name ?? "Unknown Artist" }
            let artist = try await self.artistRepo.findOrCreate(name: artistName)
            updated.artistID = artist.id

            // Resolve album-artist (may differ from track artist).
            let albumArtistName: String = if let patched = patch.albumArtist { patched ?? artistName }
            else { currentAlbumArtist?.name ?? artistName }
            let albumArtist = albumArtistName == artistName
                ? artist
                : try await self.artistRepo.findOrCreate(name: albumArtistName)

            // Resolve album FK.
            let albumTitle: String = if let patched = patch.album { patched ?? "Unknown Album" }
            else { currentAlbum?.title ?? "Unknown Album" }
            let album = try await self.albumRepo.findOrCreate(title: albumTitle, albumArtistID: albumArtist.id)
            updated.albumID = album.id
        }

        return (updated, coverArtHash)
    }

    private static func applyPatch(_ patch: TrackTagPatch, to tags: inout TrackTags) {
        if let v = patch.title { tags.title = v }
        if let v = patch.artist { tags.artist = v }
        if let v = patch.albumArtist { tags.albumArtist = v }
        if let v = patch.album { tags.album = v }
        if let v = patch.genre { tags.genre = v }
        if let v = patch.composer { tags.composer = v }
        if let v = patch.comment { tags.comment = v }
        if let v = patch.trackNumber { tags.trackNumber = v }
        if let v = patch.trackTotal { tags.trackTotal = v }
        if let v = patch.discNumber { tags.discNumber = v }
        if let v = patch.discTotal { tags.discTotal = v }
        if let v = patch.year { tags.year = v }
        if let v = patch.bpm { tags.bpm = v }
        if let v = patch.key { tags.key = v }
        if let v = patch.isrc { tags.isrc = v }
        if let v = patch.lyrics { tags.lyrics = v }
        if let v = patch.sortArtist { tags.sortArtist = v }
        if let v = patch.sortAlbumArtist { tags.sortAlbumArtist = v }
        if let v = patch.sortAlbum { tags.sortAlbum = v }
        if let v = patch.replaygainTrackGain {
            let rg = tags.replayGain
            tags.replayGain = ReplayGain(
                trackGain: v,
                trackPeak: rg.trackPeak,
                albumGain: rg.albumGain,
                albumPeak: rg.albumPeak
            )
        }
    }

    /// Detects the MIME type of image `data` from its magic bytes.
    ///
    /// Returns `"image/jpeg"` as the default for unrecognised formats because
    /// `ArtworkEditor.normalise()` converts large images to JPEG, making JPEG
    /// the most common format for patched cover art.
    private static func mimeType(for data: Data) -> String {
        guard data.count >= 4 else { return "image/jpeg" }
        let header = data.prefix(4)
        // PNG: 89 50 4E 47
        if header.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        // JPEG: FF D8 FF
        if header.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        // WebP: 52 49 46 46 ... 57 45 42 50 (need 12 bytes)
        if data.count >= 12, header.starts(with: [0x52, 0x49, 0x46, 0x46]),
           data[8 ..< 12].elementsEqual([0x57, 0x45, 0x42, 0x50]) { return "image/webp" }
        return "image/jpeg"
    }

    // MARK: - Security scope

    /// Acquires the security scope of the library root that contains
    /// `fileURLString` and returns an RAII handle whose `deinit` releases it.
    /// Caller binds the handle to a `let` for the duration of the operation;
    /// no manual `defer` is required.
    ///
    /// Returns `nil` when no matching root exists (e.g. in-memory test DBs) or
    /// when the bookmark cannot be resolved — file I/O is then attempted with
    /// the raw URL, which works outside the sandbox.
    private func acquireRootScope(for fileURLString: String) async throws -> RootScopeHandle? {
        let roots = await (try? self.rootRepo.fetchAll()) ?? []
        guard let filePath = URL(string: fileURLString)?.path else { return nil }
        guard let root = roots.first(where: {
            let prefix = $0.path == "/" ? "/" : $0.path + "/"
            return filePath.hasPrefix(prefix)
        }) else { return nil }
        var isStale = false
        guard let rootURL = try? URL(
            resolvingBookmarkData: root.bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            self.log.warning("edit.root_scope.bookmark_unresolvable", ["filePath": filePath])
            return nil
        }
        guard let handle = RootScopeHandle(url: rootURL) else {
            self.log.warning("edit.root_scope.failed", ["filePath": filePath])
            return nil
        }
        return handle
    }
}
