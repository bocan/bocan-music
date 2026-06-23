import SwiftUI

// MARK: - SafeHTMLRenderer

/// Network-free, whitelist-based HTML to `AttributedString` renderer for podcast
/// show notes.
///
/// It replaces `NSAttributedString`'s HTML importer, which is unsuitable here for
/// two reasons: it can issue synchronous network requests for remote resources
/// (images, external CSS) while parsing, and it renders entity-escaped inline
/// tags (very common in real feeds, e.g. `&lt;b&gt;Note&lt;/b&gt;`) as literal
/// visible text rather than formatting.
///
/// Supported markup: paragraphs / line breaks, `<b>`/`<strong>`, `<i>`/`<em>`,
/// `<a href>` (http/https only), `<ul>`/`<ol>`/`<li>`, `<h1>`-`<h6>`,
/// `<blockquote>`, and HTML entity decoding. Everything else (colours, fonts,
/// inline styles, scripts, images) is dropped. Attribute-less inline tags that a
/// feed entity-escaped inside otherwise-real HTML are recognised and rendered as
/// formatting too.
enum SafeHTMLRenderer {
    /// Renders `html` to a styled `AttributedString`. Never throws; malformed
    /// input degrades to its readable text.
    static func render(_ html: String) -> AttributedString {
        // Recognise attribute-less inline tags that the feed entity-escaped inside
        // otherwise-real HTML, so they format instead of showing as literal text.
        let normalized = self.unescapeInlineTags(html)
        var tokenizer = Tokenizer(normalized)
        var builder = Builder()
        return builder.build(from: tokenizer.tokenize())
    }

    /// Convert escaped, attribute-less inline tags (`&lt;b&gt;`, `&lt;/i&gt;`,
    /// `&lt;br&gt;`, ...) back to real tags. Tags carrying attributes are left
    /// escaped on purpose: blindly unescaping a quoted attribute value is unsafe.
    private static func unescapeInlineTags(_ html: String) -> String {
        var result = html
        let inline = ["b", "strong", "i", "em", "u", "br"]
        for tag in inline {
            for variant in ["&lt;\(tag)&gt;", "&lt;\(tag)/&gt;", "&lt;/\(tag)&gt;"] {
                let real = variant
                    .replacingOccurrences(of: "&lt;", with: "<")
                    .replacingOccurrences(of: "&gt;", with: ">")
                result = result.replacingOccurrences(
                    of: variant,
                    with: real,
                    options: .caseInsensitive
                )
            }
        }
        return result
    }
}

// MARK: - Tokens

private enum HTMLToken {
    case text(String)
    case open(tag: String, href: URL?)
    case close(tag: String)
}

// MARK: - Tokenizer

/// Lenient single-pass HTML tokenizer. A `<` that does not begin a well-formed
/// tag is emitted as literal text, so stray angle brackets survive intact.
private struct Tokenizer {
    private let scalars: [Character]
    private var index = 0

    init(_ html: String) {
        self.scalars = Array(html)
    }

    mutating func tokenize() -> [HTMLToken] {
        var tokens: [HTMLToken] = []
        var text = ""

        func flushText() {
            if !text.isEmpty {
                tokens.append(.text(HTMLEntities.decode(text)))
                text = ""
            }
        }

        while self.index < self.scalars.count {
            let char = self.scalars[self.index]
            if char == "<", let (token, next) = self.parseTag(from: self.index) {
                flushText()
                if let token { tokens.append(token) }
                self.index = next
            } else {
                text.append(char)
                self.index += 1
            }
        }
        flushText()
        return tokens
    }

    /// A lexed `<...>` span: either an ignorable comment/declaration or an element.
    private enum ScannedTag {
        case ignorable(end: Int)
        case element(tag: String, attrs: String, isClosing: Bool, end: Int)
    }

    /// Parse a tag starting at `start` (which points at `<`). Returns the produced
    /// token (nil for a recognised-but-ignored tag, e.g. `<span>`) and the index
    /// just past `>`. Returns nil entirely when this is not a parseable tag.
    private func parseTag(from start: Int) -> (HTMLToken?, Int)? {
        guard let scanned = self.scanTag(from: start) else { return nil }
        switch scanned {
        case let .ignorable(end):
            return (nil, end)

        case let .element(tag, attrs, isClosing, end):
            // Raw-text containers: drop the element *and its contents* (e.g. script
            // bodies must never surface as visible text).
            if !isClosing, Self.rawTextTags.contains(tag) {
                return (nil, self.skipRawText(tag, from: end))
            }
            guard Builder.knownTags.contains(tag) else { return (nil, end) }
            if isClosing { return (.close(tag: tag), end) }
            let href = tag == "a" ? HTMLEntities.webURL(Self.attribute("href", in: attrs)) : nil
            return (.open(tag: tag, href: href), end)
        }
    }

