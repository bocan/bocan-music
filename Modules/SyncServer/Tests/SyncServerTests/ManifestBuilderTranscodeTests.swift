import AudioEngine
import Foundation
import Persistence
import Testing
@testable import SyncServer

/// ADR-088 served-bytes rule in the manifest: under a transcode preset the
/// file-describing fields come from the ledger, gated on a prepared artifact.
@Suite("ManifestBuilder transcode")
struct ManifestBuilderTranscodeTests {
    private struct Fixture {
        let builder: ManifestBuilder
        let tracks: TrackRepository
        let ledger: SyncTranscodeRepository
        let roots: LibraryRootRepository
    }

    private func makeFixture() async throws -> Fixture {
        let database = try await Database(location: .inMemory)
        return Fixture(
            builder: ManifestBuilder(database: database),
            tracks: TrackRepository(database: database),
            ledger: SyncTranscodeRepository(database: database),
            roots: LibraryRootRepository(database: database)
        )
    }

    private func seedRoot(_ fixture: Fixture) async throws {
        _ = try await fixture.roots.upsert(LibraryRoot(path: "/Music", bookmark: Data([0x01]), addedAt: 0))
    }

    @discardableResult
    private func insertTrack(
        _ fixture: Fixture,
        path: String,
        hash: String,
        isLossless: Bool? = nil,
        bitrate: Int? = nil
    ) async throws -> Int64 {
        var track = Track(
            fileURL: URL(fileURLWithPath: path).absoluteString,
            fileSize: 5000,
            fileFormat: "flac",
            duration: 100,
            addedAt: 0,
            updatedAt: 0
        )
        track.contentHash = hash
        track.isLossless = isLossless
        track.bitrate = bitrate
        track.sampleRate = 44100
        track.bitDepth = 16
        track.channelCount = 2
        return try await fixture.tracks.insert(track)
    }

    private func build(
        _ fixture: Fixture,
        transcode: TranscodeSettings = .original
    ) async throws -> Manifest {
        try await fixture.builder.build(
            profile: .everything(includePodcasts: false),
            transcode: transcode,
            serverId: "srv",
            serverName: "Mac",
            generation: 1,
            generatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    @Test("an artifact-described track carries the ledger's truth")
    func artifactFieldsComeFromTheLedger() async throws {
        let fixture = try await self.makeFixture()
        try await self.seedRoot(fixture)
        let id = try await insertTrack(fixture, path: "/Music/Artist/01 Song.flac", hash: "src-hash", isLossless: true)
        try await fixture.ledger.upsert(SyncTranscode(
            trackID: id, preset: "opus_128", sourceContentHash: "src-hash",
            sha256: "artifact-sha", size: 4200, createdAt: 1, bitrate: 128
        ))

        let manifest = try await self.build(fixture, transcode: TranscodeSettings(preset: .opus128))
        let track = try #require(manifest.tracks.first { $0.id == id })

        #expect(track.relPath == "Artist/01 Song.opus")
        #expect(track.size == 4200)
        #expect(track.sha256 == "artifact-sha")
        #expect(track.format == "opus")
        #expect(track.bitrate == 128)
        #expect(track.sampleRate == 48000)
        #expect(track.bitDepth == nil)
        #expect(track.isLossless == false)
        #expect(track.channelCount == 2)
        #expect(track.sourceFormat == "flac")
    }

    @Test("a transcodable track is not advertised until prepared; pass-through is untouched")
    func gateAndPassThrough() async throws {
        let fixture = try await self.makeFixture()
        try await self.seedRoot(fixture)
        let pending = try await insertTrack(fixture, path: "/Music/A/pending.flac", hash: "h-p", isLossless: true)
        let passThrough = try await insertTrack(fixture, path: "/Music/A/small.flac", hash: "h-s", bitrate: 96)

        let manifest = try await self.build(fixture, transcode: TranscodeSettings(preset: .opus128))

        #expect(!manifest.tracks.contains { $0.id == pending })
        let small = try #require(manifest.tracks.first { $0.id == passThrough })
        #expect(small.size == 5000)
        #expect(small.sha256 == "h-s")
        #expect(small.format == "flac")
        #expect(small.relPath == "A/small.flac")
        #expect(small.sourceFormat == nil)
    }

    @Test("a stale ledger row never describes a track")
    func staleRowIsIgnored() async throws {
        let fixture = try await self.makeFixture()
        try await self.seedRoot(fixture)
        let id = try await insertTrack(fixture, path: "/Music/A/retagged.flac", hash: "h-new", isLossless: true)
        try await fixture.ledger.upsert(SyncTranscode(
            trackID: id, preset: "opus_128", sourceContentHash: "h-old",
            sha256: "stale-sha", size: 1, createdAt: 1
        ))

        let manifest = try await self.build(fixture, transcode: TranscodeSettings(preset: .opus128))
        #expect(!manifest.tracks.contains { $0.id == id })
    }

    @Test("without a preset every field describes the source")
    func originalDescribesTheSource() async throws {
        let fixture = try await self.makeFixture()
        try await self.seedRoot(fixture)
        let id = try await insertTrack(fixture, path: "/Music/A/plain.flac", hash: "h1", isLossless: true)

        let manifest = try await self.build(fixture)
        let track = try #require(manifest.tracks.first { $0.id == id })
        #expect(track.size == 5000)
        #expect(track.sha256 == "h1")
        #expect(track.format == "flac")
        #expect(track.isLossless == true)
        #expect(track.sourceFormat == nil)
    }

    @Test("MP3 rungs keep a supported source rate and swap to the mp3 extension")
    func mp3KeepsSupportedRate() async throws {
        let fixture = try await self.makeFixture()
        try await self.seedRoot(fixture)
        let id = try await insertTrack(fixture, path: "/Music/A/hi.flac", hash: "h1", isLossless: true)
        try await fixture.ledger.upsert(SyncTranscode(
            trackID: id, preset: "mp3_320", sourceContentHash: "h1",
            sha256: "m-sha", size: 9000, createdAt: 1, bitrate: 320
        ))

        let manifest = try await self.build(fixture, transcode: TranscodeSettings(preset: .mp3320))
        let track = try #require(manifest.tracks.first { $0.id == id })
        #expect(track.relPath == "A/hi.mp3")
        #expect(track.format == "mp3")
        #expect(track.sampleRate == 44100)
    }
}
