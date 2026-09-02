import AudioEngine
import Foundation
import Persistence
import Testing
@testable import SyncServer

// MARK: - FakeEncoder

/// Hermetic stand-in for AudioTranscoder: writes deterministic bytes and
/// records the order of encodes, so no FFmpeg or audio fixtures are needed.
private final class FakeEncoder: ArtifactEncoding, @unchecked Sendable {
    private let lock = NSLock()
    private var _destinations: [URL] = []
    let bytesPerFile: Int

    init(bytesPerFile: Int = 100) {
        self.bytesPerFile = bytesPerFile
    }

    var destinations: [URL] {
        self.lock.withLock { self._destinations }
    }

    var encodeCount: Int {
        self.destinations.count
    }

    /// Track ids parsed from the artifact filenames, in encode order.
    var encodedTrackIDs: [Int64] {
        self.destinations.compactMap { url in
            Int64(url.lastPathComponent.split(separator: "-").first ?? "")
        }
    }

    func encode(
        source _: URL,
        destination: URL,
        preset: TranscodePreset,
        metadata _: [String: String]
    ) async throws -> TranscodeResult {
        let data = Data(repeating: 0xAB, count: self.bytesPerFile)
        try data.write(to: destination)
        self.lock.withLock { self._destinations.append(destination) }
        return TranscodeResult(
            sha256: String(repeating: "ab", count: 32),
            size: Int64(self.bytesPerFile),
            bitrateKbps: preset.targetKbps
        )
    }
}

// MARK: - TranscodeCoordinatorTests

@Suite("TranscodeCoordinator")
struct TranscodeCoordinatorTests {
    private struct Fixture {
        let database: Database
        let coordinator: TranscodeCoordinator
        let encoder: FakeEncoder
        let store: TranscodeStore
        let ledger: SyncTranscodeRepository
        let tracks: TrackRepository
        let profiles: SyncProfileRepository
        let root: URL
    }

    private func makeFixture(prepareWindowBytes: Int64 = .max / 2) async throws -> Fixture {
        let database = try await Database(location: .inMemory)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sync-transcode-\(UUID().uuidString)")
        let store = TranscodeStore(root: root)
        let encoder = FakeEncoder()
        let coordinator = TranscodeCoordinator(
            database: database,
            store: store,
            encoder: encoder,
            prepareWindowBytes: prepareWindowBytes,
            debounce: .milliseconds(10)
        )
        return Fixture(
            database: database,
            coordinator: coordinator,
            encoder: encoder,
            store: store,
            ledger: SyncTranscodeRepository(database: database),
            tracks: TrackRepository(database: database),
            profiles: SyncProfileRepository(database: database),
            root: root
        )
    }

    private func cleanup(_ fixture: Fixture) throws {
        if FileManager.default.fileExists(atPath: fixture.root.path) {
            try FileManager.default.removeItem(at: fixture.root)
        }
    }

    @discardableResult
    private func insertTrack(
        _ fixture: Fixture,
        title: String,
        contentHash: String,
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
        return try await fixture.tracks.insert(track)
    }

    private func setDocument(
        _ fixture: Fixture,
        preset: TranscodePreset?,
        keepArtifacts: Bool = false
    ) async throws {
        let document = SyncProfileDocument(
            profile: .everything(includePodcasts: false),
            transcode: TranscodeSettings(preset: preset, keepArtifacts: keepArtifacts)
        )
        try await fixture.profiles.setProfileJSON(document.encoded())
    }

    // MARK: - The predicate and the pass

    @Test("a pass encodes lossless and above-target tracks; at-or-below lossy passes through")
    func passAppliesThePredicate() async throws {
        let fixture = try await makeFixture()
        let lossless = try await insertTrack(fixture, title: "L", contentHash: "h-l", isLossless: true)
        let bigLossy = try await insertTrack(fixture, title: "B", contentHash: "h-b", bitrate: 320)
        _ = try await self.insertTrack(fixture, title: "S", contentHash: "h-s", bitrate: 96)
        try await self.setDocument(fixture, preset: .opus128)

        await fixture.coordinator.runPass()

        let rows = try await fixture.ledger.allValid(preset: "opus_128")
        #expect(Set(rows.map(\.trackID)) == [lossless, bigLossy])
        #expect(fixture.store.exists(trackID: lossless, sourceContentHash: "h-l", preset: .opus128))
        #expect(fixture.store.exists(trackID: bigLossy, sourceContentHash: "h-b", preset: .opus128))
        #expect(fixture.encoder.encodeCount == 2)
        // A second pass finds nothing to do.
        await fixture.coordinator.runPass()
        #expect(fixture.encoder.encodeCount == 2)

        try self.cleanup(fixture)
    }

