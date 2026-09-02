import AudioEngine
import Foundation
import Persistence
import Testing
@testable import SyncServer

// MARK: - DataCollector

/// Collects streamed chunks from a response producer.
private final class DataCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _data = Data()

    func append(_ chunk: Data) {
        self.lock.withLock { self._data.append(chunk) }
    }

    var data: Data {
        self.lock.withLock { self._data }
    }
}

// MARK: - FileServingTranscodeTests

/// ADR-088 artifact serving: ledger ETags, served_at stamping through EOF,
/// and 503 busy for released bytes.
@Suite("FileServing transcode")
struct FileServingTranscodeTests {
    private struct Fixture {
        let database: Database
        let router: Router
        let tracks: TrackRepository
        let ledger: SyncTranscodeRepository
        let profiles: SyncProfileRepository
        let store: TranscodeStore
        let root: URL
    }

    private func makeFixture() async throws -> Fixture {
        let database = try await Database(location: .inMemory)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fs-transcode-\(UUID().uuidString)")
        let serving = FileServing(database: database, transcodeRoot: root)
        return Fixture(
            database: database,
            router: Router(routes: serving.routes()),
            tracks: TrackRepository(database: database),
            ledger: SyncTranscodeRepository(database: database),
            profiles: SyncProfileRepository(database: database),
            store: TranscodeStore(root: root),
            root: root
        )
    }

    private func cleanup(_ fixture: Fixture) throws {
        if FileManager.default.fileExists(atPath: fixture.root.path) {
            try FileManager.default.removeItem(at: fixture.root)
        }
    }

    private func trustedContext() -> ConnectionContext {
        let context = ConnectionContext()
        context.recordPeer(certificateDER: Data([0x01]), fingerprint: "aa", isPairing: false, isTrusted: true)
        return context
    }

    private func get(_ fixture: Fixture, _ path: String, headers: [String: String] = [:]) async -> HttpResponse {
        await fixture.router.dispatch(
            HttpRequest(method: "GET", path: path, query: [:], headers: headers, body: Data()),
            context: self.trustedContext()
        )
    }

    private func setPreset(_ fixture: Fixture, _ preset: TranscodePreset) async throws {
        let document = SyncProfileDocument(
            profile: .everything(includePodcasts: false),
            transcode: TranscodeSettings(preset: preset)
        )
        try await fixture.profiles.setProfileJSON(document.encoded())
    }

    /// Inserts a lossless track, a valid ledger row, and (optionally) the
    /// artifact bytes on disk. Returns the track id and the bytes.
    private func seedTranscodedTrack(
        _ fixture: Fixture,
        artifactOnDisk: Bool
    ) async throws -> (id: Int64, bytes: Data) {
        var track = Track(fileURL: "file:///Music/a.flac", addedAt: 0, updatedAt: 0)
        track.contentHash = "src"
        track.isLossless = true
        let id = try await fixture.tracks.insert(track)

        let bytes = Data("opus-artifact-bytes".utf8)
        try await fixture.ledger.upsert(SyncTranscode(
            trackID: id, preset: "opus_128", sourceContentHash: "src",
            sha256: "art-sha", size: Int64(bytes.count), createdAt: 1, bitrate: 128
        ))
        if artifactOnDisk {
            try fixture.store.prepareDirectory(preset: .opus128)
            let url = fixture.store.artifactURL(trackID: id, sourceContentHash: "src", preset: .opus128)
            try bytes.write(to: url)
        }
        try await self.setPreset(fixture, .opus128)
        return (id, bytes)
    }

    /// Runs a streamed response's producer and returns the delivered bytes.
    private func drain(_ response: HttpResponse) async throws -> Data {
        let collector = DataCollector()
        let stream = try #require(response.stream)
        try await stream.producer { chunk in collector.append(chunk) }
        return collector.data
    }

    @Test("an artifact is served with ledger truth and stamped on full delivery")
    func artifactServedAndStamped() async throws {
        let fixture = try await makeFixture()
        let (id, bytes) = try await seedTranscodedTrack(fixture, artifactOnDisk: true)

        let response = await self.get(fixture, "/v1/file/track/\(id)")
        #expect(response.status == 200)
        #expect(response.headers["etag"] == "art-sha")
        #expect(response.headers["content-type"] == "audio/opus")
        #expect(response.stream?.length == bytes.count)

        let delivered = try await self.drain(response)
        #expect(delivered == bytes)
        let row = try #require(
            try await fixture.ledger.validRow(trackID: id, preset: "opus_128", sourceContentHash: "src")
        )
        #expect(row.servedAt != nil)

        try self.cleanup(fixture)
    }

    @Test("released bytes draw 503 busy with Retry-After")
    func releasedBytesDrawBusy() async throws {
        let fixture = try await makeFixture()
        let (id, _) = try await seedTranscodedTrack(fixture, artifactOnDisk: false)

        let response = await self.get(fixture, "/v1/file/track/\(id)")
        #expect(response.status == 503)
        #expect(response.headers["retry-after"] != nil)

        try self.cleanup(fixture)
    }

    @Test("If-Match against the wrong artifact hash draws 412")
    func wrongIfMatchDraws412() async throws {
        let fixture = try await makeFixture()
        let (id, _) = try await seedTranscodedTrack(fixture, artifactOnDisk: true)

        let response = await self.get(fixture, "/v1/file/track/\(id)", headers: ["if-match": "stale-sha"])
        #expect(response.status == 412)

        try self.cleanup(fixture)
    }

    @Test("a transcodable track with no ledger row is 404, matching the manifest gate")
    func unpreparedTrackIs404() async throws {
        let fixture = try await makeFixture()
        var track = Track(fileURL: "file:///Music/b.flac", addedAt: 0, updatedAt: 0)
        track.contentHash = "src-b"
        track.isLossless = true
        let id = try await fixture.tracks.insert(track)
        try await self.setPreset(fixture, .opus128)

        let response = await self.get(fixture, "/v1/file/track/\(id)")
        #expect(response.status == 404)

        try self.cleanup(fixture)
    }

    @Test("only a range reaching EOF stamps served_at")
    func partialDeliveryStampsOnlyAtEOF() async throws {
        let fixture = try await makeFixture()
        let (id, bytes) = try await seedTranscodedTrack(fixture, artifactOnDisk: true)

        // A middle slice: no stamp.
        let middle = await self.get(fixture, "/v1/file/track/\(id)", headers: ["range": "bytes=0-4"])
        #expect(middle.status == 206)
        _ = try await self.drain(middle)
        var row = try #require(
            try await fixture.ledger.validRow(trackID: id, preset: "opus_128", sourceContentHash: "src")
        )
        #expect(row.servedAt == nil)

        // The resuming open-ended range reaches EOF: stamped.
        let tail = await self.get(fixture, "/v1/file/track/\(id)", headers: ["range": "bytes=5-"])
        #expect(tail.status == 206)
        let delivered = try await self.drain(tail)
        #expect(delivered == bytes.dropFirst(5))
        row = try #require(
            try await fixture.ledger.validRow(trackID: id, preset: "opus_128", sourceContentHash: "src")
        )
        #expect(row.servedAt != nil)

        try self.cleanup(fixture)
    }
}
