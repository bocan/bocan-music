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

        let bookmark = try url.bookmarkData(
            options: .withSecurityScope,
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

    /// Removes a root by its database ID.
    public func removeRoot(id: Int64) async throws {
        try await self.rootRepo.delete(id: id)
        self.log.info("library.root.removed", ["id": id])
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
            Task {
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

                // Resolve bookmarks
                var resolved: [(url: URL, rootID: Int64)] = []
                for root in allRoots {
                    guard let rootID = root.id else { continue }
                    do {
                        try await SecurityScope.withAccess(root.bookmark) { url in
                            resolved.append((url, rootID))
                        }
                    } catch {
                        self.log.warning("library.root.inaccessible", ["id": rootID, "path": root.path])
                        try? await self.rootRepo.markInaccessible(id: rootID, true)
                        continuation.yield(.error(url: URL(fileURLWithPath: root.path), error: error))
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
            await watcher.watch(watchURL)
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

    /// Adds a newly registered root to an already-running watcher.
    ///
    /// Called automatically by `addRoot(_:)` when watching is active.
    func watchNewRoot(path: String) async {
        guard let watcher = self.fsWatcher else { return }
        let url = self.watchableURL(for: path)
        await watcher.watch(url)
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
    private func handleFSChange(urls: [URL]) async {
        for url in urls {
            guard !url.lastPathComponent.hasPrefix(".") else { continue }
            guard TagReader.isSupported(url) else { continue }
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                _ = try await self.scanSingleFile(url: url)
                self.log.debug("fsevents.file_rescanned", ["path": url.lastPathComponent])
            } catch {
                self.log.warning("fsevents.rescan_failed", ["path": url.path, "error": "\(error)"])
            }
        }
    }
}
