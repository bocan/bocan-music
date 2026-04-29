import Foundation
import Testing
@testable import Library

@Suite("PLSReader/Writer")
struct PLSTests {
    @Test("Parses standard PLS")
    func parses() throws {
        let body = """
        [playlist]
        File1=/Music/a.mp3
        Title1=Alpha
        Length1=120
        File2=/Music/b.mp3
        Title2=Beta
        Length2=240
        NumberOfEntries=2
        Version=2
        """
        let p = try PLSReader.parse(data: Data(body.utf8))
        #expect(p.entries.count == 2)
        #expect(p.entries[0].path == "/Music/a.mp3")
        #expect(p.entries[0].titleHint == "Alpha")
        #expect(p.entries[0].durationHint == 120)
    }

    @Test("Recovers from missing NumberOfEntries")
    func missingNumberOfEntries() throws {
        let body = """
        [playlist]
        File1=/x.mp3
        Title1=Foo
        File3=/y.mp3
        Title3=Bar
        """
        let p = try PLSReader.parse(data: Data(body.utf8))
        #expect(p.entries.count == 2)
        #expect(p.entries[0].titleHint == "Foo")
        #expect(p.entries[1].titleHint == "Bar")
    }

    @Test("Throws on garbage input")
    func malformed() {
        let body = "not a playlist at all\nrandom text"
        #expect(throws: PlaylistIOError.self) {
            _ = try PLSReader.parse(data: Data(body.utf8))
        }
    }

    @Test("Writer roundtrip")
    func roundtrip() throws {
        let payload = PlaylistPayload(name: "p", entries: [
            .init(
                path: "/a.mp3",
                absoluteURL: URL(fileURLWithPath: "/a.mp3"),
                durationHint: 60,
                titleHint: "Alpha"
            ),
            .init(
                path: "/b.mp3",
                absoluteURL: URL(fileURLWithPath: "/b.mp3"),
                durationHint: 180,
                titleHint: "Beta"
            ),
        ])
        let body = PLSWriter.write(payload)
        let parsed = try PLSReader.parse(data: Data(body.utf8))
        #expect(parsed.entries.count == 2)
        #expect(parsed.entries[0].titleHint == "Alpha")
        #expect(parsed.entries[0].durationHint == 60)
        #expect(parsed.entries[1].titleHint == "Beta")
    }
}
