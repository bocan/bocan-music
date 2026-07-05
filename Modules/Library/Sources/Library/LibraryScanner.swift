import Foundation
import Metadata
import Observability
import Persistence

// MARK: - LibraryScanner

/// Public entry point for all library-scanning operations.
///
/// ```swift
/// let scanner = await LibraryScanner(database: db)
/// try await scanner.addRoot(folderURL)
/// for await event in scanner.scan() {
///     print(event)
/// }
/// ```
public actor LibraryScanner {
    // MARK: - Properties

    private let database: Database
    private let rootRepo: LibraryRootRepository
    private let coordinator: ScanCoordinator
    private var fsWatcher: FSWatcher?
    private var isScanning = false
    private let log = AppLogger.make(.library)

    /// Called on the caller's context after FSEvents imports one or more files.
    /// The ViewModel sets this to reload the tracks/albums/artists views.
    public var onFileImported: (@Sendable () async -> Void)?

    /// Sets the callback invoked after FSEvents imports one or more files.
    public func setOnFileImported(_ handler: (@Sendable () async -> Void)?) {
        self.onFileImported = handler
    }

    // MARK: - Init

    public init(database: Database) {
        self.database = database
        self.rootRepo = LibraryRootRepository(database: database)
        self.coordinator = ScanCoordinator(database: database)
    }

    // MARK: - Root management

    /// Adds a new library root from a user-chosen URL.
    ///
    /// Creates a security-scoped bookmark and persists it to the DB.
    /// If a root with the same path already exists this is a no-op.
    public func addRoot(_ url: URL) async throws {
        let existing = try await self.rootRepo.fetchAll()
        guard !existing.contains(where: { $0.path == url.path }) else { return }

        // Read-only scope: scanning + FSEvents watching never write to the root.
        // Per-file write scope is requested separately via the per-file bookmark
        // created by `ScanCoordinator` (see Phase 8 / EditTransaction).
        let bookmark = try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let now = Int64(Date.now.timeIntervalSince1970)
        let root = LibraryRoot(
            id: nil,
            path: url.path,
            bookmark: bookmark,
            addedAt: now,
            isInaccessible: false
        )
        try await self.rootRepo.upsert(root)
        self.log.info("library.root.added", ["path": url.path])
        // If a watcher is already running, begin watching the new root immediately.
        await self.watchNewRoot(path: url.path)
    }

    /// Removes a root by its database ID and soft-deletes all tracks under it.
    public func removeRoot(id: Int64) async throws {
        // Fetch the root path before deleting so we can disable its tracks.
        let roots = try await self.rootRepo.fetchAll()
        guard let root = roots.first(where: { $0.id == id }) else {
            try await self.rootRepo.delete(id: id)
            return
        }
        try await self.rootRepo.delete(id: id)
        let trackRepo = TrackRepository(database: self.database)
        try await trackRepo.disableAll(underPath: root.path)
        self.log.info("library.root.removed", ["id": id, "path": root.path])
    }

    /// Returns all persisted library roots.
    public func roots() async throws -> [LibraryRoot] {
        try await self.rootRepo.fetchAll()
    }

    // MARK: - Scanning

    /// Starts a scan and returns an `AsyncStream` of progress events.
    ///
    /// - Parameter mode: `.quick` (default) or `.full`.
    public func scan(mode: ScanMode = .quick) -> AsyncStream<ScanProgress> {
        AsyncStream { continuation in
            // Keep a handle to the scanning task and cancel it when the stream
            // terminates — either because we finished it ourselves or because
            // the consumer stopped iterating (or had its own task cancelled).
            // Without this, the unstructured Task inherited no cancellation, so
            // a consumer that cancelled could not stop the scan body; the
            // ScanCoordinator's cooperative `Task.isCancelled` checks never
            // tripped because nothing ever cancelled this task. See #266.
            let task = Task {
                guard !self.isScanning else {
                    continuation.yield(.error(url: nil, error: LibraryError.scanAlreadyInProgress))
                    continuation.finish()
                    return
                }
                self.isScanning = true
                defer { isScanning = false }

                let allRoots: [LibraryRoot]
                do {
                    allRoots = try await self.rootRepo.fetchAll()
                } catch {
                    continuation.yield(.error(url: nil, error: error))
                    continuation.finish()
                    return
                }

                // Resolve bookmarks and keep security scopes active for the entire scan.
                // SecurityScope.withAccess stops the scope when its closure returns, which
                // is too early — file tag reading happens later in coordinator.scan().
                // Instead, start each scope manually and stop them all via defer once
                // the coordinator finishes.
                var resolved: [(url: URL, rootID: Int64)] = []
                for root in allRoots {
                    guard let rootID = root.id else { continue }
                    var isStale = false
                    do {
                        let url = try URL(
                            resolvingBookmarkData: root.bookmark,
                            options: .withSecurityScope,
                            relativeTo: nil,
                            bookmarkDataIsStale: &isStale
                        )
                        guard url.startAccessingSecurityScopedResource() else {
                            throw LibraryError.bookmarkStale(url)
                        }
                        if isStale {
                            self.log.warning("security_scope.stale", ["url": url.path])
                            // Bookmark is still resolvable but macOS has flagged it for renewal.
                            // Persist a fresh bookmark now so future launches don't fail entirely.
                            do {
                                let fresh = try url.bookmarkData(
                                    options: .withSecurityScope,
                                    includingResourceValuesForKeys: nil,
                                    relativeTo: nil
                                )
                                var updated = root
                                updated.bookmark = fresh
                                try await self.rootRepo.upsert(updated)
                                self.log.debug("security_scope.refreshed", ["url": url.path])
                            } catch {
                                self.log.warning(
                                    "security_scope.refresh_failed",
                                    ["url": url.path, "error": String(reflecting: error)]
                                )
                            }
                        }
                        resolved.append((url, rootID))
                    } catch {
                        self.log.warning("library.root.inaccessible", ["id": rootID, "path": root.path])
                        try? await self.rootRepo.markInaccessible(id: rootID, true)
                        continuation.yield(.error(url: URL(fileURLWithPath: root.path), error: error))
                    }
                }
                // Stop all scopes once the scan completes (or if we return early below).
                defer {
                    for (url, _) in resolved {
                        url.stopAccessingSecurityScopedResource()
                    }
                }

                guard !resolved.isEmpty else {
                    continuation.yield(.finished(ScanProgress.Summary(
                        inserted: 0, updated: 0, removed: 0,
                        skipped: 0, errors: 0, duration: .zero
                    )))
                    continuation.finish()
                    return
                }

                await self.coordinator.scan(roots: resolved, mode: mode) { event in
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Rescans a single file, refreshing its tags, bookmark, and DB row.
    ///
    /// Finds the library root that covers `url`, activates its security scope,
    /// then delegates to the coordinator.  Returns a `ScanProgress.Summary`
    /// describing the outcome.
    public func scanSingleFile(url: URL) async throws -> ScanProgress.Summary {
        let roots = try await self.rootRepo.fetchAll()
        let filePath = url.path
        // Find the root whose path is a prefix of the file path so we can
        // activate its security scope before reading tags / creating a bookmark.
        if let root = roots.first(where: { filePath.hasPrefix($0.path) }) {
            let coordinator = self.coordinator
            return try await SecurityScope.withAccess(root.bookmark) { _ in
                try await coordinator.scanSingleFile(url: url)
            }
        }
        // No matching root found — try without a scope (development builds /
        // files added directly without a root).
        return try await self.coordinator.scanSingleFile(url: url)
    }

    // MARK: - FSWatcher

    /// Starts watching all current library roots for file-system changes.
    ///
    /// When a supported audio file is created or modified inside a watched root,
    /// it is re-imported automatically via `scanSingleFile(url:)`.
    /// Calling this when a watcher is already running is a no-op.
    public func startWatching() async {
        guard self.fsWatcher == nil else { return }
        let allRoots = await (try? self.rootRepo.fetchAll()) ?? []

        let watcher = FSWatcher { [weak self, log] urls in
            log.debug("fsevents.change", ["count": urls.count])
            guard let self else { return }
            Task {
                await self.handleFSChange(urls: urls)
            }
        }

        for root in allRoots {
            guard root.id != nil else { continue }
            let watchURL = self.watchableURL(for: root.path)
            await watcher.watch(watchURL, bookmark: root.bookmark)
        }

        self.fsWatcher = watcher
        self.log.info("fsevents.started", ["roots": allRoots.count])
    }

    /// Stops all active FSEvent streams.
    public func stopWatching() async {
        await self.fsWatcher?.stopAll()
        self.fsWatcher = nil
        self.log.info("fsevents.stopped")
    }

    /// Restarts every active FSEvent stream.  The App layer should call this
    /// from a `NSWorkspace.didWakeNotification` handler — FSEvents may stop
    /// firing reliably across long sleeps.
    public func restartWatcher() async {
        guard let watcher = self.fsWatcher else { return }
        await watcher.restartAllStreams()
        self.log.info("fsevents.restarted_after_wake")
    }

    /// Adds a newly registered root to an already-running watcher.
    ///
    /// Called automatically by `addRoot(_:)` when watching is active.
    func watchNewRoot(path: String) async {
        guard let watcher = self.fsWatcher else { return }
        let roots = await (try? self.rootRepo.fetchAll()) ?? []
        let bookmark = roots.first(where: { $0.path == path })?.bookmark
        let url = self.watchableURL(for: path)
        await watcher.watch(url, bookmark: bookmark)
        self.log.debug("fsevents.root_added", ["path": path])
    }

    // MARK: - Private helpers

    /// Returns the URL that FSEvents should watch for a given root path.
    ///
    /// FSEvents monitors directories. For file-type roots the parent directory
    /// is watched; the `onChange` handler then filters to just that file.
    private func watchableURL(for path: String) -> URL {
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return isDir.boolValue ? url : url.deletingLastPathComponent()
    }

    /// Handles a batch of FS-event URLs: filters to known audio extensions and
    /// triggers `scanSingleFile` for each matching, non-hidden file.
    ///
    /// When FSEvents reports a directory (e.g. when an entire folder is moved
    /// into a watched root) the event carries only the directory path — not one
    /// event per file inside it.  We recursively enumerate such directories so
    /// every audio file they contain is picked up automatically.
    private func handleFSChange(urls: [URL]) async {
        var didChange = false
        let trackRepo = TrackRepository(database: self.database)
        for raw in urls {
            // NFC-normalise — APFS may deliver decomposed UTF-8.
            let url = URL(fileURLWithPath: raw.path.precomposedStringWithCanonicalMapping)
            guard !url.lastPathComponent.hasPrefix(".") else { continue }

            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)

            if !exists {
                // File or directory was deleted — disable matching tracks.
                if TagReader.isSupported(url) {
                    // Single audio file: look it up by URL and mark disabled.
                    if let track = try? await trackRepo.fetchOne(fileURL: url.absoluteString),
                       let id = track.id {
                        var disabled = track
                        disabled.disabled = true
                        try? await trackRepo.update(disabled)
                        self.log.info("fsevents.file_removed", ["id": id, "path": url.lastPathComponent])
                        didChange = true
                    }
                } else {
                    // Directory (or unrecognised path): disable all tracks whose
                    // file_url starts with this URL.  This is a no-op if nothing
                    // in the DB lives under this path.
                    try? await trackRepo.disableAll(underPath: url.absoluteString)
                    self.log.info("fsevents.dir_removed", ["path": url.lastPathComponent])
                    didChange = true
                }
            } else if isDir.boolValue {
                // A whole directory was moved/created — enumerate it recursively.
                let audioFiles = self.audioFiles(under: url)
                for fileURL in audioFiles {
                    guard await self.contentChanged(url: fileURL, trackRepo: trackRepo) else { continue }
                    do {
                        _ = try await self.scanSingleFile(url: fileURL)
                        self.log.debug("fsevents.file_rescanned", ["path": fileURL.lastPathComponent])
                        didChange = true
                    } catch {
                        self.log.warning("fsevents.rescan_failed", ["path": fileURL.path, "error": "\(error)"])
                    }
                }
            } else {
                guard TagReader.isSupported(url) else { continue }
                guard await self.contentChanged(url: url, trackRepo: trackRepo) else { continue }
                do {
                    _ = try await self.scanSingleFile(url: url)
                    self.log.debug("fsevents.file_rescanned", ["path": url.lastPathComponent])
                    didChange = true
                } catch {
                    self.log.warning("fsevents.rescan_failed", ["path": url.path, "error": "\(error)"])
                }
            }
        }
        if didChange, let callback = self.onFileImported {
            await callback()
        }
    }

    /// Returns `true` when `url` needs a rescan: it is unknown to the DB,
    /// disabled, or its size/mtime differ from the stored row.
    ///
    /// FSEvents also fires for metadata-only changes (xattr, ownership,
    /// quarantine updates) that don't alter file content. Rescanning those is
    /// wasted work at best; at worst it loops — a write-intent open during the
    /// rescan makes macOS touch the quarantine metadata again, which emits the
    /// next FSEvents event. Size+mtime comparison is the same signal the quick
    /// scan's ChangeDetector uses.
    private func contentChanged(url: URL, trackRepo: TrackRepository) async -> Bool {
        guard let track = try? await trackRepo.fetchOne(fileURL: url.absoluteString),
              !track.disabled,
              let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return true }
        let size = Int64(values.fileSize ?? 0)
        let mtime = Int64(values.contentModificationDate?.timeIntervalSince1970 ?? 0)
        if size == track.fileSize, mtime == track.fileMtime {
            self.log.debug("fsevents.skip_unchanged", ["path": url.lastPathComponent])
            return false
        }
        return true
    }

    /// Returns all supported audio files found recursively under `directory`.
    ///
    /// Hidden files and hidden directories are skipped.
    func audioFiles(under directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var results: [URL] = []
        for case let fileURL as URL in enumerator {
            guard TagReader.isSupported(fileURL) else { continue }
            results.append(fileURL)
        }
        return results
    }
}
