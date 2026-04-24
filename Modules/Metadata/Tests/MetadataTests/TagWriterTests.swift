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
