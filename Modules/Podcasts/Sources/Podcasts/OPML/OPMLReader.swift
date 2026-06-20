import Foundation

// MARK: - OPMLReader

/// Reads an OPML 2.0 subscription list into flat feed entries.
///
/// OPML nests feeds as `<opml><body><outline xmlUrl=...>`; group outlines carry
/// no `xmlUrl` and contain child `<outline>` elements. This reader flattens the
/// tree: it collects one `OPMLEntry` per outline (at any depth) whose `xmlUrl`
/// is a non-empty `http`/`https` URL, and silently skips group outlines and
/// outlines without a usable feed URL. A malformed XML document throws once,
/// up front, since OPML is the entire input.
public enum OPMLReader {
    /// Parses OPML into feed entries. Throws `PodcastsError.parseFailed` on a
    /// malformed XML document.
    public static func parse(data: Data, sourceURL: URL? = nil) throws -> [OPMLEntry] {
        let parser = XMLParser(data: data)
        let delegate = OPMLParserDelegate()
        parser.delegate = delegate
        guard parser.parse() else {
            let reason = parser.parserError.map { String(describing: $0) } ?? "unknown XML error"
            throw PodcastsError.parseFailed(url: sourceURL ?? URL(fileURLWithPath: "opml-input"), reason: reason)
        }
        return delegate.entries
    }
}

// MARK: - OPMLParserDelegate

private final class OPMLParserDelegate: NSObject, XMLParserDelegate {
    var entries: [OPMLEntry] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        guard elementName.lowercased() == "outline" else { return }
        guard let rawFeed = Self.attribute("xmlUrl", in: attributeDict), !rawFeed.isEmpty,
              let feedURL = URL(string: rawFeed),
              let scheme = feedURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return // group outline, type="link", or non-http feed: skip (children still flatten in)
        }
        let html = Self.attribute("htmlUrl", in: attributeDict).flatMap { URL(string: $0) }
        let title = Self.attribute("title", in: attributeDict)?.nilIfBlank
            ?? Self.attribute("text", in: attributeDict)?.nilIfBlank
            ?? feedURL.host
            ?? rawFeed
        self.entries.append(OPMLEntry(feedURL: feedURL, title: title, htmlURL: html))
    }

    /// OPML uses camelCase `xmlUrl`/`htmlUrl`; tolerate producers that lowercase.
    private static func attribute(_ name: String, in dict: [String: String]) -> String? {
        if let value = dict[name] { return value }
        let lowered = name.lowercased()
        return dict.first { $0.key.lowercased() == lowered }?.value
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = self.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
