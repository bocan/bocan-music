import Foundation
import Testing
@testable import Metadata

@Suite("LRCParser — legacy API")
struct LRCParserLegacyTests {
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

@Suite("LRCParser — parseDocument")
struct LRCParserDocumentTests {
    // MARK: - Plain text

    @Test("plain text yields unsynced document")
    func plainTextUnsynced() {
        let doc = LRCParser.parseDocument("Hello\nWorld")
        guard case let .unsynced(text) = doc else {
            Issue.record("Expected .unsynced, got \(doc)")
            return
        }
        #expect(text.contains("Hello"))
        #expect(text.contains("World"))
    }

    @Test("empty input yields unsynced empty document")
    func emptyInput() {
        let doc = LRCParser.parseDocument("")
        if case .unsynced("") = doc { return }
        if case let .unsynced(t) = doc, t.isEmpty { return }
        Issue.record("Expected empty unsynced document, got \(doc)")
    }

    // MARK: - Timestamps

    @Test("standard centisecond timestamps parsed")
    func centisecondTimestamps() {
        let doc = LRCParser.parseDocument("[00:01.00]Line A\n[00:05.50]Line B")
        guard case let .synced(lines, _) = doc else {
            Issue.record("Expected .synced")
            return
        }
        #expect(lines.count == 2)
        #expect(abs(lines[0].start - 1.00) < 0.01)
        #expect(abs(lines[1].start - 5.50) < 0.01)
        #expect(lines[0].text == "Line A")
    }

    @Test("millisecond timestamps parsed")
    func millisecondTimestamps() {
        let doc = LRCParser.parseDocument("[00:10.500]ms line")
        guard case let .synced(lines, _) = doc else {
            Issue.record("Expected .synced")
            return
        }
        #expect(abs(lines[0].start - 10.5) < 0.01)
    }

    @Test("large minute value parsed correctly")
    func largeMinutes() {
        let doc = LRCParser.parseDocument("[99:59.99]End")
        guard case let .synced(lines, _) = doc else {
            Issue.record("Expected .synced")
            return
        }
        let expected = 99.0 * 60 + 59 + 0.99
        #expect(abs(lines[0].start - expected) < 0.01)
    }

    // MARK: - Multi-timestamp

    @Test("multi-timestamp lines expanded to separate entries")
    func multiTimestampExpanded() {
        let doc = LRCParser.parseDocument("[00:10.00][00:20.00][00:30.00]Same line sung thrice")
        guard case let .synced(lines, _) = doc else {
            Issue.record("Expected .synced")
            return
        }
        let matches = lines.filter { $0.text == "Same line sung thrice" }
        #expect(matches.count == 3)
        #expect(abs(matches[0].start - 10.0) < 0.01)
        #expect(abs(matches[1].start - 20.0) < 0.01)
        #expect(abs(matches[2].start - 30.0) < 0.01)
    }

    // MARK: - Metadata tags

    @Test("metadata tags are skipped")
    func metadataTagsSkipped() {
        let raw = "[ti:My Song]\n[ar:Artist]\n[al:Album]\n[by:Creator]\n[00:05.00]Lyric"
        let doc = LRCParser.parseDocument(raw)
        guard case let .synced(lines, _) = doc else {
            Issue.record("Expected .synced")
            return
        }
        #expect(lines.count == 1)
        #expect(lines[0].text == "Lyric")
    }

    // MARK: - Offset tag

    @Test("offset tag applied and stored in document")
    func offsetTag() {
        let raw = "[offset:+500]\n[00:10.00]First line"
        let doc = LRCParser.parseDocument(raw)
        guard case let .synced(_, offsetMS) = doc else {
            Issue.record("Expected .synced")
            return
        }
        #expect(offsetMS == 500)
    }

    @Test("negative offset tag stored")
    func negativeOffsetTag() {
        let raw = "[offset:-250]\n[00:05.00]Line"
        let doc = LRCParser.parseDocument(raw)
        guard case let .synced(_, offsetMS) = doc else {
            Issue.record("Expected .synced")
            return
        }
        #expect(offsetMS == -250)
    }

    // MARK: - Word-level

    @Test("enhanced word-level markers parsed into WordTime array")
    func wordLevelParsed() {
        let raw = "[00:10.00]<00:10.00>Hello <00:10.50>World"
        let doc = LRCParser.parseDocument(raw)
        guard case let .synced(lines, _) = doc else {
            Issue.record("Expected .synced")
            return
        }
        guard let firstLine = lines.first else {
            Issue.record("Expected at least one line")
            return
        }
        #expect(firstLine.words != nil)
        let words = firstLine.words ?? []
        #expect(words.count == 2)
        #expect(words[0].word == "Hello ")
        #expect(abs(words[0].start - 10.0) < 0.01)
    }

    // MARK: - Malformed lines

    @Test("malformed line in synced document is preserved with malformed flag")
    func malformedLineTolerant() {
        let raw = "[00:05.00]Good line\nno timestamp here\n[00:10.00]Another good"
        let doc = LRCParser.parseDocument(raw)
        guard case let .synced(lines, _) = doc else {
            Issue.record("Expected .synced")
            return
        }
        let malformed = lines.filter(\.malformed)
        #expect(malformed.count == 1)
        #expect(malformed[0].text == "no timestamp here")
    }

    // MARK: - End derivation

