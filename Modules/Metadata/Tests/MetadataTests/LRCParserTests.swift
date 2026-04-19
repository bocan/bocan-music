import Foundation
import Testing
@testable import Metadata

@Suite("LRCParser")
struct LRCParserTests {
    @Test("plain text returns unsynced lines")
    func plainText() {
        let raw = "Line one\nLine two\nLine three"
        let lines = LRCParser.parse(raw)
        #expect(lines.count == 3)
        #expect(lines.allSatisfy { $0.timestamp == nil })
        #expect(lines[0].text == "Line one")
    }

    @Test("empty string returns empty array")
    func empty() {
        #expect(LRCParser.parse("").isEmpty)
    }

    @Test("LRC timestamps are parsed correctly")
    func lrcTimestamps() {
        let raw = "[00:01.00]First line\n[00:05.50]Second line"
        let lines = LRCParser.parse(raw)
        #expect(lines.count == 2)
        let t0 = lines[0].timestamp ?? -1
        let t1 = lines[1].timestamp ?? -1
        #expect(abs(t0 - 1.00) < 0.01)
        #expect(abs(t1 - 5.50) < 0.01)
        #expect(lines[0].text == "First line")
    }

    @Test("millisecond timestamps are parsed")
    func millisecondTimestamps() {
        let raw = "[00:10.500]With ms\n[01:00.000]One minute"
        let lines = LRCParser.parse(raw)
        #expect(lines.count == 2)
        let t0 = lines[0].timestamp ?? -1
        let t1 = lines[1].timestamp ?? -1
        #expect(abs(t0 - 10.5) < 0.01)
        #expect(abs(t1 - 60.0) < 0.01)
    }

    @Test("metadata tags are skipped")
    func metadataTags() {
        let raw = "[ar:Some Artist]\n[al:Some Album]\n[00:01.00]Actual lyric"
        let lines = LRCParser.parse(raw)
        #expect(lines.count == 1)
        #expect(lines[0].text == "Actual lyric")
    }

    @Test("multiple timestamps on one line expanded")
    func multipleTimestamps() {
        let raw = "[00:01.00][00:30.00]Chorus"
        let lines = LRCParser.parse(raw)
        #expect(lines.count == 2)
        #expect(lines[0].text == "Chorus")
        #expect(lines[1].text == "Chorus")
    }

    @Test("lines are sorted by timestamp")
    func sortedOutput() {
        let raw = "[00:10.00]Later\n[00:02.00]Earlier"
        let lines = LRCParser.parse(raw)
        #expect(lines[0].text == "Earlier")
        #expect(lines[1].text == "Later")
    }
}
