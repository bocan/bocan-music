import FeedKit
import Foundation
import Observability

/// Wraps FeedKit to parse RSS 2.0 and Atom feeds into the module's
/// `ParsedFeed` / `ParsedEpisode` value types.
///
/// FeedKit 10.x models are `Sendable` (and `Codable`), so no `@preconcurrency`
/// boundary is required. No FeedKit type escapes this struct's API surface.
public struct FeedParser: Sendable {
    private let log = AppLogger.make(.podcasts)

    public init() {}

    /// Parse raw feed data into a normalized `ParsedFeed`.
    ///
    /// - Parameters:
    ///   - data: Raw XML bytes from `FeedFetcher`.
    ///   - sourceURL: The URL the feed was fetched from (used in error messages).
    /// - Returns: A `ParsedFeed` with episodes sorted newest-first.
    /// - Throws: `PodcastsError.parseFailed` or `.notAFeed`.
    public func parse(_ data: Data, sourceURL: URL) throws -> ParsedFeed {
        let feed: Feed
        do {
            // Synchronous, throwing core initializer; auto-detects RSS/Atom/JSON.
            // We never use the async urlString:/url: initializers because they
            // would bypass FeedFetcher's conditional GET, size cap, and User-Agent.
            feed = try Feed(data: data)
        } catch {
            // FeedKit's format sniffer inspects only the first 128 bytes. Feeds that
            // carry an `<?xml-stylesheet?>` PI (so browsers render them) push the
            // `<rss>`/`<feed>` root past that window, yielding `unknownFeedFormat`.
            // Retry once with the XML prolog stripped so the root leads the data.
            if let stripped = Self.feedDataWithStrippedProlog(data), let retried = try? Feed(data: stripped) {
                self.log.debug("feed.parse.recoveredViaPrologStrip", ["url": sourceURL.absoluteString])
                feed = retried
            } else {
                self.log.error("feed.parse.failed", [
                    "url": sourceURL.absoluteString,
                    "error": String(reflecting: error),
                ])
                throw PodcastsError.parseFailed(url: sourceURL, reason: String(describing: error))
            }
        }

        var parsed: ParsedFeed
        switch feed {
        case let .rss(rss):
            parsed = try Self.parseRSS(rss, sourceURL: sourceURL)
        case let .atom(atom):
            parsed = try Self.parseAtom(atom, sourceURL: sourceURL)
        case .json:
            throw PodcastsError.notAFeed(url: sourceURL)
        }

        // --- podcast: namespace supplement: fill the Podcasting 2.0 tags FeedKit
        //     10.4.0 does not model (podcast:funding, podcast:chapters). Non-fatal,
        //     and the single source of these values. Remove this block if FeedKit
        //     gains official support and read the fields in parseRSS instead. ---
        let extra = PodcastNamespaceSupplement().extract(from: data)
        if parsed.fundingURL == nil { parsed.fundingURL = extra.fundingURL }
        if parsed.fundingText == nil { parsed.fundingText = extra.fundingText }
        if !extra.chaptersByGUID.isEmpty {
            parsed.episodes = parsed.episodes.map { episode in
                guard episode.chaptersURL == nil,
                      let url = extra.chaptersByGUID[episode.guid] else { return episode }
                var updated = episode
                updated.chaptersURL = url
                return updated
            }
        }
        if parsed.persons.isEmpty { parsed.persons = extra.channelPersons }
        if !extra.personsByGUID.isEmpty {
            parsed.episodes = parsed.episodes.map { episode in
                guard episode.persons.isEmpty,
                      let people = extra.personsByGUID[episode.guid] else { return episode }
                var updated = episode
                updated.persons = people
                return updated
            }
        }
        return parsed
    }

