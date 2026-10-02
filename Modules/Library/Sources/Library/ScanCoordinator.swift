import Foundation
import Metadata
import Observability
import Persistence

// MARK: - ScanCoordinator

/// Orchestrates a single scan pass over a set of library roots.
///
/// - Parallelism is capped at `min(ProcessInfo.activeProcessorCount, 4)`.
/// - Cooperatively cancellable: cancelling the owning `Task` stops gracefully.
actor ScanCoordinator {
    // MARK: - Dependencies

    // `ScanCoordinator+Import.swift` and `ScanCoordinator+CueMarkers.swift`
    // use some of these, so those are internal rather than private.
    let database: Database
    let trackRepo: TrackRepository
    let artistRepo: ArtistRepository
    let albumRepo: AlbumRepository
    let lyricsRepo: LyricsRepository
    let coverArtCache: CoverArtCache
    private let libraryRootRepo: LibraryRootRepository
    private let changeDetector: ChangeDetector
    private let tagReader: TagReader
    private let settingsRepo: SettingsRepository
    let log = AppLogger.make(.library)

    // MARK: - Init

    init(database: Database) {
        self.database = database
        self.trackRepo = TrackRepository(database: database)
        self.artistRepo = ArtistRepository(database: database)
        self.albumRepo = AlbumRepository(database: database)
        self.lyricsRepo = LyricsRepository(database: database)
        self.coverArtCache = CoverArtCache.make(database: database)
        self.libraryRootRepo = LibraryRootRepository(database: database)
        self.changeDetector = ChangeDetector()
        self.tagReader = TagReader()
        self.settingsRepo = SettingsRepository(database: database)
    }

    // MARK: - Single file rescan

    /// Re-imports a single file, refreshing its tags and bookmarks.
    ///
    /// Completes in < 200 ms for normal files.  Returns a one-entry
    /// `ScanProgress.Summary` describing the outcome.
    ///
    /// - Parameter url: The resolved, security-scoped URL for the file.
    func scanSingleFile(url: URL) async throws -> ScanProgress.Summary {
        let start = ContinuousClock.now
        var inserted = 0, updated = 0, errors = 0

        let result = await self.importOne(url: url, mode: .full) { _ in }
        switch result {
        case .inserted:
            inserted += 1

        case .updated:
            updated += 1

        default:
            errors += 1
        }

        let elapsed = ContinuousClock.now - start
        return ScanProgress.Summary(
            inserted: inserted,
            updated: updated,
            removed: 0,
            skipped: 0,
            errors: errors,
            duration: elapsed
        )
    }

    // MARK: - Scan

    /// Performs a scan over `roots` and emits progress via `yield`.
    ///
    /// - Parameters:
    ///   - roots: Resolved root URLs to scan.
    ///   - mode:  `.quick` checks mtime/size; `.full` re-reads every file.
    ///   - yield: Closure to send progress events back to the caller.
    func scan(
        roots: [(url: URL, rootID: Int64)],
        mode: ScanMode,
        yield emit: @escaping @Sendable (ScanProgress) -> Void
    ) async {
        let start = ContinuousClock.now
        var counts = ScanCounts()

        emit(.started(rootCount: roots.count))
        self.log.debug("scan.start", ["roots": roots.count, "mode": "\(mode)"])

        guard await self.seedChangeDetector(roots: roots, start: start, emit: emit) else { return }

        let supported = TagReader.supportedExtensions
        let concurrency = min(ProcessInfo.processInfo.activeProcessorCount, 4)

        let iCloudDownload = await self.readICloudDownloadSetting()
        let settings = WalkSettings(supported: supported, concurrency: concurrency, iCloudDownload: iCloudDownload)

        let results = await self.walkAndImport(roots: roots, mode: mode, settings: settings, emit: emit)

        self.log.debug("scan.walk.end", ["results": results.count])
        guard !Task.isCancelled else { return }

        for result in results {
            counts.add(result)
        }

        counts.removed = await self.disableRemovedTracks(emit: emit)
        await self.pruneOrphanAlbums()
        await self.attachCueMarkers(roots: roots)

        let elapsed = ContinuousClock.now - start
        self.log.debug("scan.end", [
            "inserted": counts.inserted, "updated": counts.updated, "removed": counts.removed,
            "skipped": counts.skipped, "errors": counts.errors,
        ])
        emit(.finished(ScanProgress.Summary(
            inserted: counts.inserted,
            updated: counts.updated,
            removed: counts.removed,
            skipped: counts.skipped,
            errors: counts.errors,
            duration: elapsed
        )))
    }

    // MARK: - Scan phases

    /// Seeds the change detector with the enabled tracks under `roots`.
    ///
    /// - Returns: `false` when the library could not be read; the error and
    ///   the finished events are already emitted and the scan must stop.
    private func seedChangeDetector(
        roots: [(url: URL, rootID: Int64)],
        start: ContinuousClock.Instant,
        emit: @Sendable (ScanProgress) -> Void
    ) async -> Bool {
        // Seed the change detector from the current DB state — but only with
        // tracks that belong to the roots we are about to scan.  Seeding with
        // the entire library would mark every out-of-scope track as "removed"
        // when a partial scan (e.g. a single newly-added file) completes.
        // Disabled tracks are intentionally excluded from the seed so they are
        // treated as new and re-imported (clearing their disabled flag).
        // Both quick and full scans seed so that deleted files are pruned in
        // either mode.
        // A failed read must not read as an empty library: the seed is what
        // makes deleted files prunable and keeps known files from looking new,
        // so the scan stops here rather than re-importing everything and
        // pruning nothing (#481).
        let allTracks: [Track]
        do {
            allTracks = try await self.trackRepo.fetchAllIncludingDisabled()
        } catch {
            self.log.error("scan.seed_failed", ["error": String(reflecting: error)])
            emit(.error(url: nil, error: error))
            emit(.finished(ScanProgress.Summary(
                inserted: 0,
                updated: 0,
                removed: 0,
                skipped: 0,
                errors: 1,
                duration: ContinuousClock.now - start
            )))
            return false
        }
        // Normalize roots to filesystem paths with symlinks resolved (e.g.
        // `/var` → `/private/var`).  Without this, a root URL of
        // `file:///var/folders/...` never prefix-matches a stored track URL
        // of `file:///private/var/folders/...` and the seed becomes empty,
        // disabling removal detection.  We use `realpath(3)` because
        // `URL.resolvingSymlinksInPath()` only normalizes when the target
        // file actually exists, which is unreliable for tracks whose files
        // have been removed since import.
        let rootPaths: [String] = roots.compactMap { Self.canonicalPath($0.url.path) }
        let scopedEnabledTracks = allTracks.filter { track in
            guard !track.disabled else { return false }
            guard let trackURL = URL(string: track.fileURL) else { return false }
            let trackPath = Self.canonicalPath(trackURL.path) ?? trackURL.path
            return rootPaths.contains { LibraryRoot.directory($0, contains: trackPath) }
        }
        await self.changeDetector.seed(scopedEnabledTracks.map {
            ChangeDetector.KnownFile(url: $0.fileURL, mtime: $0.fileMtime, size: $0.fileSize)
        })
        return true
    }

    /// Reads the opt-in iCloud download setting; a failed read counts as off.
    private func readICloudDownloadSetting() async -> Bool {
        // ADR-004 audit H7: opt-in iCloud download for placeholder files.
        // A failed read is indistinguishable from the setting being off, so
        // iCloud placeholders are skipped with no reason given (#492).
        var iCloudDownload = false
        do {
            iCloudDownload = try await self.settingsRepo.get(Bool.self, for: "library.icloudDownload") ?? false
        } catch {
            self.log.warning("scan.setting.readFailed", [
                "key": "library.icloudDownload",
                "error": String(reflecting: error),
            ])
        }
        return iCloudDownload
    }

    /// Walks every root and imports each file found, at most
    /// `settings.concurrency` at a time.
    private func walkAndImport(
        roots: [(url: URL, rootID: Int64)],
        mode: ScanMode,
        settings: WalkSettings,
        emit: @escaping @Sendable (ScanProgress) -> Void
    ) async -> [ImportResult] {
        let supported = settings.supported
        let concurrency = settings.concurrency
        let iCloudDownload = settings.iCloudDownload
        // Feed the FileWalker stream directly into a bounded TaskGroup so
        // importing overlaps the walk and peak memory stays O(concurrency)
        // rather than O(library size). Previously every discovered (URL,
        // rootID) pair was buffered into an array before a single import
        // started (~10k pairs at once on a large library). See #267.
        return await withTaskGroup(
            of: (url: URL, result: ImportResult).self,
            returning: [ImportResult].self
        ) { group in
            var inFlight = 0
            var collected: [ImportResult] = []
            var walked = 0

            rootLoop: for root in roots {
                for await fileURL in FileWalker.walk(
                    root.url,
                    supportedExtensions: supported,
                    iCloudDownload: iCloudDownload
                ) {
                    if Task.isCancelled {
                        break rootLoop
                    }
                    walked += 1
                    emit(.walking(currentPath: fileURL.path, walked: walked))

                    // Throttle to the concurrency window: once `concurrency`
                    // imports are in flight, wait for one to finish before
                    // dispatching the next discovered file.
                    if inFlight >= concurrency {
                        if let r = await group.next() {
                            collected.append(r.result)
                            inFlight -= 1
                        }
                    }

                    inFlight += 1
                    let url = fileURL
                    let scanMode = mode
                    // ADR-004 audit M4: scan import work runs at `.utility` so it
                    // doesn't steal CPU priority from playback (engine + queue
                    // operate at higher default priorities).
                    group.addTask(priority: .utility) {
                        let result = await self.importOne(url: url, mode: scanMode, emit: emit)
                        return (url, result)
                    }
                }
                if Task.isCancelled {
                    break
                }
            }
            // Drain remaining
            for await r in group {
                collected.append(r.result)
            }
            return collected
        }
    }

    /// Mark removed tracks
    ///
    /// - Returns: The number of tracks disabled.
    private func disableRemovedTracks(emit: @Sendable (ScanProgress) -> Void) async -> Int {
        var removed = 0
        guard !Task.isCancelled else { return removed }
        let removedURLs = await changeDetector.removedURLs()
        for urlString in removedURLs {
            do {
                guard let track = try await trackRepo.fetchOne(fileURL: urlString),
                      let id = track.id else { continue }
                var disabled = track
                disabled.disabled = true
                try await self.trackRepo.update(disabled)
                emit(.removed(trackID: id))
                removed += 1
            } catch {
                // The summary otherwise counts a removal that did not
                // happen, or misses one that should have (#492).
                self.log.warning("scan.removal.failed", [
                    "url": urlString,
                    "error": String(reflecting: error),
                ])
            }
        }
        return removed
    }

    /// Drop album rows no longer referenced by any track, e.g. compilation
    /// albums that regrouped from many split rows into one (#362), so stale
    /// empty albums do not linger after the fix lands. Best-effort.
    private func pruneOrphanAlbums() async {
        guard !Task.isCancelled else { return }
        do {
            _ = try await self.albumRepo.pruneOrphans()
        } catch {
            // Empty album rows linger in the grid; best effort, but the
            // reason belongs in the log (#492).
            self.log.warning("scan.pruneOrphans.failed", ["error": String(reflecting: error)])
        }
    }

    // MARK: - Private

    private func importOne(
        url: URL,
        mode: ScanMode,
        emit: @Sendable (ScanProgress) -> Void
    ) async -> ImportResult {
        guard !Task.isCancelled else { return .skipped }

        // File attributes. Prefer the values the FileWalker enumerator already
        // prefetched onto this URL (size + mtime keys), so this is a cache hit
        // rather than a fresh stat(2) per file; resourceValues falls back to a
        // syscall only on a cache miss, so this never regresses. See #278.
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = Int64(values?.fileSize ?? 0)
        let mtime = Int64(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
        let file = ScannedFile(url: url, size: size, mtime: mtime)

        // The check must run in every mode: it is also what marks the file
        // *visited*, and the removal pass disables every seeded URL that
        // was never visited. Running it only for quick scans meant a Full
        // Rescan re-imported each track and then marked the entire library
        // removed (ADR-081 invocation pass). Only the skip-unchanged
        // shortcut is quick-mode behaviour.
        let status = await changeDetector.check(url: url, mtime: mtime, size: size)
        if mode == .quick, status == .unchanged {
            emit(.processed(url: url, outcome: .skippedUnchanged))
            return .skipped
        }

        // Read tags
        let tags: TrackTags
        do {
            tags = try self.tagReader.read(from: url)
        } catch {
            self.log.error("scan.tag_read_failed", ["url": url.path, "error": "\(error)"])
            emit(.error(url: url, error: error))
            return .error
        }

        // Check for conflict. A failed lookup must not read as "no such row":
        // that is what protects a user-edited track from being overwritten by
        // the scan, so the file is reported as an error and left alone (#481).
        let existingTrack: Track?
        do {
            existingTrack = try await self.trackRepo.fetchOne(fileURL: url.absoluteString)
        } catch {
            self.log.error("scan.existing_lookup_failed", ["url": url.path, "error": String(reflecting: error)])
            emit(.error(url: url, error: error))
            return .error
        }
        if let ex = existingTrack, let exID = ex.id, ex.userEdited,
           let conflict = await self.resolveUserEditConflict(ex, exID: exID, tags: tags, file: file, emit: emit) {
            return conflict
        }

        return await self.importAndReport(file: file, tags: tags, existingTrack: existingTrack, emit: emit)
    }

    /// Handles a file whose track row carries user-edited tags.
    ///
    /// - Returns: `.conflict` when the resolver keeps the user's tags, or
    ///   `nil` when the import must continue.
    private func resolveUserEditConflict(
        _ ex: Track,
        exID: Int64,
        tags: TrackTags,
        file: ScannedFile,
        emit: @Sendable (ScanProgress) -> Void
    ) async -> ImportResult? {
        let url = file.url
        let size = file.size
        let mtime = file.mtime
        let resolution = ConflictResolver.resolve(existingTrackID: exID, userEdited: true)
        if case let .conflict(trackID) = resolution {
            // The user has manually edited this track's tags so we don't
            // overwrite them, but we must still clear the disabled flag and
            // refresh file-level fields so the track becomes visible again.
            // Also set needs_conflict_review so the Tag Editor shows a banner.
            var updated = ex
            // Always sync fileMtime/fileSize so subsequent scans see a
            // matching mtime and don't re-process this file on every
            // startup. Without this, the conflict branch fires on every
            // launch for any track whose mtime changed before the
            // EditTransaction stamp was introduced.
            updated.fileSize = size
            updated.fileMtime = mtime
            // A changed file invalidates its transcode verdict (ADR-075)
            // even when the user's edited tags are being preserved.
            if mtime != ex.fileMtime {
                updated.clearProvenance()
            }
            if ex.disabled {
                updated.disabled = false
            }
            // Only raise the review flag when disk tags actually differ from
            // the DB values. A mtime-only change (e.g. app rewrote the file
            // but the tags are identical) is not a user-visible conflict.
            if Self.tagsDiffer(dbTrack: ex, diskTags: tags) {
                updated.needsConflictReview = true
            }
            // Only write the row when something actually changed. An
            // unconditional update here re-fires ValueObservation streams
            // (and the UI reloads behind them) on every FSEvents pass,
            // even when the pass was a metadata-only no-op.
            if updated != ex {
                do {
                    try await self.trackRepo.update(updated)
                } catch {
                    // The conflict banner and the refreshed file facts are
                    // both dropped, and the scan reports a conflict as
                    // though the row had been written (#492).
                    self.log.warning("scan.conflict.updateFailed", [
                        "track": trackID,
                        "error": String(reflecting: error),
                    ])
                }
            }
            emit(.processed(url: url, outcome: .conflict(trackID: trackID)))
            return .conflict(trackID)
        }
        return nil
    }

    /// Minting a security-scoped bookmark is an expensive per-file syscall.
    /// A known track (same file_url) already carries a valid bookmark for
    /// the same file, so reuse it and only mint a fresh one for genuinely
    /// new files (or a track that somehow lost its bookmark). A moved file
    /// arrives under a new path with no existing row, so it still gets a
    /// fresh bookmark. Stale-bookmark refresh stays on the edit path
    /// (MetadataEditService). See #278.
    ///
    /// Internal for `importAndReport` in `ScanCoordinator+Import.swift`.
    func bookmark(for url: URL, existingTrack: Track?) -> Data? {
        var bookmark = existingTrack?.fileBookmark
        if bookmark == nil {
            do {
                bookmark = try url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            } catch {
                // The row is imported without sandbox access, so playing it
                // later fails on permissions with no trace of this (#492).
                self.log.warning("scan.bookmark.mintFailed", [
                    "url": url.lastPathComponent,
                    "error": String(reflecting: error),
                ])
            }
        }
        return bookmark
    }

    /// Resolves any filesystem symlinks in `path` via `realpath(3)` and returns
    /// the canonical absolute form (e.g. `/var/...` → `/private/var/...` on
    /// macOS).  Returns `nil` if the path cannot be resolved (e.g. the file
    /// has been removed and no parent component exists).
    ///
    /// We use this rather than `URL.resolvingSymlinksInPath()` because the
    /// latter only normalizes when the target itself exists, which is an
    /// unreliable assumption when comparing roots against tracks whose files
    /// may have just been removed.
    private static func canonicalPath(_ path: String) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX))
        let resolved = buffer.withUnsafeMutableBufferPointer { ptr -> UnsafeMutablePointer<CChar>? in
            // The buffer is never empty, so there is always a base address;
            // without one the path counts as unresolvable, like a realpath failure.
            guard let base = ptr.baseAddress else { return nil }
            return base.withMemoryRebound(to: CChar.self, capacity: ptr.count) { cPtr in
                realpath(path, cPtr)
            }
        }
        guard resolved != nil else { return nil }
        let length = buffer.firstIndex(of: 0) ?? buffer.count
        return String(bytes: buffer[..<length], encoding: .utf8)
    }
}
