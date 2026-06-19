import Foundation
import Observability
import Persistence
import Podcasts
import UI

// MARK: - AppPodcastSearch

/// Concrete `PodcastSearchProviding` that bridges the UI seam to the
/// `Podcasts` module's search service, feed fetcher, and parser.
///
/// Declared in App so neither UI nor Podcasts needs to import the other.
struct AppPodcastSearch: PodcastSearchProviding {
    let searchService: PodcastSearchService
    let fetcher: FeedFetcher
    let parser: FeedParser
    let podcastRepo: PodcastRepository

    // MARK: - PodcastSearchProviding

    func search(term: String) async throws -> [UIPodcastSearchResult] {
        let results = try await self.searchService.search(term: term)
        return results.map(Self.map)
    }

    func detail(feedURL: URL, hint: UIPodcastSearchResult?) async throws -> PodcastDetail {
        // Optionally enrich channel metadata from the index (best-effort; never throws).
        var enriched: PodcastSearchResult?
        if let hint {
            enriched = await self.searchService.detail(for: Self.unmap(hint))
        }

        // Fetch + parse the live feed (source of truth for episode list).
        let fetchResult = try await self.fetcher.fetch(feedURL, etag: nil, lastModified: nil)
        guard let data = fetchResult.data else {
            throw PodcastsError.network(underlying: URLError(.zeroByteResource))
        }
        let parsed = try self.parser.parse(data, sourceURL: feedURL)

        // Check subscription status.
        let storedURL = FeedURL.normalizedStorageURL(feedURL)?.absoluteString
            ?? feedURL.absoluteString
        let existing: Podcast?
        do {
            existing = try await self.podcastRepo.fetchByFeedURL(storedURL)
        } catch {
            AppLogger.make(.app).warning(
                "podcastSearch.fetchByFeedURL.failed",
                ["error": String(reflecting: error)]
            )
            existing = nil
        }

        // Merge: prefer enriched index data over the live channel metadata.
        let title = enriched?.title ?? parsed.title
        let author = enriched?.author ?? parsed.author
        let description = enriched?.description ?? parsed.description
        let artworkURL = enriched?.artworkURL ?? parsed.artworkURL
        let link = parsed.link
        let categories = Self.resolveCategories(enriched: enriched, parsed: parsed)
        let sources = Self.mergeSources(enriched: enriched)

        let episodes = Array(parsed.episodes.prefix(25).map { ep in
            PodcastDetailEpisode(
                guid: ep.guid,
                title: ep.title,
                publishedAt: ep.publishedAt,
                duration: ep.duration,
                descriptionHTML: ep.descriptionHTML
            )
        })

        return PodcastDetail(
            feedURL: enriched?.feedURL ?? feedURL,
            title: title,
            author: author,
            description: description,
            artworkURL: artworkURL,
            link: link,
            categories: categories,
            sources: sources,
            episodePreview: episodes,
            alreadySubscribed: existing != nil,
            podcastID: existing.flatMap(\.id)
        )
    }

    // MARK: - Mapping helpers

    private static func map(_ r: PodcastSearchResult) -> UIPodcastSearchResult {
        UIPodcastSearchResult(
            canonicalFeedKey: r.canonicalFeedKey,
            feedURL: r.feedURL,
            title: r.title,
            author: r.author,
            artworkURL: r.artworkURL,
            description: r.description,
            episodeCount: r.episodeCount,
            lastPublishedAt: r.lastPublishedAt,
            categories: r.categories,
            sources: Set(r.sources.map(self.mapSource)),
            podcastIndexID: r.podcastIndexID,
            itunesCollectionID: r.itunesCollectionID
        )
    }

    private static func unmap(_ r: UIPodcastSearchResult) -> PodcastSearchResult {
        PodcastSearchResult(
            canonicalFeedKey: r.canonicalFeedKey,
            feedURL: r.feedURL,
            title: r.title,
            author: r.author,
            artworkURL: r.artworkURL,
            description: r.description,
            episodeCount: r.episodeCount,
            lastPublishedAt: r.lastPublishedAt,
            categories: r.categories,
            sources: Set(r.sources.map(self.unmapSource)),
            podcastIndexID: r.podcastIndexID,
            itunesCollectionID: r.itunesCollectionID
        )
    }

    private static func mapSource(_ s: PodcastSearchSource) -> UIPodcastSearchSource {
        switch s {
        case .podcastIndex:
            .podcastIndex

        case .itunes:
            .itunes
        }
    }

    private static func unmapSource(_ s: UIPodcastSearchSource) -> PodcastSearchSource {
        switch s {
        case .podcastIndex:
            .podcastIndex

        case .itunes:
            .itunes
        }
    }

    private static func resolveCategories(
        enriched: PodcastSearchResult?,
        parsed: ParsedFeed
    ) -> [String] {
        if let cats = enriched?.categories, !cats.isEmpty { return cats }
        return parsed.categories
    }

    private static func mergeSources(enriched: PodcastSearchResult?) -> Set<UIPodcastSearchSource> {
        guard let enriched else { return [] }
        return Set(enriched.sources.map(Self.mapSource))
    }
}
