import Foundation
import Observability
import Persistence

/// Best-effort extraction of the Podcasting 2.0 tags FeedKit 10.4.0 does not model:
/// channel-level `podcast:funding`, per-item `podcast:chapters`, and `podcast:person`
/// credits at both the channel (show) and item (episode) level.
///
/// It re-reads the same bytes `FeedFetcher` returned, after FeedKit, and the
/// result is merged into `ParsedFeed` in `FeedParser.parse`. It is intentionally
/// small, internal, and self-contained: if a future FeedKit release models these
/// tags, delete this file and the one merge block in `FeedParser`.
///
/// It never throws. Any parse failure logs at debug and yields whatever partial
/// result was accumulated, so the main FeedKit parse is never affected.
struct PodcastNamespaceSupplement {
    /// The extracted values, keyed for merge.
    struct Result {
        var fundingURL: URL?
        var fundingText: String?
        /// Item `guid` (else enclosure URL, matching `FeedParser.parseRSSItem`)
        /// mapped to its `podcast:chapters` URL.
        var chaptersByGUID: [String: URL] = [:]
        /// Channel-level `podcast:person` credits (show hosts / regulars).
        var channelPersons: [PodcastPerson] = []
        /// Item `guid` (else enclosure URL) mapped to its `podcast:person` credits.
        var personsByGUID: [String: [PodcastPerson]] = [:]
    }

    /// Canonical Podcasting 2.0 namespace URI. We match on the namespace, not the
    /// `podcast:` prefix, because a feed may bind the namespace to any prefix.
    static let namespaceURI = "https://podcastindex.org/namespace/1.0"

    private let log = AppLogger.make(.podcasts)

    func extract(from data: Data) -> Result {
        let driver = Driver()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = driver
        if !parser.parse() {
            self.log.debug("feed.supplement.failed", [
                "error": String(reflecting: parser.parserError as Any),
            ])
        }
        return driver.result
    }

    /// Only `http` / `https` URLs are kept; feed-supplied URLs are untrusted.
    static func webURL(_ raw: String?) -> URL? {
        guard let raw,
              let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }

    /// Trims a string attribute, returning `nil` when empty.
    static func cleanAttr(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Driver

/// Synchronous `XMLParser` delegate. Created, used, and discarded entirely within
/// `extract(from:)`, so it never crosses a concurrency boundary.
private final class Driver: NSObject, XMLParserDelegate {
    var result = PodcastNamespaceSupplement.Result()

    // Scope tracking.
    private var inChannel = false
    private var inItem = false

    // Channel funding (keep the first occurrence only).
    private var capturedFunding = false
    private var capturingFundingText = false
    private var fundingTextBuffer = ""

    // Per-item state, committed on the item's end element.
    private var currentItemGUID: String?
    private var currentItemEnclosureURL: String?
    private var currentItemChaptersURL: URL?
    private var currentItemPersons: [PodcastPerson] = []
    private var capturingGUID = false
    private var guidBuffer = ""

    // Person capture (podcast:person, channel- or item-level). Attributes are read at
    // the start element and combined with the trimmed text at the end element.
    private var capturingPersonText = false
    private var personTextBuffer = ""
    private var pendingPersonRole: String?
    private var pendingPersonGroup: String?
    private var pendingPersonImageURL: String?
    private var pendingPersonHref: String?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        if namespaceURI == PodcastNamespaceSupplement.namespaceURI {
            switch elementName {
            case "funding" where self.inChannel && !self.inItem && !self.capturedFunding:
                self.result.fundingURL = PodcastNamespaceSupplement.webURL(attributeDict["url"])
                self.capturingFundingText = true
                self.fundingTextBuffer = ""
            case "chapters" where self.inItem && self.currentItemChaptersURL == nil:
                self.currentItemChaptersURL = PodcastNamespaceSupplement.webURL(attributeDict["url"])
            case "person" where self.inChannel || self.inItem:
                self.capturingPersonText = true
                self.personTextBuffer = ""
                self.pendingPersonRole = PodcastNamespaceSupplement.cleanAttr(attributeDict["role"])
                self.pendingPersonGroup = PodcastNamespaceSupplement.cleanAttr(attributeDict["group"])
                self.pendingPersonImageURL = PodcastNamespaceSupplement.webURL(attributeDict["img"])?.absoluteString
                self.pendingPersonHref = PodcastNamespaceSupplement.webURL(attributeDict["href"])?.absoluteString
            default:
                break
            }
            return
        }

        // Standard (non-namespaced) RSS 2.0 elements.
        switch elementName {
        case "channel":
            self.inChannel = true
        case "item":
            self.inItem = true
            self.currentItemGUID = nil
            self.currentItemEnclosureURL = nil
            self.currentItemChaptersURL = nil
            self.currentItemPersons = []
        case "guid" where self.inItem:
            self.capturingGUID = true
            self.guidBuffer = ""
        case "enclosure" where self.inItem:
            self.currentItemEnclosureURL = attributeDict["url"]
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if self.capturingFundingText {
            self.fundingTextBuffer += string
        }
        if self.capturingGUID {
            self.guidBuffer += string
        }
        if self.capturingPersonText {
            self.personTextBuffer += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if namespaceURI == PodcastNamespaceSupplement.namespaceURI {
            if elementName == "funding", self.capturingFundingText {
                let text = self.fundingTextBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                self.result.fundingText = text.isEmpty ? nil : text
                self.capturingFundingText = false
                self.fundingTextBuffer = ""
                self.capturedFunding = true
            } else if elementName == "person", self.capturingPersonText {
                self.commitPerson()
            }
            return
        }

        switch elementName {
        case "channel":
            self.inChannel = false
        case "item":
            self.commitItem()
        case "guid" where self.capturingGUID:
            // Trim to match FeedKit/XMLKit, which trims element text.
            let guid = self.guidBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            self.currentItemGUID = guid.isEmpty ? nil : guid
            self.capturingGUID = false
            self.guidBuffer = ""
        default:
            break
        }
    }

    /// Commit the buffered chapters URL under the same key `FeedParser` uses:
    /// the item `guid` when present, else the enclosure URL.
    private func commitItem() {
        let key = self.currentItemGUID ?? self.currentItemEnclosureURL
        if let chapters = self.currentItemChaptersURL, let key, self.result.chaptersByGUID[key] == nil {
            self.result.chaptersByGUID[key] = chapters
        }
        if !self.currentItemPersons.isEmpty, let key, self.result.personsByGUID[key] == nil {
            self.result.personsByGUID[key] = self.currentItemPersons
        }
        self.inItem = false
        self.currentItemGUID = nil
        self.currentItemEnclosureURL = nil
        self.currentItemChaptersURL = nil
        self.currentItemPersons = []
        self.capturingGUID = false
        self.guidBuffer = ""
    }

    /// Build a `PodcastPerson` from the buffered name + pending attributes and append
    /// it to the item (when inside one) or the channel. Resets the person buffers.
    private func commitPerson() {
        let name = self.personTextBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        let person = PodcastPerson(
            name: name,
            role: self.pendingPersonRole,
            group: self.pendingPersonGroup,
            imageURL: self.pendingPersonImageURL,
            href: self.pendingPersonHref
        )
        self.capturingPersonText = false
        self.personTextBuffer = ""
        self.pendingPersonRole = nil
        self.pendingPersonGroup = nil
        self.pendingPersonImageURL = nil
        self.pendingPersonHref = nil
        guard !name.isEmpty else { return }
        if self.inItem {
            self.currentItemPersons.append(person)
        } else if self.inChannel {
            self.result.channelPersons.append(person)
        }
    }
}
