import Foundation
import Testing
@testable import Metadata

// MARK: - TagReaderFallbackTests

/// Raw Dolby files (ADR-091 slice 3). TagLib has no AC-3 or E-AC-3 file
/// type, so before this fallback every raw `.ac3` in a library scan logged
/// `scan.tag_read_failed` and imported nothing. `TagReader` now takes such
/// a file's duration, sample rate and channel count from AVFoundation and
/// names it after the file.
@Suite("TagReader raw Dolby fallback")
struct TagReaderFallbackTests {
    private let reader = TagReader()

    private func fixtureURL(_ name: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
            throw MetadataError.bridgeFailure("Missing fixture: \(name)")
        }
        return url
    }

    private func expectDolbyProperties(_ tags: TrackTags, title: String) {
        #expect(tags.title == title)
        #expect(tags.channels == 6)
        #expect(tags.sampleRate == 48000)
        #expect(tags.duration > 0.2 && tags.duration < 0.3, "duration \(tags.duration)")
        #expect(tags.bitDepth == nil)
        #expect(tags.artist == nil)
        #expect(tags.album == nil)
        #expect(tags.coverArt.isEmpty)
    }

    @Test("a raw AC-3 file reads with its filename as title and its real properties")
    func rawAC3Reads() throws {
        let tags = try reader.read(from: self.fixtureURL("surround-lsrs-48000.ac3"))
        self.expectDolbyProperties(tags, title: "surround-lsrs-48000")
    }

    @Test("a raw E-AC-3 file reads with its filename as title and its real properties")
    func rawEAC3Reads() throws {
        let tags = try reader.read(from: self.fixtureURL("surround-lsrs-48000.eac3"))
        self.expectDolbyProperties(tags, title: "surround-lsrs-48000")
    }

    @Test("eac3 and ec3 are supported extensions; thd and mlp are not")
    func dolbyExtensions() {
        #expect(TagReader.supportedExtensions.contains("ac3"))
        #expect(TagReader.supportedExtensions.contains("eac3"))
        #expect(TagReader.supportedExtensions.contains("ec3"))
        // AVAudioFile refuses TrueHD, so the fallback could not read it; the
        // ADR keeps it out of the scanner.
        #expect(!TagReader.supportedExtensions.contains("thd"))
        #expect(!TagReader.supportedExtensions.contains("mlp"))
    }

    /// When AVAudioFile refuses the file too, the caller gets TagLib's own
    /// error, not AVFoundation's: it is the reason the file was rejected in
    /// the first place, and the one the scan log already reports.
    @Test("a damaged file with a Dolby extension rethrows TagLib's error unchanged")
    func damagedDolbyRethrowsTagLibError() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-dolby-\(UUID().uuidString).eac3")
        try Data("this is not audio, it is a sentence".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: MetadataError.self) {
            try reader.read(from: url)
        }
        do {
            _ = try self.reader.read(from: url)
            Issue.record("expected the read to throw")
        } catch let MetadataError.unreadableFile(thrownURL, _) {
            #expect(thrownURL == url)
        }
    }

    /// The fallback is only for the extensions TagLib has no type for. A
    /// damaged file of a format TagLib does handle keeps TagLib's error.
    @Test("a damaged file of a TagLib format gets no AVFoundation fallback")
    func damagedTagLibFormatStillThrows() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-flac-\(UUID().uuidString).flac")
        try Data("this is not audio, it is a sentence".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: MetadataError.self) {
            try reader.read(from: url)
        }
    }
}
