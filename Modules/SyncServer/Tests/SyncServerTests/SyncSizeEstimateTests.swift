import AudioEngine
import Foundation
import Persistence
import Testing
@testable import SyncServer

/// The ADR-088 estimate aggregate: per-rung bytes with no manifest build,
/// no hashing, and no file I/O; plus the preparing-progress counts.
@Suite("Size estimates")
struct SyncSizeEstimateTests {
    private struct Fixture {
        let builder: ManifestBuilder
        let tracks: TrackRepository
        let ledger: SyncTranscodeRepository
    }

    private func makeFixture() async throws -> Fixture {
        let database = try await Database(location: .inMemory)
        return Fixture(
            builder: ManifestBuilder(database: database),
            tracks: TrackRepository(database: database),
            ledger: SyncTranscodeRepository(database: database)
        )
    }

    @discardableResult
    private func insertTrack(
        _ fixture: Fixture,
        hash: String,
        fileSize: Int64,
        duration: Double,
        isLossless: Bool? = nil,
        bitrate: Int? = nil
    ) async throws -> Int64 {
        var track = Track(
            fileURL: "file:///tmp/\(UUID().uuidString).flac",
            fileSize: fileSize,
            fileFormat: "flac",
            duration: duration,
            addedAt: 0,
            updatedAt: 0
        )
        track.contentHash = hash
        track.isLossless = isLossless
        track.bitrate = bitrate
        return try await fixture.tracks.insert(track)
    }

    /// 100 s lossless at 10 MB, 100 s lossy 320 at 5 MB, 100 s lossy 96 at 2 MB.
    private func seedMixedLibrary(_ fixture: Fixture) async throws {
        try await self.insertTrack(fixture, hash: "h-l", fileSize: 10_000_000, duration: 100, isLossless: true)
        try await self.insertTrack(fixture, hash: "h-b", fileSize: 5_000_000, duration: 100, bitrate: 320)
        try await self.insertTrack(fixture, hash: "h-s", fileSize: 2_000_000, duration: 100, bitrate: 96)
    }

    @Test("per-rung estimates apply the predicate: real size or duration times target")
    func rungMaths() async throws {
        let fixture = try await makeFixture()
        try await self.seedMixedLibrary(fixture)

        let estimates = try await fixture.builder.sizeEstimates(for: .everything(includePodcasts: false))

        // Original: the real sizes.
        #expect(estimates[nil]?.bytes == 17_000_000)
        #expect(estimates[nil]?.trackCount == 3)
        // Opus 128: lossless and the 320 kbps lossy both estimate at
        // 100 s x 128 kbps x 125 = 1.6 MB; the 96 kbps file passes through.
        #expect(estimates[.opus128]?.bytes == 5_200_000)
        // MP3 320: only the lossless transcodes (320 is not above 320) at
        // 100 s x 320 kbps x 125 = 4 MB; the lossy files pass through.
        #expect(estimates[.mp3320]?.bytes == 11_000_000)
        // Every rung has an entry: Original plus the four presets.
        #expect(estimates.count == TranscodePreset.allCases.count + 1)
    }

    @Test("the compatibility wrapper returns the Original rung")
    func wrapperMatchesOriginal() async throws {
        let fixture = try await makeFixture()
        try await self.seedMixedLibrary(fixture)

        let single = try await fixture.builder.sizeEstimate(for: .everything(includePodcasts: false))
        let estimates = try await fixture.builder.sizeEstimates(for: .everything(includePodcasts: false))
        #expect(single == estimates[nil])
    }

    @Test("disabled and hashless tracks stay out of the estimate")
    func gatesApply() async throws {
        let fixture = try await makeFixture()
        try await self.insertTrack(fixture, hash: "h-ok", fileSize: 1000, duration: 10, bitrate: 96)
        var disabled = Track(fileURL: "file:///tmp/d.flac", fileSize: 500, addedAt: 0, updatedAt: 0)
        disabled.contentHash = "h-d"
        disabled.disabled = true
        _ = try await fixture.tracks.insert(disabled)
        var hashless = Track(fileURL: "file:///tmp/n.flac", fileSize: 500, addedAt: 0, updatedAt: 0)
        hashless.contentHash = nil
        _ = try await fixture.tracks.insert(hashless)

        let estimates = try await fixture.builder.sizeEstimates(for: .everything(includePodcasts: false))
        #expect(estimates[nil]?.bytes == 1000)
        #expect(estimates[nil]?.trackCount == 1)
    }

    @Test("transcodeProgress counts prepared against the transcodable targets")
    func progressCounts() async throws {
        let fixture = try await makeFixture()
        try await self.seedMixedLibrary(fixture)

        var progress = try await fixture.builder.transcodeProgress(
            for: .everything(includePodcasts: false), preset: .opus128
        )
        #expect(progress.total == 2, "the lossless and the 320 kbps lossy qualify")
        #expect(progress.prepared == 0)
        #expect(progress.unservedBytes == 0)

        let rows = try await fixture.tracks.fetchAllIncludingDisabled()
        let lossless = try #require(rows.first { $0.contentHash == "h-l" }?.id)
        try await fixture.ledger.upsert(SyncTranscode(
            trackID: lossless, preset: "opus_128", sourceContentHash: "h-l",
            sha256: "a", size: 1, createdAt: 1
        ))
        progress = try await fixture.builder.transcodeProgress(
            for: .everything(includePodcasts: false), preset: .opus128
        )
        #expect(progress.prepared == 1)
        #expect(progress.total == 2)
        #expect(progress.unservedBytes == 1)

        // Serving releases the bytes from the window; the row stays prepared.
        try await fixture.ledger.stampServed(trackID: lossless, preset: "opus_128", at: 2)
        progress = try await fixture.builder.transcodeProgress(
            for: .everything(includePodcasts: false), preset: .opus128
        )
        #expect(progress.prepared == 1)
        #expect(progress.unservedBytes == 0, "served bytes leave the prepare window")
    }
}
