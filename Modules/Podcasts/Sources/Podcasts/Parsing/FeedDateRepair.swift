import FeedKit
import Foundation

/// Rewrites or removes the dates in a feed that FeedKit cannot read, so that one
/// bad `pubDate` does not fail the whole feed.
///
/// FeedKit throws out of `Feed(data:)` on any date it cannot read (`2024-01-01`,
/// `01 Sept 2024`). `FeedParser.parse` calls this only after that parse has
/// failed, so a feed that parses today never comes through here.
///
/// A date FeedKit reads stays as the feed wrote it. A date it cannot read is
/// rewritten when it is one of the few shapes understood here (a long month
/// name, a date without a time), and its element is removed otherwise. The
/// episode then has no date; it keeps everything else.
struct FeedDateRepair {
    /// The repaired bytes, and how many date elements changed.
    struct Outcome {
        let data: Data
        let rewritten: Int
        let dropped: Int
    }

    /// What to do with one date value.
    private enum Verdict {
        case keep
        case rewrite(String)
        case drop
    }

    /// The elements FeedKit decodes as dates. It matches on the prefix, not the
    /// namespace URI, so the prefixes here are literal.
    private static let dateElement = #"pubDate|lastBuildDate|updated|published|dc:date|sy:updateBase"#

    /// One date element with a plain or CDATA value. Group 1 is the name,
    /// group 2 the CDATA value, group 3 the plain value.
    private static let pattern =
        #"<("# + dateElement + #")(?:\s[^>]*)?>\s*(?:<!\[CDATA\[(.*?)\]\]>|([^<]*))\s*</\1\s*>"#

    /// Long month names, and the "Sept" some publishers write, mapped to the
    /// three-letter form that RFC 822 requires. "September" comes before "Sept".
    private static let longMonths = [
        "January", "February", "March", "April", "June", "July", "August",
        "September", "Sept", "October", "November", "December",
    ]

    /// Date-only shapes, tried after the month names are shortened.
    private static let dateOnlyFormats = ["yyyy-MM-dd", "d MMM yyyy", "MMM d, yyyy"]

    /// Returns the repaired feed, or `nil` when FeedKit reads every date in
    /// `data` (the parse failed for some other reason) or no date was found.
    func repair(_ data: Data) -> Outcome? {
        // Latin-1 maps every byte to one character and back, so any
        // ASCII-compatible encoding round-trips byte for byte. The dates and
        // the markup around them are ASCII.
        guard let text = String(data: data, encoding: .isoLatin1) else { return nil }
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: Self.pattern, options: [.dotMatchesLineSeparators])
        } catch {
            // The pattern is a constant; the tests would catch a bad one.
            return nil
        }
        let source = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return nil }

        let values = matches.map { Self.value(of: $0, in: source) }
        // One probe for the common case: every date is readable.
        if Self.feedKitReads(Set(values)) {
            return nil
        }

        var verdicts: [String: Verdict] = [:]
        var output = ""
        output.reserveCapacity(source.length)
        var cursor = 0
        var rewritten = 0
        var dropped = 0
        for (match, value) in zip(matches, values) {
            let verdict = verdicts[value] ?? Self.verdict(for: value)
            verdicts[value] = verdict
            output += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            switch verdict {
            case .keep:
                output += source.substring(with: match.range)
            case let .rewrite(date):
                let name = source.substring(with: match.range(at: 1))
                output += "<\(name)>\(date)</\(name)>"
                rewritten += 1
            case .drop:
                dropped += 1
            }
            cursor = match.range.location + match.range.length
        }
        output += source.substring(from: cursor)

        guard rewritten + dropped > 0, let repaired = output.data(using: .isoLatin1) else { return nil }
        return Outcome(data: repaired, rewritten: rewritten, dropped: dropped)
    }

    // MARK: - Private

    private static func value(of match: NSTextCheckingResult, in source: NSString) -> String {
        let cdata = match.range(at: 2)
        let range = cdata.location == NSNotFound ? match.range(at: 3) : cdata
        return source.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func verdict(for value: String) -> Verdict {
        if value.isEmpty || self.feedKitReads([value]) {
            return .keep
        }
        let shortened = self.shorteningMonths(in: value)
        if shortened != value, self.feedKitReads([shortened]) {
            return .rewrite(shortened)
        }
        if let date = self.dateOnly(shortened) {
            return .rewrite(date.formatted(Date.ISO8601FormatStyle(timeZone: .gmt)))
        }
        return .drop
    }

    /// True when FeedKit reads every value as a date. The probe is a minimal
    /// RSS document, because FeedKit's date reader is not public.
    private static func feedKitReads(_ values: Set<String>) -> Bool {
        let items = values.map { value in
            let escaped = value
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            return "<item><pubDate>\(escaped)</pubDate></item>"
        }
        let probe = #"<rss version="2.0"><channel><title>probe</title>"# + items.joined() + "</channel></rss>"
        do {
            _ = try Feed(data: Data(probe.utf8))
            return true
        } catch {
            return false
        }
    }

    private static func shorteningMonths(in value: String) -> String {
        self.longMonths.reduce(value) { result, month in
            result.replacingOccurrences(
                of: #"\b"# + month + #"\b"#,
                with: String(month.prefix(3)),
                options: [.regularExpression, .caseInsensitive]
            )
        }
    }

    /// Reads a date that has no time, with or without a leading weekday, as
    /// midnight UTC of that day.
    private static func dateOnly(_ value: String) -> Date? {
        var text = value
        if let comma = text.firstIndex(of: ","), text[..<comma].allSatisfy(\.isLetter), comma > text.startIndex {
            text = text[text.index(after: comma)...].trimmingCharacters(in: .whitespaces)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .gmt
        formatter.isLenient = false
        for format in self.dateOnlyFormats {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) {
                return date
            }
        }
        return nil
    }
}
