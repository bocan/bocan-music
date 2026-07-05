import Foundation
import Testing
@testable import Metadata

@Suite("TagWriter")
struct TagWriterTests {
    // MARK: - Helpers

    private func fixtureURL(named name: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil) else {
            Issue.record("Fixture not found: \(name)")
            throw FixtureError.notFound(name)
        }
        return url
    }

    /// Copies a fixture to a temp file and returns the temp URL (caller is responsible for cleanup).
    private func tempCopy(of fixture: String) throws -> URL {
        let src = try fixtureURL(named: fixture)
        let ext = src.pathExtension
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
        try FileManager.default.copyItem(at: src, to: tmp)
        return tmp
    }

    // MARK: - Round-trip tests

    @Test func writeAndReadBackTitle_mp3() throws {
        let tmp = try tempCopy(of: "sample.mp3")
        defer { try? FileManager.default.removeItem(at: tmp) }

        var tags = try TagReader().read(from: tmp)
        tags.title = "New Title Round-Trip"
        try TagWriter().write(tags, to: tmp)

        let reread = try TagReader().read(from: tmp)
        #expect(reread.title == "New Title Round-Trip")
    }

    @Test func writeAndReadBackArtist_mp3() throws {
        let tmp = try tempCopy(of: "sample.mp3")
        defer { try? FileManager.default.removeItem(at: tmp) }

        var tags = try TagReader().read(from: tmp)
        tags.artist = "Test Artist Phase8"
        try TagWriter().write(tags, to: tmp)

        let reread = try TagReader().read(from: tmp)
        #expect(reread.artist == "Test Artist Phase8")
    }

    @Test func writeAndReadBackGenre_mp3() throws {
        let tmp = try tempCopy(of: "sample.mp3")
        defer { try? FileManager.default.removeItem(at: tmp) }

        var tags = try TagReader().read(from: tmp)
        tags.genre = "Jazz"
        try TagWriter().write(tags, to: tmp)

        let reread = try TagReader().read(from: tmp)
        #expect(reread.genre == "Jazz")
    }

    @Test func writeAndReadBackYear_mp3() throws {
        let tmp = try tempCopy(of: "sample.mp3")
        defer { try? FileManager.default.removeItem(at: tmp) }

        var tags = try TagReader().read(from: tmp)
        tags.year = 1999
        try TagWriter().write(tags, to: tmp)

        let reread = try TagReader().read(from: tmp)
        #expect(reread.year == 1999)
    }

    @Test func writeAndReadBackTrackNumber_mp3() throws {
        let tmp = try tempCopy(of: "sample.mp3")
        defer { try? FileManager.default.removeItem(at: tmp) }

        var tags = try TagReader().read(from: tmp)
        tags.trackNumber = 7
        try TagWriter().write(tags, to: tmp)

        let reread = try TagReader().read(from: tmp)
        #expect(reread.trackNumber == 7)
    }

    @Test func writeAndReadBackComposer_mp3() throws {
        let tmp = try tempCopy(of: "sample.mp3")
        defer { try? FileManager.default.removeItem(at: tmp) }

        var tags = try TagReader().read(from: tmp)
        tags.composer = "J.S. Bach"
        try TagWriter().write(tags, to: tmp)

        let reread = try TagReader().read(from: tmp)
        #expect(reread.composer == "J.S. Bach")
    }

    @Test func writeAndReadBackBPM_mp3() throws {
        let tmp = try tempCopy(of: "sample.mp3")
        defer { try? FileManager.default.removeItem(at: tmp) }

        var tags = try TagReader().read(from: tmp)
        tags.bpm = 128
        try TagWriter().write(tags, to: tmp)

        let reread = try TagReader().read(from: tmp)
        #expect(reread.bpm == 128)
    }

    // MARK: - MusicBrainz IDs + ISRC round-trip (Phase 8.6)

    private func assertMusicBrainzRoundTrip(fixture: String) throws {
        let tmp = try tempCopy(of: fixture)
        defer { try? FileManager.default.removeItem(at: tmp) }

        var tags = try TagReader().read(from: tmp)
        tags.isrc = "GBAYE0601696"
        tags.musicbrainzTrackID = "7fe8e13a-7ae0-3ff6-8429-52ddf31e6e1b"
        tags.musicbrainzRecordingID = "485bbe7f-d0f7-4ffe-8adb-0f1093dd2dbf"
        tags.musicbrainzReleaseID = "9e53c190-5621-3848-8ae4-39ad9f7d9ace"
        tags.musicbrainzReleaseGroupID = "9162580e-5df4-32de-80cc-f45a8d8a9b1d"
        tags.musicbrainzAlbumArtistID = "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d"
        try TagWriter().write(tags, to: tmp)

        let reread = try TagReader().read(from: tmp)
        #expect(reread.isrc == "GBAYE0601696")
        #expect(reread.musicbrainzTrackID == "7fe8e13a-7ae0-3ff6-8429-52ddf31e6e1b")
        #expect(reread.musicbrainzRecordingID == "485bbe7f-d0f7-4ffe-8adb-0f1093dd2dbf")
        #expect(reread.musicbrainzReleaseID == "9e53c190-5621-3848-8ae4-39ad9f7d9ace")
        #expect(reread.musicbrainzReleaseGroupID == "9162580e-5df4-32de-80cc-f45a8d8a9b1d")
        #expect(reread.musicbrainzAlbumArtistID == "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d")
    }

    @Test func writeAndReadBackMusicBrainzIDs_mp3() throws {
        try self.assertMusicBrainzRoundTrip(fixture: "sample.mp3")
    }

    @Test func writeAndReadBackMusicBrainzIDs_flac() throws {
        try self.assertMusicBrainzRoundTrip(fixture: "sine-1s-44100-24-stereo.flac")
    }

    @Test func writeAndReadBackMusicBrainzIDs_m4a() throws {
        try self.assertMusicBrainzRoundTrip(fixture: "sample-aac.m4a")
    }

    @Test func writeAndReadBackMusicBrainzIDs_ogg() throws {
        try self.assertMusicBrainzRoundTrip(fixture: "sine-1s-48000-stereo.ogg")
    }

    /// A symmetric read/write swap would still round-trip, so the Picard key
    /// convention is pinned against a fixture tagged by an external tool
    /// (ffmpeg): the historical MUSICBRAINZ_TRACKID key carries the *recording*
    /// MBID, MUSICBRAINZ_RELEASETRACKID the track MBID.
    @Test func readsPicardConventionKeys() throws {
        let url = try fixtureURL(named: "picard-mbids.flac")
        let tags = try TagReader().read(from: url)
        #expect(tags.musicbrainzRecordingID == "external-recording-mbid")
        #expect(tags.musicbrainzTrackID == "external-track-mbid")
    }

    @Test func clearingFieldRemovesItFromFile() throws {
        let tmp = try tempCopy(of: "sample.mp3")
        defer { try? FileManager.default.removeItem(at: tmp) }

        var tags = try TagReader().read(from: tmp)
        tags.musicbrainzRecordingID = "485bbe7f-d0f7-4ffe-8adb-0f1093dd2dbf"
        tags.isrc = "GBAYE0601696"
        try TagWriter().write(tags, to: tmp)

        var cleared = try TagReader().read(from: tmp)
        cleared.musicbrainzRecordingID = nil
        cleared.isrc = nil
        try TagWriter().write(cleared, to: tmp)

        let reread = try TagReader().read(from: tmp)
        #expect(reread.musicbrainzRecordingID == nil)
        #expect(reread.isrc == nil)
    }

    @Test func writePreservesAudioDuration() throws {
        let tmp = try tempCopy(of: "sample.mp3")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let originalTags = try TagReader().read(from: tmp)
        var tags = originalTags
        tags.title = "Duration Test"
        try TagWriter().write(tags, to: tmp)

        let reread = try TagReader().read(from: tmp)
        // Duration should be within 1 second of original
        #expect(abs(reread.duration - originalTags.duration) < 1.0)
    }

    // MARK: - Atomic write safety

    @Test func originalUntouchedOnBadPath() throws {
        let tmp = try tempCopy(of: "sample.mp3")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Read original content for size comparison
        let originalData = try Data(contentsOf: tmp)

        // Non-existent file should throw, not corrupt the original
        let badURL = URL(fileURLWithPath: "/tmp/does_not_exist_\(UUID().uuidString).mp3")
        let tags = TrackTags()
        #expect(throws: MetadataError.self) {
            try TagWriter().write(tags, to: badURL)
        }

        // Original file must be intact
        let afterData = try Data(contentsOf: tmp)
        #expect(afterData.count == originalData.count)
    }

    // MARK: - Read-only file

    @Test func readOnlyFileThrowsReadOnlyError() throws {
        let tmp = try tempCopy(of: "sample.mp3")
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: tmp.path
            )
            try? FileManager.default.removeItem(at: tmp)
        }

        // Make the file read-only
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o444],
            ofItemAtPath: tmp.path
        )

        var tags = try TagReader().read(from: tmp)
        tags.title = "Should Fail"

        #expect(throws: MetadataError.self) {
            try TagWriter().write(tags, to: tmp)
        }
    }

    // MARK: - FLAC

    @Test func writeAndReadBackTitle_flac() throws {
        let tmp = try tempCopy(of: "sine-1s-44100-24-stereo.flac")
        defer { try? FileManager.default.removeItem(at: tmp) }

        var tags = try TagReader().read(from: tmp)
        tags.title = "FLAC Round-Trip"
        try TagWriter().write(tags, to: tmp)

        let reread = try TagReader().read(from: tmp)
        #expect(reread.title == "FLAC Round-Trip")
    }

    // MARK: - Cover art clearing (#289)

    @Test("writing empty coverArt clears existing embedded art")
    func writingEmptyCoverArtClearsExistingArt() throws {
        let tmp = try tempCopy(of: "sample-with-art.mp3")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Verify the fixture actually has art before we try to clear it.
        let before = try TagReader().read(from: tmp)
        guard !before.coverArt.isEmpty else {
            // Fixture has no art; the test has nothing meaningful to assert.
            return
        }

        // Write tags back with an empty coverArt array.
        var tags = before
        tags.coverArt = []
        try TagWriter().write(tags, to: tmp)

        let after = try TagReader().read(from: tmp)
        #expect(after.coverArt.isEmpty, "Expected embedded art to be cleared; got \(after.coverArt.count) image(s)")
    }

    // MARK: - OGG

    @Test func writeAndReadBackTitle_ogg() throws {
        let tmp = try tempCopy(of: "sine-1s-48000-stereo.ogg")
        defer { try? FileManager.default.removeItem(at: tmp) }

        var tags = try TagReader().read(from: tmp)
        tags.title = "OGG Round-Trip"
        try TagWriter().write(tags, to: tmp)

        let reread = try TagReader().read(from: tmp)
        #expect(reread.title == "OGG Round-Trip")
    }
}

// MARK: - FixtureError

private enum FixtureError: Error {
    case notFound(String)
}