    /// Returns the feed bytes with the XML prolog (declaration, `<?xml-stylesheet?>`
    /// PIs, comments, whitespace) replaced by a clean declaration so the `<rss>` /
    /// `<feed>` root leads the data and FeedKit's 128-byte sniffer can detect it.
    /// Returns nil when no feed root is found in the first 64 KB.
    private static func feedDataWithStrippedProlog(_ data: Data) -> Data? {
        let window = data.prefix(64 * 1024)
        var rootOffset: Int?
        for marker in ["<rss", "<feed"] {
            guard let needle = marker.data(using: .utf8), let range = window.range(of: needle) else { continue }
            if rootOffset == nil || range.lowerBound < rootOffset! {
                rootOffset = range.lowerBound
            }
        }
        guard let start = rootOffset, start > 0 else { return nil }
        let declaration = Data(#"<?xml version="1.0" encoding="UTF-8"?>"#.utf8) + Data("\n".utf8)
        return declaration + data[start...]
    }

    // MARK: - RSS

    private static func parseRSS(_ rss: RSSFeed, sourceURL: URL) throws -> ParsedFeed {
        guard let channel = rss.channel,
              let title = channel.title, !title.isEmpty else {
            throw PodcastsError.notAFeed(url: sourceURL)
        }

        let author = channel.iTunes?.author
            ?? channel.managingEditor
            ?? channel.dublinCore?.creator

        let description = channel.iTunes?.summary ?? channel.description

        let artworkURLString = channel.iTunes?.image?.attributes?.href
            ?? channel.image?.url
        let artworkURL = artworkURLString.flatMap { URL(string: $0) }

        let link = channel.link.flatMap { URL(string: $0) }

        let explicit = Self.parseExplicit(channel.iTunes?.explicit)

        let categories = Self.parseITunesCategories(channel.iTunes?.categories)

        // FeedKit 10.x does not parse podcast:funding; it stays nil until a
        // supplementary parser is added (see phase21-12-podcast-features.md).
        let fundingURL: URL? = nil

        // podcast:guid is the canonical, cross-platform show identity.
        let podcastGUID = channel.podcast?.guid

        // itunes:type drives the default episode sort (serial -> oldest-first).
        let showType = Self.normalizeShowType(channel.iTunes?.type)

        let episodes: [ParsedEpisode] = (channel.items ?? []).compactMap { item in
            Self.parseRSSItem(item)
        }

        let sorted = Self.sortedNewestFirst(episodes)

        return ParsedFeed(
            title: title,
            author: author,
            description: description,
            artworkURL: artworkURL,
            link: link,
            language: channel.language,
            explicit: explicit,
            categories: categories,
            ownerName: channel.iTunes?.owner?.name,
            ownerEmail: channel.iTunes?.owner?.email,
            copyright: channel.copyright,
            fundingURL: fundingURL,
            podcastGUID: podcastGUID,
            showType: showType,
            episodes: sorted
        )
    }

    /// Normalizes `itunes:type`: trims, lowercases, and accepts only the two
    /// canonical values; anything else (including nil) becomes nil.
    private static func normalizeShowType(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return nil }
        return (value == "episodic" || value == "serial") ? value : nil
    }

    private static func parseRSSItem(_ item: RSSFeedItem) -> ParsedEpisode? {
        guard let enclosure = item.enclosure?.attributes,
              let urlString = enclosure.url,
              let audioURL = URL(string: urlString) else {
            return nil
        }

        let mimeType = enclosure.type ?? ""

        // Skip video-only enclosures.
        if mimeType.hasPrefix("video/") {
            return nil
        }

        // Require an audio MIME type or no MIME (tolerate bare-URL feeds).
        if !mimeType.isEmpty, !mimeType.hasPrefix("audio/") {
            return nil
        }

        // GUID falls back to enclosure URL when absent.
        let guid = item.guid?.text ?? urlString

        // itunes:episode is a String in 10.x; convert for the Int column.
        let episodeNumber = item.iTunes?.episode.flatMap { Int($0) }

        // Title falls back to episode number / pubDate when absent.
        let title = item.title
            ?? item.iTunes?.title
            ?? Self.fallbackTitle(episode: episodeNumber, pubDate: item.pubDate)

        let descriptionHTML = item.content?.encoded
            ?? item.iTunes?.summary
            ?? item.description

        // Episode artwork: itunes:image, else a Media RSS thumbnail.
        let artworkURLString = item.iTunes?.image?.attributes?.href
            ?? item.media?.thumbnails?.first?.attributes?.url
        let artworkURL = artworkURLString.flatMap { URL(string: $0) }

        // podcast:transcript -> the single transcript_url column (best pick).
        let transcriptURL = Self.preferredTranscript(item.podcast?.transcripts)

        return ParsedEpisode(
            guid: guid,
            title: title,
            subtitle: item.iTunes?.subtitle,
            descriptionHTML: descriptionHTML,
            audioURL: audioURL,
            audioMIME: mimeType.isEmpty ? nil : mimeType,
            audioByteLength: enclosure.length,
            duration: item.iTunes?.duration,
            publishedAt: item.pubDate,
            season: item.iTunes?.season,
            episodeNumber: episodeNumber,
            episodeType: item.iTunes?.episodeType,
            artworkURL: artworkURL,
            // FeedKit 10.x does not parse podcast:chapters (see phase21-12).
            chaptersURL: nil,
            transcriptURL: transcriptURL,
            link: item.link.flatMap { URL(string: $0) },
            explicit: Self.parseExplicit(item.iTunes?.explicit)
        )
    }

    // MARK: - Atom

