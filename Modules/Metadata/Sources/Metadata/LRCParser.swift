import Foundation

// MARK: - LyricLine (legacy)

/// A single lyric line with optional start timestamp.
///
/// > Note: This type is kept for callers that predate `LyricsDocument`.
/// > Prefer ``LyricsDocument`` and ``LRCParser/parseDocument(_:trackDuration:)`` in new code.
public struct LyricLine: Sendable, Equatable {
    /// Start time in seconds, or `nil` for unsynced lines.
    public let timestamp: Double?

    /// Lyric text.
    public let text: String

    public init(timestamp: Double? = nil, text: String) {
        self.timestamp = timestamp
        self.text = text
    }
}

// MARK: - LRCParser

/// Parses LRC-format lyrics into ``LyricsDocument`` or the legacy ``LyricLine`` array.
///
/// Supports:
/// - Standard `[mm:ss.xx]` (centiseconds) and `[mm:ss.xxx]` (milliseconds) timestamps.
/// - Multi-timestamp lines: `[00:10.00][00:20.00]Same line sung thrice`.
/// - Metadata tags: `[ti:]`, `[ar:]`, `[al:]`, `[by:]`, `[offset:±N]`.
/// - Enhanced / word-level `<mm:ss.xx>` within a line (stored but not used by v1 UI).
/// - Malformed lines preserved as unsynced text mixed into the timeline.
public enum LRCParser {
    // MARK: - Patterns

    // [mm:ss.xx] or [mm:ss.xxx]
    // nonisolated(unsafe) because Regex is not Sendable; the pattern is effectively immutable.
    private nonisolated(unsafe) static let timestampPattern = #/\[(\d{1,3}):(\d{2})\.(\d{2,3})\]/#

    // <mm:ss.xx> or <mm:ss.xxx> — enhanced word-level markers
    private nonisolated(unsafe) static let wordPattern = #/<(\d{1,3}):(\d{2})\.(\d{2,3})>/#

    // [offset:+N] or [offset:-N] (N in milliseconds)
    private nonisolated(unsafe) static let offsetPattern = #/\[offset:\s*([+-]?\d+)\s*\]/#

    /// Metadata-only tags — no timestamp digits after the colon
    private nonisolated(unsafe) static let metaPattern = #/^\[(?:ti|ar|al|by|length|re|ve):/#

    // MARK: - Public API

    /// Parses `raw` into a ``LyricsDocument``.
    ///
    /// - Parameters:
    ///   - raw: Raw LRC or plain-text lyrics string.
    ///   - trackDuration: When provided, the last synced line's `end` is set to this value.
    /// - Returns: `.synced` when LRC timestamps are detected; `.unsynced` otherwise.
    public static func parseDocument(_ raw: String, trackDuration: TimeInterval? = nil) -> LyricsDocument {
        let lines = raw.components(separatedBy: .newlines)

        let hasTimestamps = lines.contains { $0.contains(self.timestampPattern) }
        guard hasTimestamps else {
            let text = lines
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            return .unsynced(text)
        }

        var offsetMS = 0
        var result: [LyricsDocument.LyricsLine] = []

        for line in lines {
            let stripped = line.trimmingCharacters(in: .whitespaces)
            guard !stripped.isEmpty else { continue }

            // Capture global offset tag.
            if let offsetMatch = stripped.firstMatch(of: offsetPattern) {
                offsetMS = Int(offsetMatch.output.1) ?? 0
                continue
            }

            // Skip known metadata tags.
            if stripped.firstMatch(of: self.metaPattern) != nil {
                continue
            }

            // Parse line-level timestamps.
            var remaining = stripped[stripped.startIndex...]
            var timestamps: [Double] = []
            while let match = remaining.prefixMatch(of: timestampPattern) {
                timestamps.append(Self.parseTimestamp(match.output.1, match.output.2, match.output.3))
                remaining = remaining[match.range.upperBound...]
            }

            let textRaw = String(remaining).trimmingCharacters(in: .whitespaces)

            // Parse word-level `<mm:ss.xx>` markers from the remaining text.
            let (cleanText, wordTimes) = Self.extractWordTimings(from: textRaw)

            if timestamps.isEmpty {
                // Malformed line inside a synced document — include at t=0 if non-empty.
                if !textRaw.isEmpty {
                    result.append(LyricsDocument.LyricsLine(
                        start: 0,
                        text: cleanText.isEmpty ? textRaw : cleanText,
                        words: wordTimes.isEmpty ? nil : wordTimes,
                        malformed: true
                    ))
                }
            } else {
                let text = cleanText.isEmpty && !timestamps.isEmpty ? textRaw : cleanText
                for ts in timestamps {
                    result.append(LyricsDocument.LyricsLine(
                        start: ts,
                        text: text,
                        words: wordTimes.isEmpty ? nil : wordTimes
                    ))
                }
            }
        }

        var sorted = result.sorted { $0.start < $1.start }

        // Derive `end` times from the next line's `start` (minus a 50ms gap).
        for idx in sorted.indices {
            if idx + 1 < sorted.count {
                sorted[idx].end = sorted[idx + 1].start - 0.05
            } else if let dur = trackDuration {
                sorted[idx].end = dur
            }
        }

        return .synced(lines: sorted, offsetMS: offsetMS)
    }

