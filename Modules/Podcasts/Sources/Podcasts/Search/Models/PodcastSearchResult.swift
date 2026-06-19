import Foundation

/// One deduplicated, merged search hit from the dual-index search (phase 21-3).
///
/// The ``id`` property is the ``canonicalFeedKey`` -- a scheme-less, www-less,
/// trailing-slash-less string derived from the feed URL. Two results with the same
/// key represent the same podcast regardless of which index returned them.
public struct PodcastSearchResult: Sendable, Hashable, Identifiable {
    /// Deduplication/identity key. Use ``FeedURL.canonicalKey(_:)`` to compute.
    public var canonicalFeedKey: String
    public var id: String {
        self.canonicalFeedKey
    }

    /// The feed URL (https preferred over http when both sources knew it).
    public var feedURL: URL
    public var title: String
    public var author: String?
    public var artworkURL: URL?
    public var description: String?
    public var episodeCount: Int?
    public var lastPublishedAt: Date?
    public var categories: [String]
    /// Which source(s) this result came from. May contain both.
    public var sources: Set<PodcastSearchSource>
    public var podcastIndexID: Int?
    public var itunesCollectionID: Int?

    public init(
        canonicalFeedKey: String,
        feedURL: URL,
        title: String,
        author: String? = nil,
        artworkURL: URL? = nil,
        description: String? = nil,
        episodeCount: Int? = nil,
        lastPublishedAt: Date? = nil,
        categories: [String] = [],
        sources: Set<PodcastSearchSource> = [],
        podcastIndexID: Int? = nil,
        itunesCollectionID: Int? = nil
    ) {
        self.canonicalFeedKey = canonicalFeedKey
        self.feedURL = feedURL
        self.title = title
        self.author = author
        self.artworkURL = artworkURL
        self.description = description
        self.episodeCount = episodeCount
        self.lastPublishedAt = lastPublishedAt
        self.categories = categories
        self.sources = sources
        self.podcastIndexID = podcastIndexID
        self.itunesCollectionID = itunesCollectionID
    }
}