    @Test("switching preset clears the old rung's rows and bytes")
    func presetSwitchClearsOldRung() async throws {
        let fixture = try await makeFixture()
        let id = try await insertTrack(fixture, title: "L", contentHash: "h1", isLossless: true)
        try await self.setDocument(fixture, preset: .opus128)
        await fixture.coordinator.runPass()
        #expect(try await fixture.ledger.allValid(preset: "opus_128").count == 1)

        try await self.setDocument(fixture, preset: .mp3320)
        await fixture.coordinator.runPass()

        #expect(try await fixture.ledger.allValid(preset: "opus_128").isEmpty)
        #expect(!fixture.store.exists(trackID: id, sourceContentHash: "h1", preset: .opus128))
        #expect(try await fixture.ledger.allValid(preset: "mp3_320").map(\.trackID) == [id])

        try self.cleanup(fixture)
    }

    @Test("selecting Original clears every rung")
    func originalClearsEverything() async throws {
        let fixture = try await makeFixture()
        let id = try await insertTrack(fixture, title: "L", contentHash: "h1", isLossless: true)
        try await self.setDocument(fixture, preset: .opus128)
        await fixture.coordinator.runPass()

        try await self.setDocument(fixture, preset: nil)
        await fixture.coordinator.runPass()

        #expect(try await fixture.ledger.allValid(preset: "opus_128").isEmpty)
        #expect(!fixture.store.exists(trackID: id, sourceContentHash: "h1", preset: .opus128))

        try self.cleanup(fixture)
    }

    // MARK: - Prepare-and-release

    @Test("the release sweep deletes served bytes but keeps the row, without re-encoding")
    func releaseSweepDeletesServedBytes() async throws {
        let fixture = try await makeFixture()
        let id = try await insertTrack(fixture, title: "L", contentHash: "h1", isLossless: true)
        try await self.setDocument(fixture, preset: .opus128)
        await fixture.coordinator.runPass()

        try await fixture.ledger.stampServed(trackID: id, preset: "opus_128", at: 1_756_000_000)
        await fixture.coordinator.runPass()

        #expect(!fixture.store.exists(trackID: id, sourceContentHash: "h1", preset: .opus128))
        #expect(try await fixture.ledger.allValid(preset: "opus_128").map(\.trackID) == [id])
        #expect(fixture.encoder.encodeCount == 1)

        try self.cleanup(fixture)
    }

    @Test("the keep toggle suppresses the release sweep")
    func keepTogglePreservesServedBytes() async throws {
        let fixture = try await makeFixture()
        let id = try await insertTrack(fixture, title: "L", contentHash: "h1", isLossless: true)
        try await self.setDocument(fixture, preset: .opus128, keepArtifacts: true)
        await fixture.coordinator.runPass()

        try await fixture.ledger.stampServed(trackID: id, preset: "opus_128", at: 1_756_000_000)
        await fixture.coordinator.runPass()

        #expect(fixture.store.exists(trackID: id, sourceContentHash: "h1", preset: .opus128))

        try self.cleanup(fixture)
    }

    @Test("the prepare window parks the pass and resumes after release")
    func prepareWindowParksAndResumes() async throws {
        let fixture = try await makeFixture(prepareWindowBytes: 100)
        let first = try await insertTrack(fixture, title: "A", contentHash: "h-a", isLossless: true)
        let second = try await insertTrack(fixture, title: "B", contentHash: "h-b", isLossless: true)
        try await self.setDocument(fixture, preset: .opus128)

        await fixture.coordinator.runPass()
        #expect(fixture.encoder.encodeCount == 1, "the 100-byte window holds exactly one 100-byte artifact")

        // The phone drains the window: stamp whichever got encoded as served.
        let encoded = try #require(fixture.encoder.encodedTrackIDs.first)
        try await fixture.ledger.stampServed(trackID: encoded, preset: "opus_128", at: 1_756_000_000)
        await fixture.coordinator.runPass()

        #expect(fixture.encoder.encodeCount == 2)
        let rows = try await fixture.ledger.allValid(preset: "opus_128")
        #expect(Set(rows.map(\.trackID)) == [first, second])

        try self.cleanup(fixture)
    }

