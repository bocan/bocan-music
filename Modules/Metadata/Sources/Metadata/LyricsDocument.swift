import Foundation

// MARK: - LyricsDocument

/// A parsed lyrics payload — either unsynced plain text or a time-coded sequence of lines.
public enum LyricsDocument: Sendable, Hashable {
    /// Plain text lyrics with no timing information.
    case unsynced(String)

    /// LRC-style lyrics with per-line timestamps and an optional global offset.
    ///
    /// `offsetMS` follows LRC convention: a *positive* value means the lyrics file's
    /// timestamps run ahead of the audio, so the display should subtract this offset.
    case synced(lines: [LyricsLine], offsetMS: Int)

    // MARK: - Nested types

    /// A single timed lyric line.
    public struct LyricsLine: Sendable, Codable, Hashable {
        /// Line start time in seconds (after any global offset has been applied).
        public let start: TimeInterval

        /// Exclusive end time in seconds. Derived from the next line's `start` minus a small gap;
        /// for the final line it equals track duration when known, otherwise `nil`.
        public var end: TimeInterval?

        /// Display text for the line.
        public let text: String

        /// Word-level timings parsed from enhanced `<mm:ss.xx>` markers (may be `nil`).
        public let words: [WordTime]?

        /// `true` when the source line was malformed — preserved verbatim as unsynced text.
        public let malformed: Bool

        public init(
            start: TimeInterval,
            end: TimeInterval? = nil,
            text: String,
            words: [WordTime]? = nil,
            malformed: Bool = false
        ) {
            self.start = start
            self.end = end
            self.text = text
            self.words = words
            self.malformed = malformed
        }
    }

    /// A single word with its own start timestamp within an enhanced LRC line.
    public struct WordTime: Sendable, Codable, Hashable {
        /// Word start time in seconds (relative to track start, offset already applied).
        public let start: TimeInterval

        /// The word or syllable text.
        public let word: String

        public init(start: TimeInterval, word: String) {
            self.start = start
            self.word = word
        }
    }
}

// MARK: - Codable

extension LyricsDocument: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, text, lines, offsetMS
    }

    private enum TypeKey: String, Codable {
        case unsynced, synced
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(TypeKey.self, forKey: .type)
        switch type {
        case .unsynced:
            let text = try c.decode(String.self, forKey: .text)
            self = .unsynced(text)
        case .synced:
            let lines = try c.decode([LyricsLine].self, forKey: .lines)
            let offset = try c.decodeIfPresent(Int.self, forKey: .offsetMS) ?? 0
            self = .synced(lines: lines, offsetMS: offset)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .unsynced(text):
            try c.encode(TypeKey.unsynced, forKey: .type)
            try c.encode(text, forKey: .text)
        case let .synced(lines, offsetMS):
            try c.encode(TypeKey.synced, forKey: .type)
            try c.encode(lines, forKey: .lines)
            try c.encode(offsetMS, forKey: .offsetMS)
        }
    }
}

// MARK: - Helpers

public extension LyricsDocument {
    /// Returns `true` when the document contains at least one non-empty line / non-empty text.
    var isEmpty: Bool {
        switch self {
        case let .unsynced(text): text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case let .synced(lines, _): lines.isEmpty
        }
    }

    /// The effective offset in milliseconds (positive = lyrics lead the audio).
    var offsetMS: Int {
        switch self {
        case .unsynced: 0
        case let .synced(_, offset): offset
        }
    }

    /// Serialises this document back to canonical LRC text.
    ///
    /// Unsynced documents are returned as-is.  Synced documents produce
    /// `[mm:ss.xx]text` lines, sorted by timestamp, with an `[offset:N]` header
    /// when `offsetMS != 0`.
    func toLRC() -> String {
        switch self {
        case let .unsynced(text):
            return text
        case let .synced(lines, offsetMS):
            var parts: [String] = []
            if offsetMS != 0 {
                parts.append("[offset:\(offsetMS)]")
            }
            for line in lines.sorted(by: { $0.start < $1.start }) {
                let stamp = Self.formatTimestamp(line.start)
                parts.append("[\(stamp)]\(line.text)")
            }
            return parts.joined(separator: "\n")
        }
    }

    private static func formatTimestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, seconds)
        let mins = Int(total) / 60
        let secs = total - Double(mins * 60)
        let cents = Int((secs - Double(Int(secs))) * 100)
        return String(format: "%02d:%02d.%02d", mins, Int(secs), cents)
    }
}
