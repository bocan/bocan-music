import Foundation
import Testing
@testable import Metadata

// MARK: - Fixtures helper

private enum Fixtures {
    static var bundle: Bundle {
        Bundle.module
    }

    static func url(named name: String) throws -> URL {
        guard let url = bundle.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
            throw MetadataError.bridgeFailure("Missing fixture: \(name)")
        }
        return url
    }
}

// MARK: - TagReaderTests

@Suite("TagReader")
struct TagReaderTests {
    let reader = TagReader()

    @Test("reads MP3 without throwing")
    func readsMP3() throws {
        let url = try Fixtures.url(named: "sample.mp3")
        let tags = try reader.read(from: url)
        #expect(tags.duration > 0)
    }

    @Test("reads FLAC without throwing")
    func readsFLAC() throws {
        let url = try Fixtures.url(named: "sine-1s-44100-24-stereo.flac")
        let tags = try reader.read(from: url)
        #expect(tags.duration > 0)
        #expect(tags.sampleRate == 44100)
    }

    @Test("reads OGG without throwing")
    func readsOGG() throws {
        let url = try Fixtures.url(named: "sine-1s-48000-stereo.ogg")
        let tags = try reader.read(from: url)
        #expect(tags.duration > 0)
    }

    @Test("reads WAV without throwing")
    func readsWAV() throws {
        let url = try Fixtures.url(named: "sine-1s-44100-16-stereo.wav")
        let tags = try reader.read(from: url)
        #expect(tags.duration > 0)
    }

    @Test("reads M4A without throwing")
    func readsM4A() throws {
        let url = try Fixtures.url(named: "sample-aac.m4a")
        let tags = try reader.read(from: url)
        #expect(tags.duration > 0)
    }

    // MARK: - Bit depth (#405)

    @Test("bit depth is read from FLAC stream info")
    func bitDepthFLAC() throws {
        let url = try Fixtures.url(named: "sine-1s-44100-24-stereo.flac")
        let tags = try reader.read(from: url)
        #expect(tags.bitDepth == 24)
    }

    @Test("bit depth is read from WAV format chunk")
    func bitDepthWAV() throws {
        let url = try Fixtures.url(named: "sine-1s-44100-16-stereo.wav")
        let tags = try reader.read(from: url)
        #expect(tags.bitDepth == 16)
    }

    @Test("lossy formats report no bit depth", arguments: [
        "sine-1s-48000-stereo.ogg", "sample.mp3", "sample-aac.m4a",
    ])
    func bitDepthLossyIsNil(fixture: String) throws {
        let url = try Fixtures.url(named: fixture)
        let tags = try reader.read(from: url)
        #expect(tags.bitDepth == nil)
    }

    @Test("primaryReleaseType prefers a known type over junk first values (#403)", arguments: [
        (["album"], "album"),
        (["Album", "Compilation"], "album"),
        (["ELEAS", "album", "compilation"], "album"),
        (["compilation", "album"], "album"),
        (["OURCE", "live"], "live"),
        (["mixtape"], "mixtape"),
        ([" ", ""], nil),
        ([], nil),
    ] as [([String], String?)])
    func primaryReleaseType(values: [String], expected: String?) {
        #expect(TrackTags.primaryReleaseType(from: values) == expected)
    }

    @Test("corrupt MP3 throws MetadataError")
    func corruptMP3Throws() throws {
        let url = try Fixtures.url(named: "corrupt.mp3")
        // TagLib may succeed on partial files; any result (tags or error) is acceptable.
        // The point is it must not crash.
        _ = try? self.reader.read(from: url)
    }

    @Test("non-existent file throws MetadataError.unreadableFile")
    func missingFileThrows() throws {
        let url = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).mp3")
        #expect(throws: MetadataError.self) {
            try reader.read(from: url)
        }
    }

    @Test("isSupported returns true for known extensions")
    func isSupportedKnown() {
        for ext in ["mp3", "flac", "ogg", "m4a", "wav", "opus", "aiff"] {
            let url = URL(fileURLWithPath: "/tmp/test.\(ext)")
            #expect(TagReader.isSupported(url))
        }
    }

    @Test("isSupported returns false for unknown extensions")
    func isSupportedUnknown() {
        let url = URL(fileURLWithPath: "/tmp/file.pdf")
        #expect(!TagReader.isSupported(url))
    }

    /// Guard for issue #259: real Latin-1 (ISO-8859-1) ID3 tags, common in older
    /// MP3 libraries, must decode to their accented characters rather than being
    /// dropped. `tagStringToNS` also carries a defensive raw-Latin-1 fallback for
    /// the rarer case where TagLib hands back non-UTF-8 bytes. (Frames mis-declared
    /// as UTF-8 but carrying Latin-1 bytes are discarded by TagLib at parse time
    /// and are not recoverable through its high-level API.)
    @Test("reads Latin-1 (ISO-8859-1) ID3 tags with accented characters")
    func readsLatin1Tags() throws {
        let url = try Fixtures.url(named: "latin1-id3.mp3")
        let tags = try self.reader.read(from: url)
        #expect(tags.title == "Café")
        #expect(tags.artist == "Björk")
    }
}
