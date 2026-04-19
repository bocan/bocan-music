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
        var root = LibraryRoot(
            id: nil,
            path: url.path,
            bookmark: bookmark,
            addedAt: now,
            isInaccessible: false
        )
        try await self.rootRepo.upsert(root)
        self.log.info("library.root.added", ["path": url.path])
        _ = root // suppress warning
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

    // MARK: - FSWatcher

    /// Starts watching all current library roots for file-system changes.
    public func startWatching() async {
        guard self.fsWatcher == nil else { return }
        let allRoots = await (try? self.rootRepo.fetchAll()) ?? []

        let watcher = FSWatcher { [log] urls in
            log.debug("fsevents.change", ["count": urls.count])
            // Phase 3 incremental re-import is handled by ScanCoordinator.
            // For now, events are logged; full incremental handling is Phase 4+.
        }

        for root in allRoots {
            guard let _ = root.id else { continue }
            do {
                try await SecurityScope.withAccess(root.bookmark) { url in
                    await watcher.watch(url)
                }
            } catch {
                self.log.warning("fsevents.bookmark_stale", ["path": root.path])
            }
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
}
