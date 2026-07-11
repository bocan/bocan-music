import CryptoKit
import Foundation
import Observability
import Persistence

/// Backfills `tracks.content_hash` in the background: the whole-file SHA-256
/// that Phone Sync serves as the manifest `sha256`, the download `ETag`, and
/// the `If-Match` basis. A track without it cannot appear in a sync manifest.
///
/// The scanner does not hash at import time, and a changed file's re-import
/// resets the column to NULL (the correct invalidation: the old digest no
/// longer matches the bytes on disk). This service watches the library and
/// fills whatever is missing: a debounced ValueObservation on the missing-hash
/// count starts the launch backfill via its initial emission and re-triggers
/// after any scan or re-import that leaves NULL hashes behind.
///
/// Passes are sequential (one file at a time, polite to the disk), cursor
/// based so an unreadable file is skipped rather than refetched forever, and
/// cooperatively cancellable between files and between read chunks.
public actor ContentHashService {
    private let tracks: TrackRepository
    private let debounce: Duration
    private let batchSize: Int
    private let log = AppLogger.make(.library)

    private var observationTask: Task<Void, Never>?
    private var pendingRun: Task<Void, Never>?
    private var runningPass: Task<Void, Never>?

    public init(tracks: TrackRepository, debounce: Duration = .seconds(5), batchSize: Int = 64) {
        self.tracks = tracks
        self.debounce = debounce
        self.batchSize = batchSize
    }

    /// Begins observing. The initial emission is deliberately not skipped: at
    /// launch it starts the backfill for whatever the last session left
    /// unhashed.
    public func start() {
        guard self.observationTask == nil else { return }
        self.observationTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.tracks.observeMissingContentHashCount()
            do {
                for try await missing in stream where missing > 0 {
                    await self.scheduleRun()
                }
            } catch {
                await self.observationFailed(error)
            }
        }
    }

    public func stop() {
        self.observationTask?.cancel()
        self.observationTask = nil
        self.pendingRun?.cancel()
        self.pendingRun = nil
        self.runningPass?.cancel()
        self.runningPass = nil
    }

    private func scheduleRun() {
        self.pendingRun?.cancel()
        self.pendingRun = Task {
            try? await Task.sleep(for: self.debounce)
            guard !Task.isCancelled else { return }
            self.startPassIfIdle()
        }
    }

    /// A pass already underway covers the tracks that scheduled this run; any
    /// track it misses re-emits through the observation once the pass's own
    /// writes go quiet, so skipping here never strands work.
    private func startPassIfIdle() {
        guard self.runningPass == nil else { return }
        self.runningPass = Task(priority: .utility) { [weak self] in
            await self?.backfillOnce()
            await self?.passFinished()
        }
    }

    private func passFinished() {
        self.runningPass = nil
    }

    /// One full pass over every track currently missing a hash. Internal so
    /// tests can drive a pass directly without the observation machinery.
    func backfillOnce() async {
        let start = Date()
        var hashed = 0
        var failed = 0
        var cursor: Int64 = 0
        do {
            let missing = try await self.tracks.countMissingContentHash()
            guard missing > 0 else { return }
            self.log.debug("content_hash.pass.start", ["missing": missing])
            while true {
                try Task.checkCancellation()
                let batch = try await self.tracks.fetchMissingContentHash(limit: self.batchSize, afterID: cursor)
                guard !batch.isEmpty else { break }
                for track in batch {
                    try Task.checkCancellation()
                    guard let id = track.id else { continue }
                    cursor = max(cursor, id)
                    if await self.hashOne(track, id: id) {
                        hashed += 1
                    } else {
                        failed += 1
                    }
                }
            }
        } catch is CancellationError {
            self.log.debug("content_hash.pass.cancelled", ["hashed": hashed])
            return
        } catch {
            self.log.error("content_hash.pass.failed", ["error": String(reflecting: error)])
        }
        self.log.info("content_hash.pass.end", [
            "hashed": hashed,
            "failed": failed,
            "ms": Int(-start.timeIntervalSinceNow * 1000),
        ])
    }

    /// Hashes a single track's file and stores the digest. Returns `false` on
    /// any failure (missing file, unreadable bookmark, write error); the
    /// cursor has already moved past the track, so a broken file costs one
    /// attempt per pass, never a loop.
    private func hashOne(_ track: Track, id: Int64) async -> Bool {
        guard let bookmark = track.fileBookmark else { return false }
        do {
            let hash = try await SecurityScope.withAccess(bookmark) { url in
                try Self.sha256Hex(ofFileAt: url)
            }
            try await self.tracks.setContentHash(trackID: id, hash: hash)
            return true
        } catch is CancellationError {
            return false
        } catch {
            self.log.warning("content_hash.file.failed", [
                "id": id,
                "url": track.fileURL,
                "error": String(reflecting: error),
            ])
            return false
        }
    }

    /// Streams the file through SHA-256 in 1 MiB chunks (never loading it
    /// whole) and returns the lowercase-hex digest. Checks for cancellation
    /// between chunks so a stop request interrupts even a huge file promptly.
    static func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func observationFailed(_ error: any Error) {
        self.log.warning("content_hash.observe.failed", ["error": String(reflecting: error)])
    }
}
