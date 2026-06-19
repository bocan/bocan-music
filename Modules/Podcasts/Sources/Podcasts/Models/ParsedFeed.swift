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
        self.episodes = episodes
    }
}
