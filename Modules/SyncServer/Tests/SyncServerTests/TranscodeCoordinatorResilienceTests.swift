import AudioEngine
import Foundation
import Persistence
import Testing
@testable import SyncServer

// MARK: - Test encoders

/// Records every attempt and fails the configured track ids, so the failure
/// memo can be observed hermetically.
private final class FailingEncoder: ArtifactEncoding, @unchecked Sendable {
    private struct EncodeRefused: Error {}

    private let lock = NSLock()
    private var _failingTrackIDs: Set<Int64> = []
    private var _attempts: [Int64] = []

    var attemptedTrackIDs: [Int64] {
        self.lock.withLock { self._attempts }
    }

    func setFailing(_ ids: Set<Int64>) {
        self.lock.withLock { self._failingTrackIDs = ids }
    }

    func encode(
        source _: URL,
        destination: URL,
        preset: TranscodePreset,
        metadata _: [String: String]
    ) async throws -> TranscodeResult {
        let trackID = Int64(destination.lastPathComponent.split(separator: "-").first ?? "") ?? -1
        let shouldFail = self.lock.withLock {
            self._attempts.append(trackID)
            return self._failingTrackIDs.contains(trackID)
        }
        if shouldFail { throw EncodeRefused() }
        try Data(repeating: 0xAB, count: 100).write(to: destination)
        return TranscodeResult(sha256: String(repeating: "ab", count: 32), size: 100, bitrateKbps: preset.targetKbps)
    }
}

/// Blocks its first encode on a gate the test opens, and records whether the
/// gated encode's task was cancelled while it waited: the direct signature of
/// the old self-cancel bug.
private final class GatedEncoder: ArtifactEncoding, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    private var gateArmed = true
    private var _started = false
    private var _cancelledDuringGate = false
    private var _encodedTrackIDs: [Int64] = []

    var started: Bool {
        self.lock.withLock { self._started }
    }

    var cancelledDuringGate: Bool {
        self.lock.withLock { self._cancelledDuringGate }
    }

    var encodedTrackIDs: [Int64] {
        self.lock.withLock { self._encodedTrackIDs }
    }

    /// Releases the gated first encode (safe to call before it arrives).
    func open() {
        let waiting = self.lock.withLock {
            self.opened = true
            let held = self.continuation
            self.continuation = nil
            return held
        }
        waiting?.resume()
    }

    func encode(
        source _: URL,
        destination: URL,
        preset: TranscodePreset,
        metadata _: [String: String]
    ) async throws -> TranscodeResult {
        let shouldGate = self.lock.withLock {
            self._started = true
            let gate = self.gateArmed
            self.gateArmed = false
            return gate
        }
        if shouldGate {
            await withCheckedContinuation { held in
                let resumeNow = self.lock.withLock {
                    if self.opened { return true }
                    self.continuation = held
                    return false
                }
                if resumeNow { held.resume() }
            }
            self.lock.withLock { self._cancelledDuringGate = Task.isCancelled }
        }
        try Data(repeating: 0xCD, count: 100).write(to: destination)
        let trackID = Int64(destination.lastPathComponent.split(separator: "-").first ?? "") ?? -1
        self.lock.withLock { self._encodedTrackIDs.append(trackID) }
        return TranscodeResult(sha256: String(repeating: "cd", count: 32), size: 100, bitrateKbps: preset.targetKbps)
    }
}

// MARK: - TranscodeCoordinatorResilienceTests

/// The two anti-thrash behaviours: a running pass is never cancelled by its
/// own ledger writes, and a file that fails to encode is not retried until
/// its source changes.
@Suite("TranscodeCoordinator resilience")
struct TranscodeCoordinatorResilienceTests {
    @discardableResult
    private func insertTrack(
        _ tracks: TrackRepository,
        title: String,
        contentHash: String?,
        isLossless: Bool? = nil,
        bitrate: Int? = nil
    ) async throws -> Int64 {
        let now = Int64(Date().timeIntervalSince1970)
        var track = Track(
            fileURL: "file:///tmp/\(UUID().uuidString).flac",
            fileSize: 1024,
            fileMtime: now,
            fileFormat: "flac",
            duration: 200,
            title: title,
            addedAt: now,
            updatedAt: now
        )
        track.contentHash = contentHash
        track.isLossless = isLossless
        track.bitrate = bitrate
        return try await tracks.insert(track)
    }