    @Test("end times derived from next line start minus 50ms gap")
    func endTimeDerived() {
        let raw = "[00:05.00]A\n[00:10.00]B"
        let doc = LRCParser.parseDocument(raw)
        guard case let .synced(lines, _) = doc else {
            Issue.record("Expected .synced")
            return
        }
        #expect(lines.count == 2)
        let expectedEnd = 10.0 - 0.05
        #expect(abs((lines[0].end ?? 0) - expectedEnd) < 0.001)
    }

    @Test("last line end is trackDuration when provided")
    func lastLineEndFromDuration() {
        let raw = "[00:05.00]A"
        let doc = LRCParser.parseDocument(raw, trackDuration: 180.0)
        guard case let .synced(lines, _) = doc else {
            Issue.record("Expected .synced")
            return
        }
        #expect(abs((lines.last?.end ?? 0) - 180.0) < 0.01)
    }

    // MARK: - Sorting

    @Test("lines are sorted by start timestamp")
    func linesSorted() {
        let raw = "[00:20.00]Later\n[00:05.00]Earlier"
        let doc = LRCParser.parseDocument(raw)
        guard case let .synced(lines, _) = doc else {
            Issue.record("Expected .synced")
            return
        }
        #expect(lines[0].text == "Earlier")
        #expect(lines[1].text == "Later")
    }

    // MARK: - Round-trip

    @Test("synced document round-trips through toLRC → parseDocument")
    func roundTrip() {
        let raw = "[00:05.00]Line one\n[00:10.00]Line two\n[00:15.50]Line three"
        let doc = LRCParser.parseDocument(raw)
        guard case let .synced(originalLines, _) = doc else {
            Issue.record("Expected .synced")
            return
        }

        let lrc = doc.toLRC()
        let reparsed = LRCParser.parseDocument(lrc)
        guard case let .synced(reparsedLines, _) = reparsed else {
            Issue.record("Re-parsed should also be .synced")
            return
        }

        #expect(originalLines.count == reparsedLines.count)
        for (orig, re) in zip(originalLines, reparsedLines) {
            #expect(abs(orig.start - re.start) < 0.02)
            #expect(orig.text == re.text)
        }
    }
}

@Suite("LyricsDocument")
struct LyricsDocumentTests {
    @Test("unsynced isEmpty true for blank text")
    func unsyncedEmpty() {
        let doc = LyricsDocument.unsynced("   ")
        #expect(doc.isEmpty)
    }

    @Test("unsynced isEmpty false for real text")
    func unsyncedNotEmpty() {
        let doc = LyricsDocument.unsynced("Hello")
        #expect(!doc.isEmpty)
    }

    @Test("synced isEmpty true when lines array is empty")
    func syncedEmptyLines() {
        let doc = LyricsDocument.synced(lines: [], offsetMS: 0)
        #expect(doc.isEmpty)
    }

    @Test("offsetMS returns 0 for unsynced")
    func unsyncedOffsetAlwaysZero() {
        #expect(LyricsDocument.unsynced("text").offsetMS == 0)
    }

    @Test("offsetMS returns stored value for synced")
    func syncedOffsetReturned() {
        let line = LyricsDocument.LyricsLine(start: 1, text: "Hi")
        let doc = LyricsDocument.synced(lines: [line], offsetMS: 300)
        #expect(doc.offsetMS == 300)
    }

    @Test("Codable round-trip for unsynced")
    func codableUnsynced() throws {
        let doc = LyricsDocument.unsynced("Some lyrics")
        let data = try JSONEncoder().encode(doc)
        let decoded = try JSONDecoder().decode(LyricsDocument.self, from: data)
        #expect(doc == decoded)
    }

    @Test("Codable round-trip for synced")
    func codableSynced() throws {
        let line = LyricsDocument.LyricsLine(
            start: 5.0,
            end: 9.95,
            text: "Hello",
            words: [LyricsDocument.WordTime(start: 5.0, word: "Hello")]
        )
        let doc = LyricsDocument.synced(lines: [line], offsetMS: 100)
        let data = try JSONEncoder().encode(doc)
        let decoded = try JSONDecoder().decode(LyricsDocument.self, from: data)
        #expect(doc == decoded)
    }

    @Test("toLRC produces parseable output for synced doc")
    func toLRCParseable() {
        let lines = [
            LyricsDocument.LyricsLine(start: 10.0, text: "Alpha"),
            LyricsDocument.LyricsLine(start: 20.5, text: "Beta"),
        ]
        let doc = LyricsDocument.synced(lines: lines, offsetMS: 0)
        let lrc = doc.toLRC()
        #expect(lrc.contains("[00:10.00]Alpha"))
        #expect(lrc.contains("[00:20.50]Beta"))
    }

    @Test("toLRC includes offset header when non-zero")
    func toLRCWithOffset() {
        let line = LyricsDocument.LyricsLine(start: 5.0, text: "Hi")
        let doc = LyricsDocument.synced(lines: [line], offsetMS: 200)
        let lrc = doc.toLRC()
        #expect(lrc.contains("[offset:200]"))
    }

    @Test("toLRC for unsynced returns raw text unchanged")
    func toLRCUnsynced() {
        let text = "Line 1\nLine 2"
        let doc = LyricsDocument.unsynced(text)
        #expect(doc.toLRC() == text)
    }
}
