import Foundation
import Testing
@testable import Library

@Suite("M3UReader/Writer")
struct M3UReaderWriterTests {
    @Test("Parses extended M3U with EXTINF")
    func extM3U() throws {
        let body = """
        #EXTM3U
        #EXTINF:240,Artist - Title
        /Music/track1.mp3
        #EXTINF:-1,Just A Title
        /Music/track2.mp3
        """
        let payload = try M3UReader.parse(data: Data(body.utf8))
        #expect(payload.entries.count == 2)
        #expect(payload.entries[0].titleHint == "Title")
        #expect(payload.entries[0].artistHint == "Artist")
        #expect(payload.entries[0].durationHint == 240)
        #expect(payload.entries[1].titleHint == "Just A Title")
        #expect(payload.entries[1].durationHint == nil)
    }

    @Test("Strips UTF-8 BOM and CRLF line endings")
    func bomAndCRLF() throws {
        var bytes: [UInt8] = [0xEF, 0xBB, 0xBF]
        bytes.append(contentsOf: "#EXTM3U\r\n#EXTINF:60,Foo - Bar\r\n/x/y.mp3\r\n".utf8)
        let p = try M3UReader.parse(data: Data(bytes))
        #expect(p.entries.count == 1)
        #expect(p.entries[0].titleHint == "Bar")
    }

    @Test("Resolves relative paths against playlist directory")
    func relativeResolution() throws {
        let dir = URL(fileURLWithPath: "/Users/me/Music")
        let body = "#EXTM3U\n#EXTINF:10,X - Y\nrelative/song.mp3\n"
        let p = try M3UReader.parse(data: Data(body.utf8), sourceURL: dir.appendingPathComponent("p.m3u8"))
        #expect(p.entries[0].absoluteURL?.path == "/Users/me/Music/relative/song.mp3")
    }

    @Test("Handles file:// URLs")
    func fileURLs() throws {
        let body = "#EXTM3U\nfile:///foo/bar.flac\n"
        let p = try M3UReader.parse(data: Data(body.utf8))
        #expect(p.entries[0].absoluteURL?.absoluteString == "file:///foo/bar.flac")
    }

    @Test("Falls back to Windows-1252 for legacy .m3u")
    func legacyM3U() throws {
        var bytes: [UInt8] = []
        bytes.append(contentsOf: "#EXTM3U\n#EXTINF:60,".utf8)
        bytes.append(0xE9) // 'é' in Windows-1252
        bytes.append(contentsOf: " - song\n/p.mp3\n".utf8)
        let url = URL(fileURLWithPath: "/tmp/playlist.m3u")
        let p = try M3UReader.parse(data: Data(bytes), sourceURL: url)
        #expect(p.entries.count == 1)
        #expect(p.entries[0].artistHint?.contains("é") == true)
    }

    @Test("Roundtrip: write then read returns same entries")
    func roundtrip() throws {
        let payload = PlaylistPayload(name: "Mix", entries: [
            .init(
                path: "/Music/a.mp3",
                absoluteURL: URL(fileURLWithPath: "/Music/a.mp3"),
                durationHint: 120,
                titleHint: "A",
                artistHint: "X"
            ),
            .init(
                path: "/Music/b.mp3",
                absoluteURL: URL(fileURLWithPath: "/Music/b.mp3"),
                durationHint: 200,
                titleHint: "B",
                artistHint: "Y"
            ),
        ])
        let body = M3UWriter.write(payload)
        let parsed = try M3UReader.parse(data: Data(body.utf8))
        #expect(parsed.entries.count == 2)
        #expect(parsed.entries[0].titleHint == "A")
        #expect(parsed.entries[0].artistHint == "X")
        #expect(parsed.entries[1].titleHint == "B")
    }

    @Test("Relative writer survives root move")
    func relativeWriter() {
        let root = URL(fileURLWithPath: "/Volumes/Music")
        let payload = PlaylistPayload(name: "x", entries: [
            .init(
                path: "/Volumes/Music/Album/01.flac",
                absoluteURL: URL(fileURLWithPath: "/Volumes/Music/Album/01.flac")
            ),
        ])
        let body = M3UWriter.write(payload, options: M3UWriter.Options(pathMode: .relative(to: root)))
        #expect(body.contains("Album/01.flac"))
        #expect(!body.contains("/Volumes/Music/Album"))
    }

    @Test("CRLF line ending option")
    func crlfOption() {
        let payload = PlaylistPayload(name: "x", entries: [
            .init(path: "/a.mp3", absoluteURL: URL(fileURLWithPath: "/a.mp3")),
        ])
        let body = M3UWriter.write(payload, options: M3UWriter.Options(lineEnding: "\r\n"))
        #expect(body.contains("\r\n"))
    }
}