    private func setDocument(_ profiles: SyncProfileRepository, preset: TranscodePreset?) async throws {
        let document = SyncProfileDocument(
            profile: .everything(includePodcasts: false),
            transcode: TranscodeSettings(preset: preset)
        )
        try await profiles.setProfileJSON(document.encoded())
    }

    /// Polls `condition` every 20 ms until true or the deadline passes; the
    /// assertion on the condition follows separately.
    private func poll(
        deadline: Duration = .seconds(5),
        until condition: () async throws -> Bool
    ) async throws {
        let end = ContinuousClock.now.advanced(by: deadline)
        while try await !condition(), ContinuousClock.now < end {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func removeIfPresent(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    @Test("a change event during a running pass defers to a follow-up instead of cancelling")
    func changeDuringPassDefersInsteadOfCancelling() async throws {
        let database = try await Database(location: .inMemory)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sync-transcode-\(UUID().uuidString)")
        let store = TranscodeStore(root: root)
        let encoder = GatedEncoder()
        let coordinator = TranscodeCoordinator(
            database: database,
            store: store,
            encoder: encoder,
            prepareWindowBytes: .max / 2,
            debounce: .milliseconds(10)
        )
        let tracks = TrackRepository(database: database)
        let ledger = SyncTranscodeRepository(database: database)
        let first = try await insertTrack(tracks, title: "A", contentHash: "h-a", isLossless: true)
        let second = try await insertTrack(tracks, title: "B", contentHash: "h-b", isLossless: true)
        try await self.setDocument(SyncProfileRepository(database: database), preset: .opus128)

        await coordinator.start()
        try await self.poll { encoder.started }
        #expect(encoder.started, "the initial pass reached the first encode")
        // Let the observation attach before the change lands.
        try await Task.sleep(for: .milliseconds(100))

        // A library change while the first encode is mid-flight. The old
        // behaviour cancelled the running pass here; the fix defers.
        _ = try await self.insertTrack(tracks, title: "S", contentHash: "h-s", bitrate: 96)
        try await self.poll { await coordinator.rerunRequested }
        #expect(await coordinator.rerunRequested, "the mid-pass change is deferred, not acted on")

        encoder.open()
        try await self.poll { try await ledger.allValid(preset: "opus_128").count == 2 }
        #expect(!encoder.cancelledDuringGate, "the in-flight encode must survive the change event")
        #expect(Set(encoder.encodedTrackIDs) == [first, second], "one pass finishes all pending work")

        await coordinator.stop()
        try self.removeIfPresent(root)
    }

    @Test("a failed encode is skipped by later passes until the source hash changes")
    func failedEncodeIsNotRetried() async throws {
        let database = try await Database(location: .inMemory)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sync-transcode-\(UUID().uuidString)")
        let store = TranscodeStore(root: root)
        let encoder = FailingEncoder()
        let coordinator = TranscodeCoordinator(
            database: database,
            store: store,
            encoder: encoder,
            prepareWindowBytes: .max / 2,
            debounce: .milliseconds(10)
        )
        let tracks = TrackRepository(database: database)
        let ledger = SyncTranscodeRepository(database: database)
        let bad = try await insertTrack(tracks, title: "Bad", contentHash: "h-bad", isLossless: true)
        let good = try await insertTrack(tracks, title: "Good", contentHash: "h-good", isLossless: true)
        try await self.setDocument(SyncProfileRepository(database: database), preset: .opus128)
        encoder.setFailing([bad])

        await coordinator.runPass()
        #expect(encoder.attemptedTrackIDs.count(where: { $0 == bad }) == 1)
        #expect(try await ledger.allValid(preset: "opus_128").map(\.trackID) == [good])

        await coordinator.runPass()
        #expect(
            encoder.attemptedTrackIDs.count(where: { $0 == bad }) == 1,
            "the memo skips the known-bad file"
        )

        // A repaired file (new content hash) gets one fresh try.
        encoder.setFailing([])
        var track = try await tracks.fetch(id: bad)
        track.contentHash = "h-fixed"
        _ = try await tracks.upsert(track)
        await coordinator.runPass()
        #expect(encoder.attemptedTrackIDs.count(where: { $0 == bad }) == 2)
        #expect(try await ledger.allValid(preset: "opus_128").count == 2)

        try self.removeIfPresent(root)
    }
}