    /// Lex the `<...>` span at `start`, returning its parts or nil when it is not a
    /// well-formed tag (so the caller can treat the `<` as literal text).
    private func scanTag(from start: Int) -> ScannedTag? {
        var i = start + 1
        guard i < self.scalars.count else { return nil }

        // Comments and declarations: skip to the next '>'.
        if self.scalars[i] == "!" {
            while i < self.scalars.count, self.scalars[i] != ">" {
                i += 1
            }
            return .ignorable(end: min(i + 1, self.scalars.count))
        }

        let isClosing = self.scalars[i] == "/"
        if isClosing { i += 1 }

        var name = ""
        while i < self.scalars.count, self.scalars[i].isLetter || self.scalars[i].isNumber {
            name.append(self.scalars[i])
            i += 1
        }
        guard !name.isEmpty else { return nil }

        // Capture the raw attribute span up to the closing '>'.
        var attrs = ""
        while i < self.scalars.count, self.scalars[i] != ">" {
            attrs.append(self.scalars[i])
            i += 1
        }
        guard i < self.scalars.count else { return nil } // unterminated tag
        return .element(tag: name.lowercased(), attrs: attrs, isClosing: isClosing, end: i + 1)
    }

    /// Tags whose entire content is discarded, not just the tag itself.
    private static let rawTextTags: Set = ["script", "style", "head", "title", "noscript"]

    /// Return the index just past `</tag>` (case-insensitive); end-of-input if the
    /// element is never closed.
    private func skipRawText(_ tag: String, from start: Int) -> Int {
        let closing = Array("</\(tag)")
        var i = start
        while i < self.scalars.count {
            if self.scalars[i] == "<",
               i + closing.count <= self.scalars.count,
               String(self.scalars[i ..< i + closing.count]).lowercased() == "</\(tag)" {
                var j = i + closing.count
                while j < self.scalars.count, self.scalars[j] != ">" {
                    j += 1
                }
                return min(j + 1, self.scalars.count)
            }
            i += 1
        }
        return self.scalars.count
    }

    /// Extract a quoted attribute value (`name="..."` / `name='...'`) from a raw
    /// attribute span, entity-decoded.
    private static func attribute(_ name: String, in raw: String) -> String? {
        let lower = raw.lowercased()
        guard let nameRange = lower.range(of: name) else { return nil }
        var i = nameRange.upperBound
        // Skip whitespace and the '='.
        while i < raw.endIndex, raw[i] == " " || raw[i] == "=" {
            i = raw.index(after: i)
        }
        guard i < raw.endIndex else { return nil }
        let quote = raw[i]
        guard quote == "\"" || quote == "'" else { return nil }
        i = raw.index(after: i)
        var value = ""
        while i < raw.endIndex, raw[i] != quote {
            value.append(raw[i])
            i = raw.index(after: i)
        }
        return HTMLEntities.decode(value)
    }
}

// MARK: - Builder

/// Consumes tokens into a styled `AttributedString`, tracking inline emphasis,
/// links, headings, and list nesting. Whitespace is collapsed HTML-style and
/// block boundaries become at most a blank line.
private struct Builder {
    /// Tags the tokenizer surfaces; everything else is dropped.
    static let knownTags: Set = [
        "b", "strong", "i", "em", "u", "a", "br",
        "p", "div", "ul", "ol", "li", "blockquote",
        "h1", "h2", "h3", "h4", "h5", "h6",
    ]
    private static let blockTags: Set = [
        "p", "div", "ul", "ol", "li", "blockquote",
        "h1", "h2", "h3", "h4", "h5", "h6",
    ]

    private var out = AttributedString()
    private var bold = 0
    private var italic = 0
    private var linkStack: [URL] = []
    private var headingStack: [Int] = []
    /// One entry per open list: `ordered` plus the running item counter.
    private var listStack: [(ordered: Bool, counter: Int)] = []
    /// Pending vertical separation (0, 1, or 2 newlines) to flush before the next
    /// visible text. Starts at 0 so the output has no leading blank lines.
    private var pendingNewlines = 0

    mutating func build(from tokens: [HTMLToken]) -> AttributedString {
        for token in tokens {
            switch token {
            case let .text(text):
                self.appendText(text)

            case let .open(tag, href):
                self.openTag(tag, href: href)

            case let .close(tag):
                self.closeTag(tag)
            }
        }
        // Trim a trailing newline run the block flushing may have queued.
        while let last = self.out.characters.last, last == "\n" {
            self.out.removeSubrange(self.out.index(beforeCharacter: self.out.endIndex) ..< self.out.endIndex)
        }
        return self.out
    }

    private mutating func openTag(_ tag: String, href: URL?) {
        switch tag {
        case "b", "strong":
            self.bold += 1

        case "i", "em":
            self.italic += 1

        case "u":
            break // underline intentionally not styled; keep text legible

        case "a":
            if let href { self.linkStack.append(href) }

        case "br":
            self.pendingNewlines = max(self.pendingNewlines, 1)

        case "ul":
            self.listStack.append((ordered: false, counter: 0))

        case "ol":
            self.listStack.append((ordered: true, counter: 0))

        case "h1", "h2", "h3", "h4", "h5", "h6":
            self.requestParagraphBreak()
            self.headingStack.append(Int(String(tag.dropFirst())) ?? 3)

        case "li":
            self.requestParagraphBreak()
            self.flushPending()
            self.appendMarker()

        case "p", "div", "blockquote":
            self.requestParagraphBreak()

        default:
            break
        }
    }

