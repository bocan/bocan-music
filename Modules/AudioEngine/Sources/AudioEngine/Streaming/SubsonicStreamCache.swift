import Foundation
import Network
import Observability

/// Actor that turns a Subsonic stream key into a local file URL the engine
/// can decode. The cache writes incoming bytes to a partial file and returns
/// the URL only once the download has fully completed.
///
/// **Why wait for the whole file?** The engine decodes via `AVAudioFile`,
/// which snapshots the track's frame count at open time. If we returned the
/// URL mid-download, the decoder would treat whatever bytes happened to be
/// on disk as the entire track — playback would stop early (e.g. ~18 s on a
/// 200 KB sample of an MP3) with no warning. Waiting for `isComplete = true`
/// is the only correctness-preserving option without swapping the decoder.
public actor SubsonicStreamCache {
    // MARK: - Configuration

    public struct Configuration: Sendable {
        public var rootDirectory: URL
        public var budgetBytes: Int64

        public init(
            rootDirectory: URL,
            budgetBytes: Int64 = 1_073_741_824
        ) {
            self.rootDirectory = rootDirectory
            self.budgetBytes = budgetBytes
        }
    }

    // MARK: - Stored state

    private let config: Configuration
    private let loader: RemoteTrackLoader
    private let log = AppLogger.make(.subsonic)
    private var entries: [SubsonicStreamKey: Entry] = [:]
    private var pinned: Set<SubsonicStreamKey> = []
    private let pathMonitor: NWPathMonitor

    private final class Entry {
        let key: SubsonicStreamKey
        /// Mutable so the cache can rename the file to a real audio
        /// extension once the magic bytes are known (see `finaliseExtension`).
        var fileURL: URL
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

    /// Create a cache rooted at `configuration.rootDirectory`, using `loader` to
    /// stream remote bytes. Creates the root directory if it does not exist.
    public init(configuration: Configuration, loader: RemoteTrackLoader) throws {
        self.config = configuration
        self.loader = loader
        try FileManager.default.createDirectory(
            at: configuration.rootDirectory,
            withIntermediateDirectories: true
        )
        // All stored properties are now initialised; safe to capture self.
        self.pathMonitor = NWPathMonitor()
        let monitor = self.pathMonitor
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            Task { await self.handlePathChange(satisfied: path.status == .satisfied) }
        }
        monitor.start(queue: DispatchQueue(
            label: "io.cloudcauldron.bocan.streamcache.path",
            qos: .utility
        ))
    }

    deinit {
        pathMonitor.cancel()
    }

    // MARK: - Public API

    /// Returns a local file URL for `key` once the whole track has been
    /// downloaded. Concurrent requests for the same key share a single
    /// download. `urlProvider` is invoked exactly once per fresh cache miss
    /// to obtain the signed Subsonic stream URL.
    public func url(
        for key: SubsonicStreamKey,
        urlProvider: @Sendable @escaping () async throws -> URL
    ) async throws -> URL {
        if let existing = self.entries[key] {
            existing.lastAccess = Date()
            if let error = existing.error { throw error }
            if existing.isComplete {
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

    // MARK: - Network path monitoring

    /// Called whenever the NWPathMonitor reports a path change.
    /// On path loss, in-flight downloads are cancelled immediately so TCP
    /// timeouts don't block playback for ~60 s waiting to fail.
    private func handlePathChange(satisfied: Bool) {
        guard !satisfied else { return }
        self.cancelInFlightDownloads()
    }

    /// Cancel every incomplete download and fail any pending ready-waiters.
    /// Completed cached entries are left intact — they remain valid to read.
    /// The next call to `url(for:urlProvider:)` will start a fresh download.
    private func cancelInFlightDownloads() {
        let incomplete = self.entries.filter { !$1.isComplete }
        guard !incomplete.isEmpty else { return }
        for (key, entry) in incomplete {
            entry.downloadTask?.cancel()
            for cont in entry.readyContinuations {
                cont.resume(throwing: RemoteTrackLoaderError.cancelled)
            }
            entry.readyContinuations.removeAll()
            try? FileManager.default.removeItem(at: entry.fileURL)
            self.entries[key] = nil
        }
        self.log.info("subsonic.cache.network.lost", ["cancelled": incomplete.count])
    }

    // MARK: - Download pump

    private func runDownload(key: SubsonicStreamKey, url: URL) async {
        guard let entry = self.entries[key] else { return }

        let bytes: RemoteTrackBytes
        do {
            bytes = try await self.loader.loadBytes(from: url)
        } catch {
            self.fail(entry: entry, with: error)
            return
        }
        entry.totalBytes = bytes.totalBytes

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
            }
            // Close the writer before sniffing so the read sees a flushed file.
            try? handle.close()
            entry.isComplete = true
            self.finaliseExtension(for: entry)
            if !entry.hasSignalledReady {
                entry.hasSignalledReady = true
                self.signalReady(entry: entry)
            }
            self.log.info("subsonic.cache.download.complete", [
                "songID": key.songID,
                "bytes": entry.bytesWritten,
                "ext": entry.fileURL.pathExtension,
            ])
            await self.evictIfNeeded()
        } catch {
            self.fail(entry: entry, with: error)
        }
    }

    // MARK: - Format sniffing

    /// If the entry's file is named with the generic `.bin` extension
    /// (i.e. the format was `"original"` / unknown), sniff its magic bytes
    /// and rename it to the correct audio extension. AVFoundation's
    /// content-type detection is unreliable for a `.bin` input — Opus,
    /// Vorbis, and some FLAC variants fail with `kAudioFileUnsupportedFile`
    /// (`'typ?'`). Giving the file a real extension routes the file
    /// through the matching decoder.
    private func finaliseExtension(for entry: Entry) {
        guard entry.fileURL.pathExtension.lowercased() == "bin" else { return }
        guard let ext = Self.detectAudioExtension(at: entry.fileURL) else { return }
        let newURL = entry.fileURL.deletingPathExtension().appendingPathExtension(ext)
        do {
            // moveItem fails if the destination exists. Clear it first.
            try? FileManager.default.removeItem(at: newURL)
            try FileManager.default.moveItem(at: entry.fileURL, to: newURL)
            entry.fileURL = newURL
        } catch {
            self.log.warning("subsonic.cache.rename.failed", [
                "songID": entry.key.songID,
                "error": String(reflecting: error),
            ])
        }
    }

    /// Returns the appropriate audio file extension based on the first
    /// few bytes of `fileURL`, or `nil` if no known signature is found.
    /// Covers the formats Navidrome / Subsonic servers commonly serve as
    /// `original`: MP3, FLAC, OGG, Opus, WAV, AIFF, M4A/AAC.
    static func detectAudioExtension(at fileURL: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64) else { return nil }
        let b = Array(data)
        guard b.count >= 4 else { return nil }

        // FLAC: "fLaC"
        if b.starts(with: [0x66, 0x4C, 0x61, 0x43]) { return "flac" }
        // Ogg container: "OggS". Inspect the payload to distinguish Opus vs Vorbis vs FLAC-in-Ogg.
        if b.starts(with: [0x4F, 0x67, 0x67, 0x53]) {
            if b.count >= 36, b[28 ..< 36].elementsEqual([0x4F, 0x70, 0x75, 0x73, 0x48, 0x65, 0x61, 0x64]) {
                return "opus"
            }
            return "ogg"
        }
        // RIFF / WAVE
        if b.count >= 12, b.starts(with: [0x52, 0x49, 0x46, 0x46]),
           b[8 ..< 12].elementsEqual([0x57, 0x41, 0x56, 0x45]) {
            return "wav"
        }
        // AIFF / AIFC: "FORM" .. "AIFF" or "AIFC"
        if b.count >= 12, b.starts(with: [0x46, 0x4F, 0x52, 0x4D]),
           b[8 ..< 12].elementsEqual([0x41, 0x49, 0x46, 0x46])
           || b[8 ..< 12].elementsEqual([0x41, 0x49, 0x46, 0x43]) {
            return "aiff"
        }
        // MP4/M4A: "ftyp" at offset 4
        if b.count >= 8, b[4] == 0x66, b[5] == 0x74, b[6] == 0x79, b[7] == 0x70 {
            return "m4a"
        }
        // MP3 with ID3v2: "ID3"
        if b.starts(with: [0x49, 0x44, 0x33]) { return "mp3" }
        // MP3 frame sync (11 bits set: 0xFF Ex)
        if b[0] == 0xFF, (b[1] & 0xE0) == 0xE0 { return "mp3" }

        return nil
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
