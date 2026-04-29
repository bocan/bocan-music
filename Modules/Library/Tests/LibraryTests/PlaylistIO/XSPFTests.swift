import Foundation
import Testing
@testable import Library

@Suite("XSPFReader/Writer")
struct XSPFTests {
    @Test("Parses standard XSPF")
    func parses() throws {
        let body = """
        <?xml version="1.0" encoding="UTF-8"?>
        <playlist version="1" xmlns="http://xspf.org/ns/0/">
          <title>My Mix</title>
          <trackList>
            <track>
              <location>file:///Music/a.mp3</location>
              <title>Alpha</title>
              <creator>X</creator>
              <album>Album1</album>
              <duration>120000</duration>
            </track>
            <track>
              <location>/Music/b.mp3</location>
              <title>Beta</title>
            </track>
          </trackList>
        </playlist>
        """
        let p = try XSPFReader.parse(data: Data(body.utf8))
        #expect(p.name == "My Mix")
        #expect(p.entries.count == 2)
        #expect(p.entries[0].titleHint == "Alpha")
        #expect(p.entries[0].artistHint == "X")
        #expect(p.entries[0].albumHint == "Album1")
        #expect(p.entries[0].durationHint == 120)
        #expect(p.entries[1].titleHint == "Beta")
    }

    @Test("Roundtrip preserves entries")
    func roundtrip() throws {
        let payload = PlaylistPayload(name: "Bob's Mix & Match", entries: [
            .init(
                path: "/a.mp3",
                absoluteURL: URL(fileURLWithPath: "/a.mp3"),
                durationHint: 90,
                titleHint: "Title <1>",
                artistHint: "Artist & Co"
            ),
            .init(
                path: "/b.mp3",
                absoluteURL: URL(fileURLWithPath: "/b.mp3"),
                durationHint: 150,
                titleHint: "T2",
                artistHint: "A2"
            ),
        ])
        let body = XSPFWriter.write(payload)
        let parsed = try XSPFReader.parse(data: Data(body.utf8))
        #expect(parsed.name == "Bob's Mix & Match")
        #expect(parsed.entries.count == 2)
        #expect(parsed.entries[0].titleHint == "Title <1>")
        #expect(parsed.entries[0].artistHint == "Artist & Co")
        #expect(parsed.entries[0].durationHint == 90)
    }

    @Test("Throws on malformed XML")
    func malformed() {
        let bad = "<playlist><trackList><track><location>nope"
        #expect(throws: PlaylistIOError.self) {
            _ = try XSPFReader.parse(data: Data(bad.utf8))
        }
    }
}