    private mutating func closeTag(_ tag: String) {
        switch tag {
        case "b", "strong":
            self.bold = max(0, self.bold - 1)

        case "i", "em":
            self.italic = max(0, self.italic - 1)

        case "a":
            if !self.linkStack.isEmpty { self.linkStack.removeLast() }

        case "ul", "ol":
            if !self.listStack.isEmpty { self.listStack.removeLast() }

        case "h1", "h2", "h3", "h4", "h5", "h6":
            if !self.headingStack.isEmpty { self.headingStack.removeLast() }
            self.requestParagraphBreak()

        case "p", "div", "blockquote", "li":
            self.requestParagraphBreak()

        default:
            break
        }
    }

    /// Append text after collapsing internal whitespace. Empty/whitespace-only
    /// runs are dropped so block markup does not inject stray spaces.
    private mutating func appendText(_ raw: String) {
        let collapsed = raw.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        if collapsed.trimmingCharacters(in: .whitespaces).isEmpty { return }
        self.flushPending()
        var run = AttributedString(collapsed)
        run.mergeAttributes(self.currentAttributes())
        self.out.append(run)
    }

    /// Prefix the current list item with "• " (unordered) or "N. " (ordered).
    private mutating func appendMarker() {
        guard !self.listStack.isEmpty else { return }
        var top = self.listStack[self.listStack.count - 1]
        top.counter += 1
        self.listStack[self.listStack.count - 1] = top
        let indent = String(repeating: "    ", count: max(0, self.listStack.count - 1))
        let marker = top.ordered ? "\(top.counter). " : "•  "
        var run = AttributedString(indent + marker)
        run.mergeAttributes(self.currentAttributes())
        self.out.append(run)
    }

    private mutating func requestParagraphBreak() {
        guard !self.out.characters.isEmpty || self.pendingNewlines > 0 else { return }
        self.pendingNewlines = 2
    }

    /// Emit queued newlines, but never at the very start of the output.
    private mutating func flushPending() {
        guard self.pendingNewlines > 0, !self.out.characters.isEmpty else {
            self.pendingNewlines = 0
            return
        }
        self.out.append(AttributedString(String(repeating: "\n", count: self.pendingNewlines)))
        self.pendingNewlines = 0
    }

    private func currentAttributes() -> AttributeContainer {
        var container = AttributeContainer()
        var intent: InlinePresentationIntent = []
        if self.bold > 0 || !self.headingStack.isEmpty { intent.insert(.stronglyEmphasized) }
        if self.italic > 0 { intent.insert(.emphasized) }
        if !intent.isEmpty { container.inlinePresentationIntent = intent }
        if let level = self.headingStack.last {
            container.font = .system(size: level <= 1 ? 17 : level == 2 ? 15 : 14, weight: .bold)
        }
        if let url = self.linkStack.last { container.link = url }
        return container
    }
}

// MARK: - HTMLEntities

/// Minimal, dependency-free HTML entity decoder: the named entities common in
/// podcast notes plus decimal/hex numeric references. Unknown entities are left
/// verbatim.
enum HTMLEntities {
    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": "\u{00A0}", "mdash": "\u{2014}", "ndash": "\u{2013}",
        "hellip": "\u{2026}", "lsquo": "\u{2018}", "rsquo": "\u{2019}",
        "ldquo": "\u{201C}", "rdquo": "\u{201D}", "copy": "\u{00A9}",
        "reg": "\u{00AE}", "trade": "\u{2122}", "deg": "\u{00B0}",
        "bull": "\u{2022}", "middot": "\u{00B7}", "eacute": "\u{00E9}",
    ]

    static func decode(_ string: String) -> String {
        guard string.contains("&") else { return string }
        var result = ""
        result.reserveCapacity(string.count)
        var rest = Substring(string)
        while let amp = rest.firstIndex(of: "&") {
            result += rest[rest.startIndex ..< amp]
            let after = rest[rest.index(after: amp)...]
            guard let semi = after.firstIndex(of: ";"), after.distance(from: after.startIndex, to: semi) <= 10 else {
                result.append("&")
                rest = after
                continue
            }
            let body = String(after[after.startIndex ..< semi])
            if let decoded = self.decodeEntity(body) {
                result += decoded
            } else {
                result += "&\(body);"
            }
            rest = after[after.index(after: semi)...]
        }
        result += rest
        return result
    }

    private static func decodeEntity(_ body: String) -> String? {
        if body.hasPrefix("#") {
            let digits = body.dropFirst()
            let value: UInt32? = if digits.first == "x" || digits.first == "X" {
                UInt32(digits.dropFirst(), radix: 16)
            } else {
                UInt32(digits)
            }
            if let value, let scalar = Unicode.Scalar(value) { return String(scalar) }
            return nil
        }
        return self.named[body]
    }

    /// Only `http`/`https` links are kept; feed-supplied URLs are untrusted.
    static func webURL(_ raw: String?) -> URL? {
        guard let raw,
              let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }
}
