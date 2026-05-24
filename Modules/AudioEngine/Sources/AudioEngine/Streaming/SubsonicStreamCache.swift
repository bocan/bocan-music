import Foundation
import Observability

/// Actor that turns a Subsonic stream key into a local file URL the engine
/// can decode. The cache writes incoming bytes to a partial file, and
/// returns the URL as soon as enough bytes are buffered for playback to
/// start. The download continues in the background until complete (or
/// fails); the engine reads from the same file the downloader is still
/// writing to, which is what makes seek + gapless work without bolting an
/// `AVPlayer` code path onto the engine.
public actor SubsonicStreamCache {
    // MARK: - Configuration

    public struct Configuration: Sendable {
        public var rootDirectory: URL
        public var budgetBytes: Int64
        public var readyThresholdBytes: Int

        public init(
            rootDirectory: URL,
            budgetBytes: Int64 = 1_073_741_824,
            readyThresholdBytes: Int = 200 * 1024
        ) {
            self.rootDirectory = rootDirectory
            self.budgetBytes = budgetBytes
            self.readyThresholdBytes = readyThresholdBytes
        }
    }

    // MARK: - Stored state

    private let config: Configuration
    private let loader: RemoteTrackLoader
    private let log = AppLogger.make(.subsonic)
    private var entries: [SubsonicStreamKey: Entry] = [:]
    private var pinned: Set<SubsonicStreamKey> = []

    private final class Entry {
        let key: SubsonicStreamKey
        let fileURL: URL
        var totalBytes: Int64?
        var bytesWritten: Int64 = 0
        var isComplete = false
        var error: Error?
        var lastAccess: Date
        var readyContinuations: [CheckedContinuation<URL, Error>] = []
        var downloadTask: Task<Void, Never>?
        var hasSignalledReady = false

        init(key: SubsonicStreamKey, fileURL: URL, now: Date = Date()) {
            self.key = key
            self.fileURL = fileURL
            self.lastAccess = now
        }
    }

    // MARK: - Init

    public init(configuration: Configuration, loader: RemoteTrackLoader) throws {
        self.config = configuration
        self.loader = loader
        try FileManager.default.createDirectory(
            at: configuration.rootDirectory,
            withIntermediateDirectories: true
        )
    }

    // MARK: - Public API

    /// Returns a local file URL for `key` as soon as the cache has buffered
    /// enough bytes to start playback. Concurrent requests for the same key
    /// share a single download. `urlProvider` is invoked exactly once per
    /// fresh cache miss to obtain the signed Subsonic stream URL.
    public func url(
        for key: SubsonicStreamKey,
        urlProvider: @Sendable @escaping () async throws -> URL
    ) async throws -> URL {
        if let existing = self.entries[key] {
            existing.lastAccess = Date()
            if let error = existing.error { throw error }
            if existing.isComplete || existing.bytesWritten >= Int64(self.config.readyThresholdBytes) {
                return existing.fileURL
            }
            return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                existing.readyContinuations.append(cont)
            }
        }

        let fileURL = try self.fileURL(for: key)
        let entry = Entry(key: key, fileURL: fileURL)
        self.entries[key] = entry

        // Truncate any stale partial file so we start clean.
        try? FileManager.default.removeItem(at: fileURL)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)

        let resolvedURL: URL
        do {
            resolvedURL = try await urlProvider()
        } catch {
            self.entries[key] = nil
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            entry.readyContinuations.append(cont)
            entry.downloadTask = Task { [weak self] in
                await self?.runDownload(key: key, url: resolvedURL)
            }
        }
    }

    /// Mark these keys as pinned. Pinned entries are skipped by LRU
    /// eviction (i.e. tracks currently in the queue stay cached).
    public func pin(_ keys: Set<SubsonicStreamKey>) {
        self.pinned = keys
    }

    /// Current on-disk size of the cache in bytes.
    public func cacheSize() -> Int64 {
        self.entries.values.reduce(0) { $0 + $1.bytesWritten }
    }

    /// Remove every cached file for the given server. Used when a server is
    /// deleted from the user's library or its credentials change.
    public func purge(serverID: UUID) throws {
        let serverDir = self.config.rootDirectory.appendingPathComponent(serverID.uuidString, isDirectory: true)
        for (key, entry) in self.entries where key.serverID == serverID {
            entry.downloadTask?.cancel()
            entry.error = RemoteTrackLoaderError.cancelled
            for cont in entry.readyContinuations {
                cont.resume(throwing: RemoteTrackLoaderError.cancelled)
            }
            entry.readyContinuations.removeAll()
            self.entries[key] = nil
        }
        if FileManager.default.fileExists(atPath: serverDir.path) {
            try FileManager.default.removeItem(at: serverDir)
        }
    }

    /// Total entries currently tracked in memory. Exposed for tests.
    public func entryCount() -> Int {
        self.entries.count
    }

    /// `true` iff the cache has an entry for `key` (regardless of completion).
    public func contains(_ key: SubsonicStreamKey) -> Bool {
        self.entries[key] != nil
    }

    // MARK: - Download pump

    private func runDownload(key: SubsonicStreamKey, url: URL) async {
        guard let entry = self.entries[key] else { return }
        let threshold = Int64(self.config.readyThresholdBytes)

        let bytes: RemoteTrackBytes
        do {
            bytes = try await self.loader.loadBytes(from: url)
        } catch {
            self.fail(entry: entry, with: error)
            return
        }
        entry.totalBytes = bytes.totalBytes
        // Short tracks: drop the ready threshold to the file size so we
        // don't block forever waiting for 200 KB on a 60 KB voice memo.
        let effectiveThreshold: Int64 = {
            guard let total = bytes.totalBytes else { return threshold }
            return min(threshold, total)
        }()

        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: entry.fileURL)
        } catch {
            self.fail(entry: entry, with: error)
            return
        }
        defer { try? handle.close() }

        self.log.debug("subsonic.cache.download.start", [
            "songID": key.songID,
            "format": key.format,
            "kbps": key.bitrateKbps ?? -1,
            "total": bytes.totalBytes ?? -1,
        ])

        do {
            for try await chunk in bytes.stream {
                if Task.isCancelled {
                    throw RemoteTrackLoaderError.cancelled
                }
                try handle.write(contentsOf: chunk)
                entry.bytesWritten += Int64(chunk.count)
                if !entry.hasSignalledReady, entry.bytesWritten >= effectiveThreshold {
                    entry.hasSignalledReady = true
                    self.signalReady(entry: entry)
                }
            }
            entry.isComplete = true
            // EOF arrived before we hit the threshold (very short track):
            // signal ready now so any waiters unblock with the whole file.
            if !entry.hasSignalledReady {
                entry.hasSignalledReady = true
                self.signalReady(entry: entry)
            }
            self.log.info("subsonic.cache.download.complete", [
                "songID": key.songID,
                "bytes": entry.bytesWritten,
            ])
            await self.evictIfNeeded()
        } catch {
            self.fail(entry: entry, with: error)
        }
    }

    private func signalReady(entry: Entry) {
        let conts = entry.readyContinuations
        entry.readyContinuations.removeAll()
        for cont in conts {
            cont.resume(returning: entry.fileURL)
        }
    }

    private func fail(entry: Entry, with error: Error) {
        entry.error = error
        let conts = entry.readyContinuations
        entry.readyContinuations.removeAll()
        for cont in conts {
            cont.resume(throwing: error)
        }
        try? FileManager.default.removeItem(at: entry.fileURL)
        self.entries[entry.key] = nil
        self.log.error("subsonic.cache.download.failed", [
            "songID": entry.key.songID,
            "error": String(reflecting: error),
        ])
    }

    // MARK: - Eviction

    /// LRU-evict completed, non-pinned entries until the cache is back under
    /// budget. Incomplete downloads are never evicted (we'd lose live data).
    private func evictIfNeeded() async {
        var totalSize = self.cacheSize()
        guard totalSize > self.config.budgetBytes else { return }
        let candidates = self.entries.values
            .filter { $0.isComplete && !self.pinned.contains($0.key) }
            .sorted { $0.lastAccess < $1.lastAccess }
        for entry in candidates {
            if totalSize <= self.config.budgetBytes { break }
            try? FileManager.default.removeItem(at: entry.fileURL)
            totalSize -= entry.bytesWritten
            self.entries[entry.key] = nil
            self.log.debug("subsonic.cache.evict", [
                "songID": entry.key.songID,
                "bytes": entry.bytesWritten,
            ])
        }
    }

    // MARK: - Filesystem

    private func fileURL(for key: SubsonicStreamKey) throws -> URL {
        let serverDir = self.config.rootDirectory
            .appendingPathComponent(key.serverID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: serverDir, withIntermediateDirectories: true)
        return serverDir.appendingPathComponent(key.cacheFilename)
    }
}
