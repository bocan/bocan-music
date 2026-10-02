import Foundation
import Testing
@testable import Metadata

// MARK: - Property-based tests (#324)

/// Deterministic SplitMix64. Seeded so the randomized cases below are
/// reproducible across runs (the standard requires test inputs be
/// deterministic, never freshly random per invocation).
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        self.state &+= 0x9E37_79B9_7F4A_7C15
        var z = self.state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A single randomized `[mm:ss.cs]` timestamp to parse.
struct TimestampCase: CustomStringConvertible {
    let mm: Int
    let ss: Int
    let cs: Int
    var description: String {
        String(format: "[%02d:%02d.%02d]", self.mm, self.ss, self.cs)
    }
}

/// A randomized synced document: lines keyed by centisecond start, plus an offset.
struct DocumentCase: CustomStringConvertible {
    let lines: [LineSpec]
    let offsetMS: Int

    struct LineSpec {
        let cs: Int
        let text: String
    }

    var description: String {
        "\(self.lines.count) lines, offset \(self.offsetMS)"
    }
}

/// The LRC parser has interesting algebra (timestamp math, multi-line sorting,
/// `toLRC` round-trip), which the standard names explicitly as a candidate for
/// property-based coverage. These exercise it over many randomized-but-reproducible
/// inputs rather than the handful of hand-picked examples in `LRCParserTests.swift`.
@Suite("LRCParser — property-based")
struct LRCParserPropertyTests {
    // MARK: - Case generation

    private static let safeAlphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ")

    /// Random display text drawn from a parser-safe alphabet: no `[`/`]`/`<`/`>`
    /// (which the parser reads as timestamp or word markers) and no newlines.
    /// Trimmed so leading/trailing whitespace can't diverge from the parser, which
    /// trims each line's text; internal spaces are preserved on both sides.
    private static func randomText(_ rng: inout SplitMix64) -> String {
        let length = Int.random(in: 1 ... 24, using: &rng)
        var s = ""
        for _ in 0 ..< length {
            s.append(self.safeAlphabet[Int.random(in: 0 ..< self.safeAlphabet.count, using: &rng)])
        }
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "lyric" : trimmed
    }

    static func timestampCases() -> [TimestampCase] {
        var rng = SplitMix64(seed: 0x11C5_2026)
        return (0 ..< 200).map { _ in
            TimestampCase(
                mm: Int.random(in: 0 ... 999, using: &rng), // pattern allows up to 3 minute digits
                ss: Int.random(in: 0 ... 59, using: &rng),
                cs: Int.random(in: 0 ... 99, using: &rng)
            )
        }
    }

    static func documentCases() -> [DocumentCase] {
        var rng = SplitMix64(seed: 0xB0CA_2026)
        return (0 ..< 120).map { _ in
            let lineCount = Int.random(in: 1 ... 8, using: &rng)
            // Unique centisecond starts so each line pairs unambiguously with its
            // text after both sides sort by start. Capped at 99:59.99.
            var csSet = Set<Int>()
            while csSet.count < lineCount {
                csSet.insert(Int.random(in: 0 ... 599_999, using: &rng))
            }
            let lines = csSet.sorted().map { DocumentCase.LineSpec(cs: $0, text: self.randomText(&rng)) }
            let offset = Bool.random(using: &rng) ? Int.random(in: -5000 ... 5000, using: &rng) : 0
            return DocumentCase(lines: lines, offsetMS: offset)
        }
    }

    // MARK: - Properties

    @Test("randomized [mm:ss.cs] timestamps parse to the exact seconds value", arguments: Self.timestampCases())
    func timestampMathIsExact(_ c: TimestampCase) {
        let raw = String(format: "[%02d:%02d.%02d]Lyric", c.mm, c.ss, c.cs)
        let doc = LRCParser.parseDocument(raw)
        guard case let .synced(lines, _) = doc, let first = lines.first else {
            Issue.record("Expected a .synced document with one line for \(c)")
            return
        }
        let expected = Double(c.mm) * 60 + Double(c.ss) + Double(c.cs) / 100.0
        #expect(abs(first.start - expected) < 0.001)
        #expect(first.text == "Lyric")
    }

    @Test("randomized synced documents round-trip through toLRC → parseDocument", arguments: Self.documentCases())
    func roundTripPreservesTimingTextAndOffset(_ c: DocumentCase) {
        let original = c.lines
            .map { LyricsDocument.LyricsLine(start: Double($0.cs) / 100.0, text: $0.text) }
            .sorted { $0.start < $1.start }
        let doc = LyricsDocument.synced(lines: original, offsetMS: c.offsetMS)

        let reparsed = LRCParser.parseDocument(doc.toLRC())
        guard case let .synced(reLines, reOffset) = reparsed else {
            Issue.record("Re-parsed document should be .synced for case \(c)")
            return
        }

        #expect(reOffset == c.offsetMS)
        #expect(reLines.count == original.count)
        for (orig, re) in zip(original, reLines) {
            // toLRC truncates to centiseconds, so allow up to one centisecond of slip.
            #expect(abs(orig.start - re.start) < 0.02)
            #expect(orig.text == re.text)
        }
    }
}