    private static func parseAtom(_ atom: AtomFeed, sourceURL: URL) throws -> ParsedFeed {
        guard let title = atom.title?.text, !title.isEmpty else {
            throw PodcastsError.notAFeed(url: sourceURL)
        }

        let author = atom.authors?.first?.name

        let description = atom.subtitle?.text

        let artworkURL: URL? = atom.logo.flatMap { URL(string: $0) }

        let link = atom.links?
            .first(where: { $0.attributes?.rel == "alternate" || $0.attributes?.rel == nil })?
            .attributes?.href
            .flatMap { URL(string: $0) }

        let episodes: [ParsedEpisode] = (atom.entries ?? []).compactMap { entry in
            Self.parseAtomEntry(entry)
        }

        let sorted = Self.sortedNewestFirst(episodes)

        return ParsedFeed(
            title: title,
            author: author,
            description: description,
            artworkURL: artworkURL,
            link: link,
            language: nil,
            explicit: false,
            categories: [],
            ownerName: nil,
            ownerEmail: atom.authors?.first?.email,
            copyright: atom.rights,
            fundingURL: nil,
            podcastGUID: nil,
            episodes: sorted
        )
    }

    private static func parseAtomEntry(_ entry: AtomFeedEntry) -> ParsedEpisode? {
        // Find the enclosure link: rel="enclosure" with an audio MIME type.
        guard let enclosureLink = entry.links?.first(where: {
            $0.attributes?.rel == "enclosure"
                && ($0.attributes?.type?.hasPrefix("audio/") == true
                    || $0.attributes?.type == nil)
        }),
            let hrefString = enclosureLink.attributes?.href,
            let audioURL = URL(string: hrefString) else {
            return nil
        }

        // Skip video enclosures.
        if enclosureLink.attributes?.type?.hasPrefix("video/") == true {
            return nil
        }

        let guid = entry.id ?? hrefString
        let title = entry.title ?? Self.fallbackTitle(episode: nil, pubDate: entry.published)
        let descriptionHTML = entry.content?.text ?? entry.summary?.text

        return ParsedEpisode(
            guid: guid,
            title: title,
            subtitle: nil,
            descriptionHTML: descriptionHTML,
            audioURL: audioURL,
            audioMIME: enclosureLink.attributes?.type,
            audioByteLength: enclosureLink.attributes?.length,
            duration: nil,
            publishedAt: entry.published ?? entry.updated,
            season: nil,
            episodeNumber: nil,
            episodeType: nil,
            artworkURL: nil,
            chaptersURL: nil,
            transcriptURL: nil,
            link: entry.links?
                .first(where: { $0.attributes?.rel == "alternate" })?
                .attributes?.href
                .flatMap { URL(string: $0) },
            explicit: false
        )
    }

    // MARK: - Helpers

    private static func sortedNewestFirst(_ episodes: [ParsedEpisode]) -> [ParsedEpisode] {
        episodes.sorted { lhs, rhs in
            switch (lhs.publishedAt, rhs.publishedAt) {
            case let (a?, b?): a > b
            case (nil, _): false
            case (_, nil): true
            }
        }
    }

    private static func parseExplicit(_ value: String?) -> Bool {
        guard let v = value?.lowercased().trimmingCharacters(in: .whitespaces) else { return false }
        return v == "yes" || v == "true" || v == "explicit"
    }

    private static func parseITunesCategories(_ cats: [iTunesCategory]?) -> [String] {
        guard let cats else { return [] }
        var result: [String] = []
        for cat in cats {
            if let text = cat.attributes?.text {
                result.append(text)
            }
            if let sub = cat.subcategory?.attributes?.text {
                result.append(sub)
            }
        }
        return Array(Set(result)).sorted()
    }

    /// Pick a single transcript URL for the `transcript_url` column, preferring
    /// common readable / timed formats. The full multi-format list is a future
    /// enhancement (see phase21-12-podcast-features.md).
    private static func preferredTranscript(_ transcripts: [PodcastTranscript]?) -> URL? {
        guard let transcripts, !transcripts.isEmpty else { return nil }
        let ranked = transcripts.sorted { lhs, rhs in
            Self.transcriptRank(lhs.attributes?.type) < Self.transcriptRank(rhs.attributes?.type)
        }
        for transcript in ranked {
            if let urlString = transcript.attributes?.url, let url = URL(string: urlString) {
                return url
            }
        }
        return nil
    }

    private static func transcriptRank(_ type: String?) -> Int {
        switch type?.lowercased() {
        case "text/vtt": 0
        case "application/x-subrip", "application/srt", "text/srt": 1
        case "text/html": 2
        case "text/plain": 3
        case "application/json": 4
        default: 5
        }
    }

    private static func fallbackTitle(episode: Int?, pubDate: Date?) -> String {
        if let ep = episode { return "Episode \(ep)" }
        if let date = pubDate {
            let fmt = DateFormatter()
            fmt.dateStyle = .medium
            fmt.timeStyle = .none
            return fmt.string(from: date)
        }
        return "Untitled Episode"
    }
}
