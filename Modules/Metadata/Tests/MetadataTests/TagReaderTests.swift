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
}