    @Test("the keep toggle lifts the prepare window")
    func keepToggleLiftsWindow() async throws {
        let fixture = try await makeFixture(prepareWindowBytes: 100)
        let first = try await insertTrack(fixture, title: "A", contentHash: "h-a", isLossless: true)
        let second = try await insertTrack(fixture, title: "B", contentHash: "h-b", isLossless: true)
        try await self.setDocument(fixture, preset: .opus128, keepArtifacts: true)

        await fixture.coordinator.runPass()

        #expect(fixture.encoder.encodeCount == 2, "keep-artifacts prepares the whole selection up front")
        let rows = try await fixture.ledger.allValid(preset: "opus_128")
        #expect(Set(rows.map(\.trackID)) == [first, second])

        try self.cleanup(fixture)
    }

    // MARK: - Invalidation

    @Test("a retagged source re-encodes and the stale artifact goes")
    func retagReencodes() async throws {
        let fixture = try await makeFixture()
        let id = try await insertTrack(fixture, title: "L", contentHash: "h-old", isLossless: true)
        try await self.setDocument(fixture, preset: .opus128)
        await fixture.coordinator.runPass()
        #expect(fixture.store.exists(trackID: id, sourceContentHash: "h-old", preset: .opus128))

        var track = try await fixture.tracks.fetch(id: id)
        track.contentHash = "h-new"
        _ = try await fixture.tracks.upsert(track)
        await fixture.coordinator.runPass()

        #expect(!fixture.store.exists(trackID: id, sourceContentHash: "h-old", preset: .opus128))
        #expect(fixture.store.exists(trackID: id, sourceContentHash: "h-new", preset: .opus128))
        let rows = try await fixture.ledger.allValid(preset: "opus_128")
        #expect(rows.map(\.sourceContentHash) == ["h-new"])

        try self.cleanup(fixture)
    }

    @Test("tracks that leave the selection lose their rows and bytes")
    func deselectionReaps() async throws {
        let fixture = try await makeFixture()
        let id = try await insertTrack(fixture, title: "L", contentHash: "h1", isLossless: true)
        try await self.setDocument(fixture, preset: .opus128)
        await fixture.coordinator.runPass()
        #expect(try await fixture.ledger.allValid(preset: "opus_128").count == 1)

        // An empty playlist selection selects nothing.
        let document = SyncProfileDocument(
            profile: .selected(playlistIds: [], includePodcasts: false),
            transcode: TranscodeSettings(preset: .opus128)
        )
        try await fixture.profiles.setProfileJSON(document.encoded())
        await fixture.coordinator.runPass()

        #expect(try await fixture.ledger.allValid(preset: "opus_128").isEmpty)
        #expect(!fixture.store.exists(trackID: id, sourceContentHash: "h1", preset: .opus128))

        try self.cleanup(fixture)
    }

    // MARK: - Ordering and signalling

    @Test("an urgent request encodes first")
    func urgentGoesFirst() async throws {
        let fixture = try await makeFixture()
        let first = try await insertTrack(fixture, title: "A", contentHash: "h-a", isLossless: true)
        let second = try await insertTrack(fixture, title: "B", contentHash: "h-b", isLossless: true)
        try await self.setDocument(fixture, preset: .opus128)

        await fixture.coordinator.requestUrgent(trackID: second)
        await fixture.coordinator.runPass()

        #expect(fixture.encoder.encodedTrackIDs == [second, first])

        try self.cleanup(fixture)
    }

    @Test("ledger writes bump the sync generation through the observed tables")
    func ledgerWritesBumpGeneration() async throws {
        let fixture = try await makeFixture()
        _ = try await self.insertTrack(fixture, title: "L", contentHash: "h1", isLossless: true)
        try await self.setDocument(fixture, preset: .opus128)

        let syncMeta = SyncMetaRepository(database: fixture.database)
        let before = try await syncMeta.generation()
        let observer = LibraryChangeObserver(syncMeta: syncMeta, debounce: .milliseconds(50))
        await observer.start()
        // Let the observation attach before the writes happen.
        try await Task.sleep(for: .milliseconds(100))

        await fixture.coordinator.runPass()

        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var generation = try await syncMeta.generation()
        while generation <= before, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            generation = try await syncMeta.generation()
        }
        #expect(generation > before)
        await observer.stop()

        try self.cleanup(fixture)
    }
}
