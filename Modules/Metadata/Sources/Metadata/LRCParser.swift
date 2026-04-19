import Foundation

// MARK: - Line

/// A single lyric line with optional start timestamp.
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

/// Parses LRC-format lyrics into ``LyricLine`` values.
///
/// Supports:
/// - Unsynced plain text blocks
/// - Standard `[mm:ss.xx]` timestamps (hundredths)
/// - Enhanced `[mm:ss.xxx]` timestamps (milliseconds)
public enum LRCParser {
    // [mm:ss.xx] or [mm:ss.xxx]
    // nonisolated(unsafe) because Regex is not Sendable, but the pattern is effectively immutable.
    private nonisolated(unsafe) static let timestampPattern = #/\[(\d{2}):(\d{2})\.(\d{2,3})\]/#

    /// Parses `raw` lyrics string into ``LyricLine`` values.
    ///
    /// Returns unsynced lines when no LRC timestamps are detected.
    public static func parse(_ raw: String) -> [LyricLine] {
        let lines = raw.components(separatedBy: .newlines)

        // Quick check: does this look like LRC?
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
            // Skip metadata tags like [ar:Artist] [al:Album] (no digit:digit prefix)
            if stripped.hasPrefix("[") {
                if stripped.range(of: #"^\[\d{2}:\d{2}"#, options: .regularExpression) == nil {
                    continue
                }
            }
            // Extract all timestamps from line prefix
            var remaining = stripped[stripped.startIndex...]
            var timestamps: [Double] = []
            while let match = remaining.prefixMatch(of: timestampPattern) {
                let mm = Double(match.output.1)!
                let ss = Double(match.output.2)!
                let sub = match.output.3
                let subDouble = if sub.count == 2 {
                    Double(sub)! / 100.0
                } else {
                    Double(sub)! / 1000.0
                }
                timestamps.append(mm * 60.0 + ss + subDouble)
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
}
