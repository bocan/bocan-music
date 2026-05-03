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

    private let database: Database
    private let trackRepo: TrackRepository
    private let artistRepo: ArtistRepository
    private let albumRepo: AlbumRepository
    private let lyricsRepo: LyricsRepository
    private let coverArtCache: CoverArtCache
    private let libraryRootRepo: LibraryRootRepository
    private let changeDetector: ChangeDetector
    private let tagReader: TagReader
    private let settingsRepo: SettingsRepository
    private let log = AppLogger.make(.library)

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

    // MARK: - Internal types

    enum ImportResult {
        case inserted(Int64), updated(Int64), skipped, conflict(Int64), error
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
        case .inserted: inserted += 1
        case .updated: updated += 1
        default: errors += 1
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
        var inserted = 0, updated = 0, removed = 0, errors = 0, skipped = 0

        emit(.started(rootCount: roots.count))

        // Seed the change detector from the current DB state — but only with
        // tracks that belong to the roots we are about to scan.  Seeding with
        // the entire library would mark every out-of-scope track as "removed"
        // when a partial scan (e.g. a single newly-added file) completes.
        // Disabled tracks are intentionally excluded from the seed so they are
        // treated as new and re-imported (clearing their disabled flag).
        if mode == .quick {
            let allTracks = await (try? self.trackRepo.fetchAllIncludingDisabled()) ?? []
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
                return rootPaths.contains { trackPath.hasPrefix($0) }
            }
            await self.changeDetector.seed(scopedEnabledTracks.map {
                (url: $0.fileURL, mtime: $0.fileMtime, size: $0.fileSize)
            })
        }

        let supported = TagReader.supportedExtensions
        let concurrency = min(ProcessInfo.processInfo.activeProcessorCount, 4)

        // Phase 3 audit H7: opt-in iCloud download for placeholder files.
        let iCloudDownload: Bool = await (try? self.settingsRepo.get(Bool.self, for: "library.icloudDownload")) ?? nil ?? false

        // Collect all URLs first so we can cap concurrency properly
        var discoveredURLs: [(url: URL, rootID: Int64)] = []
        for root in roots {
            var walked = 0
            for await fileURL in FileWalker.walk(
                root.url,
                supportedExtensions: supported,
                iCloudDownload: iCloudDownload
            ) {
                walked += 1
                discoveredURLs.append((fileURL, root.rootID))
                emit(.walking(currentPath: fileURL.path, walked: walked))
                guard !Task.isCancelled else { break }
            }
            guard !Task.isCancelled else { break }
        }

        guard !Task.isCancelled else { return }

        // Import in a bounded TaskGroup; each task returns an ImportResult.
        let results: [ImportResult] = await withTaskGroup(
            of: (url: URL, result: ImportResult).self,
            returning: [ImportResult].self
        ) { group in
            var inFlight = 0
            var collected: [ImportResult] = []

            for (fileURL, _) in discoveredURLs {
                if Task.isCancelled { break }

                if inFlight >= concurrency {
                    if let r = await group.next() {
                        collected.append(r.result)
                        inFlight -= 1
                    }
                }

                inFlight += 1
                let url = fileURL
                let mode_ = mode
                // Phase 3 audit M4: scan import work runs at `.utility` so it
                // doesn't steal CPU priority from playback (engine + queue
                // operate at higher default priorities).
                group.addTask(priority: .utility) {
                    let result = await self.importOne(url: url, mode: mode_, emit: emit)
                    return (url, result)
                }
            }
            // Drain remaining
            for await r in group {
                collected.append(r.result)
            }
            return collected
        }

        for result in results {
            switch result {
            case .inserted: inserted += 1
            case .updated: updated += 1
            case .skipped: skipped += 1
            case .conflict: skipped += 1
            case .error: errors += 1
            }
        }

        // Mark removed tracks
        if mode == .quick, !Task.isCancelled {
            let removedURLs = await changeDetector.removedURLs()
            for urlString in removedURLs {
                guard let track = try? await trackRepo.fetchOne(fileURL: urlString) else { continue }
                if let id = track.id {
                    var disabled = track
                    disabled.disabled = true
                    try? await self.trackRepo.update(disabled)
                    emit(.removed(trackID: id))
                    removed += 1
                }
            }
        }

        let elapsed = ContinuousClock.now - start
        emit(.finished(ScanProgress.Summary(
            inserted: inserted,
            updated: updated,
            removed: removed,
            skipped: skipped,
            errors: errors,
            duration: elapsed
        )))
    }

    // MARK: - Private

    private func importOne(
        url: URL,
        mode: ScanMode,
        emit: @Sendable (ScanProgress) -> Void
    ) async -> ImportResult {
        guard !Task.isCancelled else { return .skipped }

        // File attributes
        let fm = FileManager.default
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int64) ?? 0
        let mtime = Int64((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)

        // Change detection for quick scans
        if mode == .quick {
            let status = await changeDetector.check(url: url, mtime: mtime, size: size)
            if status == .unchanged {
                emit(.processed(url: url, outcome: .skippedUnchanged))
                return .skipped
            }
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

        // Check for conflict
        let existingTrack = try? await trackRepo.fetchOne(fileURL: url.absoluteString)
        if let ex = existingTrack, let exID = ex.id, ex.userEdited {
            let resolution = ConflictResolver.resolve(existingTrackID: exID, userEdited: true)
            if case let .conflict(trackID) = resolution {
                // The user has manually edited this track's tags so we don't
                // overwrite them — but we must still clear the disabled flag and
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
                if ex.disabled { updated.disabled = false }
                // Only raise the review flag when disk tags actually differ from
                // the DB values. A mtime-only change (e.g. app rewrote the file
                // but the tags are identical) is not a user-visible conflict.
                if Self.tagsDiffer(dbTrack: ex, diskTags: tags) {
                    updated.needsConflictReview = true
                }
                try? await self.trackRepo.update(updated)
                emit(.processed(url: url, outcome: .conflict(trackID: trackID)))
                return .conflict(trackID)
            }
        }

        // Create importer and import
        let importer = TrackImporter(
            artistRepo: artistRepo,
            albumRepo: albumRepo,
            trackRepo: trackRepo,
            lyricsRepo: lyricsRepo,
            coverArtCache: coverArtCache
        )

        let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        do {
            let id = try await importer.importTrack(
                url: url,
                bookmark: bookmark,
                tags: tags,
                fileMtime: mtime,
                fileSize: size
            )
            if existingTrack == nil {
                emit(.processed(url: url, outcome: .inserted(trackID: id)))
                return .inserted(id)
            } else {
                emit(.processed(url: url, outcome: .updated(trackID: id)))
                return .updated(id)
            }
        } catch {
            self.log.error("scan.import_failed", ["url": url.path, "error": "\(error)"])
            emit(.error(url: url, error: error))
            return .error
        }
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
    /// Returns `true` when any user-visible tag field differs between the
    /// stored `Track` and the freshly-read `TrackTags`. Used in the conflict
    /// branch so we only raise `needsConflictReview` when something actually
    /// changed — not just the file's modification timestamp.
    private static func tagsDiffer(dbTrack: Track, diskTags: TrackTags) -> Bool {
        func ne<T: Equatable>(_ a: T?, _ b: T?) -> Bool {
            a != b
        }
        return ne(dbTrack.title, diskTags.title) ||
            ne(dbTrack.genre, diskTags.genre) ||
            ne(dbTrack.composer, diskTags.composer) ||
            ne(dbTrack.isrc, diskTags.isrc) ||
            ne(dbTrack.key, diskTags.key) ||
            ne(dbTrack.year, diskTags.year) ||
            ne(dbTrack.trackNumber, diskTags.trackNumber) ||
            ne(dbTrack.trackTotal, diskTags.trackTotal) ||
            ne(dbTrack.discNumber, diskTags.discNumber) ||
            ne(dbTrack.discTotal, diskTags.discTotal)
    }

    private static func canonicalPath(_ path: String) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX))
        let resolved = buffer.withUnsafeMutableBufferPointer { ptr -> UnsafeMutablePointer<CChar>? in
            ptr.baseAddress!.withMemoryRebound(to: CChar.self, capacity: ptr.count) { cPtr in
                realpath(path, cPtr)
            }
        }
        guard resolved != nil else { return nil }
        let length = buffer.firstIndex(of: 0) ?? buffer.count
        return String(decoding: buffer[..<length], as: UTF8.self)
    }
}

/// Controls how the scanner treats the existing DB state.
public enum ScanMode: Sendable {
    /// Only re-import files whose `mtime` or `size` has changed.
    case quick
    /// Re-read every file regardless of stored state.
    case full
}
