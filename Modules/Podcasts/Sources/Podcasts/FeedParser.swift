import Foundation

// third-party boundary: FeedKit 9.x classes are not Sendable; all FeedKit
// types are created and consumed synchronously within parse(_:sourceURL:) and
// never cross an actor boundary.
@preconcurrency import FeedKit
import Observability

/// Wraps FeedKit to parse RSS 2.0 and Atom feeds into the module's
/// `ParsedFeed` / `ParsedEpisode` value types.
///
/// No FeedKit type escapes this struct's API surface.
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
        let kitParser = FeedKit.FeedParser(data: data)
        let result = kitParser.parse()

        switch result {
        case let .failure(err):
            throw PodcastsError.parseFailed(url: sourceURL, reason: err.localizedDescription)
        case let .success(feed):
            switch feed {
            case let .rss(rss):
                return try Self.parseRSS(rss, sourceURL: sourceURL)
            case let .atom(atom):
                return try Self.parseAtom(atom, sourceURL: sourceURL)
            case .json:
                throw PodcastsError.notAFeed(url: sourceURL)
            }
        }
    }

    // MARK: - RSS

    private static func parseRSS(_ rss: RSSFeed, sourceURL: URL) throws -> ParsedFeed {
        guard let title = rss.title, !title.isEmpty else {
            throw PodcastsError.notAFeed(url: sourceURL)
        }

        let author = rss.iTunes?.iTunesAuthor
            ?? rss.managingEditor
            ?? rss.dublinCore?.dcCreator

        let description = rss.iTunes?.iTunesSummary ?? rss.description

        let artworkURLString = rss.iTunes?.iTunesImage?.attributes?.href
            ?? rss.image?.url
        let artworkURL = artworkURLString.flatMap { URL(string: $0) }

        let link = rss.link.flatMap { URL(string: $0) }

        let explicit = Self.parseExplicit(rss.iTunes?.iTunesExplicit)

        let categories = Self.parseITunesCategories(rss.iTunes?.iTunesCategories)

        let fundingURL: URL? = nil

        let episodes: [ParsedEpisode] = (rss.items ?? []).compactMap { item in
            Self.parseRSSItem(item)
        }

        let sorted = episodes.sorted { lhs, rhs in
            switch (lhs.publishedAt, rhs.publishedAt) {
            case let (a?, b?): a > b
            case (nil, _): false
            case (_, nil): true
            }
        }

        return ParsedFeed(
            title: title,
            author: author,
            description: description,
            artworkURL: artworkURL,
            link: link,
            language: rss.language,
            explicit: explicit,
            categories: categories,
            ownerName: rss.iTunes?.iTunesOwner?.name,
            ownerEmail: rss.iTunes?.iTunesOwner?.email,
            copyright: rss.copyright,
            fundingURL: fundingURL,
            episodes: sorted
        )
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
        let guid = item.guid?.value ?? urlString

        // Title falls back to episode number / pubDate when absent.
        let title = item.title
            ?? item.iTunes?.iTunesTitle
            ?? Self.fallbackTitle(episode: item.iTunes?.iTunesEpisode, pubDate: item.pubDate)

        let descriptionHTML = item.content?.contentEncoded
            ?? item.iTunes?.iTunesSummary
            ?? item.description

        let artworkURLString = item.iTunes?.iTunesImage?.attributes?.href
        let artworkURL = artworkURLString.flatMap { URL(string: $0) }

        let episodeNumber = item.iTunes?.iTunesEpisode

        return ParsedEpisode(
            guid: guid,
            title: title,
            subtitle: item.iTunes?.iTunesSubtitle,
            descriptionHTML: descriptionHTML,
            audioURL: audioURL,
            audioMIME: mimeType.isEmpty ? nil : mimeType,
            audioByteLength: enclosure.length,
            duration: item.iTunes?.iTunesDuration,
            publishedAt: item.pubDate,
            season: item.iTunes?.iTunesSeason,
            episodeNumber: episodeNumber,
            episodeType: item.iTunes?.iTunesEpisodeType,
            artworkURL: artworkURL,
            chaptersURL: nil,
            transcriptURL: nil,
            link: item.link.flatMap { URL(string: $0) },
            explicit: Self.parseExplicit(item.iTunes?.iTunesExplicit)
        )
    }

    // MARK: - Atom

    private static func parseAtom(_ atom: AtomFeed, sourceURL: URL) throws -> ParsedFeed {
        guard let title = atom.title, !title.isEmpty else {
            throw PodcastsError.notAFeed(url: sourceURL)
        }

        let author = atom.authors?.first?.name

        let description = atom.subtitle?.value

        let artworkURL: URL? = atom.logo.flatMap { URL(string: $0) }

        let link = atom.links?
            .first(where: { $0.attributes?.rel == "alternate" || $0.attributes?.rel == nil })?
            .attributes?.href
            .flatMap { URL(string: $0) }

        let episodes: [ParsedEpisode] = (atom.entries ?? []).compactMap { entry in
            Self.parseAtomEntry(entry)
        }

        let sorted = episodes.sorted { lhs, rhs in
            switch (lhs.publishedAt, rhs.publishedAt) {
            case let (a?, b?): a > b
            case (nil, _): false
            case (_, nil): true
            }
        }

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
        let descriptionHTML = entry.content?.value ?? entry.summary?.value

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

    private static func parseExplicit(_ value: String?) -> Bool {
        guard let v = value?.lowercased().trimmingCharacters(in: .whitespaces) else { return false }
        return v == "yes" || v == "true" || v == "explicit"
    }

    private static func parseITunesCategories(_ cats: [ITunesCategory]?) -> [String] {
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
