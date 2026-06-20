import Foundation
import Persistence

// MARK: - Cue types

/// One transcript cue. `end` is nil when the source format gives no end time.
public struct TranscriptCue: Sendable, Hashable, Identifiable {
    public let id: Int
    public let start: TimeInterval
    public let end: TimeInterval?
    public let speaker: String?
    public let text: String

    public init(id: Int, start: TimeInterval, end: TimeInterval?, speaker: String?, text: String) {
        self.id = id
        self.start = start
        self.end = end
        self.speaker = speaker
        self.text = text
    }
}

/// A parsed transcript: timed cues, or one plain block when there is no timing.
public enum TranscriptContent: Sendable, Hashable {
    case timed([TranscriptCue])
    case plain(String)
}

// MARK: - TranscriptParser

/// Pure, I/O-free transcript parser. Best-effort: a malformed body for any format
/// degrades to `.plain(content)` rather than failing the viewer.
///
/// Lives in `UI` (not `Podcasts`) because it is consumed at view time and `UI`
/// must not import `Podcasts`; it shares only the `TranscriptFormat` discriminator
/// via `Persistence`. The fetch/cache parser-free path lives in `Podcasts`.
enum TranscriptParser {
    static func parse(_ content: String, format: TranscriptFormat) -> TranscriptContent {
        let body = self.stripBOM(content)
        switch format {
        case .vtt:
            return self.parseCues(body, commaDecimal: false)

        case .srt:
            return self.parseCues(body, commaDecimal: true)

        case .json:
            return self.parseJSON(body)

        case .html:
            return .plain(self.stripHTML(body))

        case .plain:
            return .plain(body)
        }
    }

    // MARK: - VTT / SRT

    /// Parses WebVTT and SRT, which differ only in the decimal separator (`.` vs
    /// `,`) and SRT's leading numeric index line. Blocks split on blank lines; a
    /// block is a cue when it has a `-->` timing line, so the `WEBVTT` header and
    /// `NOTE` / `STYLE` blocks (which have none) are skipped.
    private static func parseCues(_ content: String, commaDecimal: Bool) -> TranscriptContent {
        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let blocks = normalized.components(separatedBy: "\n\n")
        var cues: [TranscriptCue] = []
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let timing = lines[timingIndex]
            let endpoints = timing.components(separatedBy: "-->")
            guard endpoints.count == 2,
                  let start = self.seconds(from: endpoints[0]) else { continue }
            // The end side may carry cue settings after the timestamp; take the first token.
            let end = endpoints[1].split(separator: " ").first.flatMap { self.seconds(from: String($0)) }
            let rawText = lines[(timingIndex + 1)...].joined(separator: "\n")
            guard !rawText.isEmpty else { continue }
            let (speaker, text) = self.extractVoice(rawText)
            cues.append(TranscriptCue(id: cues.count, start: start, end: end, speaker: speaker, text: text))
            _ = commaDecimal // separator handled in seconds(from:)
        }
        return cues.isEmpty ? .plain(content) : .timed(cues)
    }

    /// Parses `HH:MM:SS.mmm`, `MM:SS.mmm`, or `SS.mmm`, tolerating the SRT comma.
    private static func seconds(from timestamp: String) -> TimeInterval? {
        let trimmed = timestamp
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        let parts = trimmed.split(separator: ":")
        guard !parts.isEmpty else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part) else { return nil }
            total = total * 60 + value
        }
        return total
    }

    /// Lifts a leading `<v Speaker>` voice tag into the speaker, then strips any
    /// remaining inline tags from the text.
    private static func extractVoice(_ raw: String) -> (speaker: String?, text: String) {
        var speaker: String?
        if let match = raw.range(of: "<v\\s+([^>]+)>", options: .regularExpression) {
            let tag = String(raw[match])
            speaker = tag
                .replacingOccurrences(of: "<v", with: "")
                .replacingOccurrences(of: ">", with: "")
                .trimmingCharacters(in: .whitespaces)
        }
        let stripped = raw
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (speaker, stripped)
    }

    // MARK: - JSON (Podcasting 2.0)

    private static func parseJSON(_ content: String) -> TranscriptContent {
        guard let data = content.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(JSONTranscriptDocument.self, from: data),
              let segments = decoded.segments, !segments.isEmpty else {
            return .plain(content)
        }
        var cues: [TranscriptCue] = []
        for segment in segments {
            let text = (segment.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            cues.append(TranscriptCue(
                id: cues.count,
                start: segment.startTime ?? 0,
                end: segment.endTime,
                speaker: segment.speaker,
                text: text
            ))
        }
        return cues.isEmpty ? .plain(content) : .timed(cues)
    }

    // MARK: - HTML / helpers

    private static func stripHTML(_ content: String) -> String {
        let noScripts = content.replacingOccurrences(
            of: "<script[\\s\\S]*?</script>",
            with: "",
            options: .regularExpression
        )
        let noTags = noScripts.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let decoded = noTags
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        let collapsed = decoded.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        return collapsed
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripBOM(_ content: String) -> String {
        content.hasPrefix("\u{FEFF}") ? String(content.dropFirst()) : content
    }
}

// MARK: - JSON shapes (Podcasting 2.0 transcript)

private struct JSONTranscriptDocument: Decodable {
    let segments: [JSONTranscriptSegment]?
}

private struct JSONTranscriptSegment: Decodable {
    let startTime: Double?
    let endTime: Double?
    let speaker: String?
    let body: String?
}