    /// Parses `raw` lyrics string into ``LyricLine`` values (legacy API).
    ///
    /// - Returns: Unsynced lines when no LRC timestamps are detected.
    public static func parse(_ raw: String) -> [LyricLine] {
        let lines = raw.components(separatedBy: .newlines)

        let hasTimestamps = lines.contains { $0.contains(self.timestampPattern) }
        guard hasTimestamps else {
            return lines
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { LyricLine(text: $0) }
        }

        var result: [LyricLine] = []
        for line in lines {
            let stripped = line.trimmingCharacters(in: .whitespaces)
            guard !stripped.isEmpty else { continue }
            if stripped.firstMatch(of: self.metaPattern) != nil { continue }
            if stripped.contains(self.offsetPattern) { continue }

            var remaining = stripped[stripped.startIndex...]
            var timestamps: [Double] = []
            while let match = remaining.prefixMatch(of: timestampPattern) {
                timestamps.append(Self.parseTimestamp(match.output.1, match.output.2, match.output.3))
                remaining = remaining[match.range.upperBound...]
            }
            let text = String(remaining).trimmingCharacters(in: .whitespaces)
            if timestamps.isEmpty {
                if !text.isEmpty {
                    result.append(LyricLine(text: text))
                }
            } else {
                for ts in timestamps {
                    result.append(LyricLine(timestamp: ts, text: text))
                }
            }
        }
        return result.sorted { ($0.timestamp ?? 0) < ($1.timestamp ?? 0) }
    }

    // MARK: - Helpers

    private static func parseTimestamp(
        _ mm: Substring,
        _ ss: Substring,
        _ sub: Substring
    ) -> Double {
        let minutes = Double(mm) ?? 0
        let seconds = Double(ss) ?? 0
        let subVal: Double = if sub.count == 2 {
            (Double(sub) ?? 0) / 100.0
        } else {
            (Double(sub) ?? 0) / 1000.0
        }
        return minutes * 60.0 + seconds + subVal
    }

    /// Strips enhanced `<mm:ss.xx>` markers from `text`, returning clean display text
    /// and an array of ``LyricsDocument/WordTime`` values.
    ///
    /// Each marker precedes the word(s) it times; text between markers is grouped
    /// under the preceding marker's timestamp.
    private static func extractWordTimings(
        from text: String
    ) -> (cleanText: String, words: [LyricsDocument.WordTime]) {
        guard text.contains(self.wordPattern) else {
            return (text, [])
        }

        var words: [LyricsDocument.WordTime] = []
        var allText = ""
        var remaining = text[text.startIndex...]
        var pendingTS: Double?
        var pendingWord = ""

        while !remaining.isEmpty {
            if let match = remaining.prefixMatch(of: wordPattern) {
                let ts = Self.parseTimestamp(match.output.1, match.output.2, match.output.3)
                if let prev = pendingTS, !pendingWord.isEmpty {
                    words.append(LyricsDocument.WordTime(start: prev, word: pendingWord))
                    allText += pendingWord
                    pendingWord = ""
                }
                pendingTS = ts
                remaining = remaining[match.range.upperBound...]
            } else {
                pendingWord.append(remaining.removeFirst())
            }
        }

        // Flush final word.
        if let ts = pendingTS, !pendingWord.isEmpty {
            words.append(LyricsDocument.WordTime(start: ts, word: pendingWord))
            allText += pendingWord
        } else {
            allText += pendingWord
        }

        return (allText.trimmingCharacters(in: .whitespaces), words)
    }
}
