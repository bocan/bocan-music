import Foundation

/// Normalized output of feed parsing, source-agnostic across RSS and Atom.
///
/// This is a pure value type that never references FeedKit types; callers
/// never need to import FeedKit directly.
public struct ParsedFeed: Sendable {
    public var title: String
    public var author: String?
    public var description: String?
    public var artworkURL: URL?
    public var link: URL?
    public var language: String?
    public var explicit: Bool
    public var categories: [String]
    public var ownerName: String?
    public var ownerEmail: String?
    public var copyright: String?
    public var fundingURL: URL?
    /// Podcasting 2.0 `podcast:funding` display label (the element text). Feed
    /// content, rendered verbatim, never localized. Nil unless the tag is present.
    public var fundingText: String?
    /// Podcasting 2.0 `podcast:guid`: a stable, cross-platform show identity.
    public var podcastGUID: String?
    /// `itunes:type`: "episodic" | "serial" (normalized). Nil when absent/unrecognized
    /// or for Atom feeds. Drives the default episode sort.
    public var showType: String?
    public var episodes: [ParsedEpisode]

    public init(
        title: String,
        author: String? = nil,
        description: String? = nil,
        artworkURL: URL? = nil,
        link: URL? = nil,
        language: String? = nil,
        explicit: Bool = false,
        categories: [String] = [],
        ownerName: String? = nil,
        ownerEmail: String? = nil,
        copyright: String? = nil,
        fundingURL: URL? = nil,
        fundingText: String? = nil,
        podcastGUID: String? = nil,
        showType: String? = nil,
        episodes: [ParsedEpisode] = []
    ) {
        self.title = title
        self.author = author
        self.description = description
        self.artworkURL = artworkURL
        self.link = link
        self.language = language
        self.explicit = explicit
        self.categories = categories
        self.ownerName = ownerName
        self.ownerEmail = ownerEmail
        self.copyright = copyright
        self.fundingURL = fundingURL
        self.fundingText = fundingText
        self.podcastGUID = podcastGUID
        self.showType = showType
        self.episodes = episodes
    }
}
