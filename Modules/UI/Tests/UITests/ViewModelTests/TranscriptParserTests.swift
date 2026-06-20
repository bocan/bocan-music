import Foundation
import Persistence
import Testing
@testable import UI

@Suite("TranscriptParser")
struct TranscriptParserTests {
    @Test("VTT parses cues with dot-decimal timing and lifts a voice tag")
    func vtt() {
        let body = """
        WEBVTT

        NOTE this is a note

        00:00:01.000 --> 00:00:03.500
        <v Alice>Hello there

        00:00:03.500 --> 00:00:06.000
        General Kenobi
        """
        guard case let .timed(cues) = TranscriptParser.parse(body, format: .vtt) else {
            Issue.record("expected timed content")
            return
        }
        #expect(cues.count == 2)
        #expect(cues[0].start == 1.0)
        #expect(cues[0].end == 3.5)
        #expect(cues[0].speaker == "Alice")
        #expect(cues[0].text == "Hello there")
        #expect(cues[1].start == 3.5)
        #expect(cues[1].text == "General Kenobi")
    }

    @Test("SRT parses cues with comma-decimal timing and an index line")
    func srt() {
        let body = """
        1
        00:00:00,000 --> 00:00:02,000
        First line

        2
        00:00:02,000 --> 00:00:04,000
        Second line
        """
        guard case let .timed(cues) = TranscriptParser.parse(body, format: .srt) else {
            Issue.record("expected timed content")
            return
        }
        #expect(cues.count == 2)
        #expect(cues[0].start == 0.0)
        #expect(cues[0].end == 2.0)
        #expect(cues[0].text == "First line")
        #expect(cues[1].start == 2.0)
    }

    @Test("Podcasting 2.0 JSON parses segments into cues")
    func json() {
        let body = """
        { "version": "1.0.0", "segments": [
          { "startTime": 0.0, "endTime": 2.0, "speaker": "Host", "body": "Welcome" },
          { "startTime": 2.0, "endTime": 4.0, "body": "to the show" }
        ] }
        """
        guard case let .timed(cues) = TranscriptParser.parse(body, format: .json) else {
            Issue.record("expected timed content")
            return
        }
        #expect(cues.count == 2)
        #expect(cues[0].speaker == "Host")
        #expect(cues[0].text == "Welcome")
        #expect(cues[1].start == 2.0)
    }

    @Test("plain text round-trips unchanged")
    func plain() {
        #expect(TranscriptParser.parse("just words", format: .plain) == .plain("just words"))
    }

    @Test("HTML is stripped to plain text")
    func html() {
        guard case let .plain(text) = TranscriptParser.parse("<p>Hello <b>world</b></p>", format: .html) else {
            Issue.record("expected plain content")
            return
        }
        #expect(text.contains("Hello"))
        #expect(text.contains("world"))
        #expect(!text.contains("<"))
    }

    @Test("a malformed timed body degrades to plain rather than crashing")
    func malformedDegrades() {
        let junk = "not a vtt at all\nno timings here"
        #expect(TranscriptParser.parse(junk, format: .vtt) == .plain(junk))
    }
}
