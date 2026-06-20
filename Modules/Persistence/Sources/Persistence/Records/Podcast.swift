import Foundation
import GRDB

/// A subscribed podcast show, stored in the `podcasts` table.
///
/// Content fields (title, author, artwork, etc.) come from the feed and may be updated
/// on every refresh. Identity fields (`id`, `addedAt`, `subscribed`, `autoDownload`,
/// `sortIndex`) are owned by the user and are preserved across refreshes by
/// `PodcastRepository.upsertByFeedURL`.
public struct Podcast: Codable, Equatable, Hashable, FetchableRecord, MutablePersistableRecord, Sendable {
    // MARK: - Table

    public static let databaseTableName = "podcasts"

    // MARK: - Properties

    public var id: Int64?
    public var feedURL: String
    public var title: String
    public var author: String?
    public var description: String?
    public var artworkURL: String?
    public var artworkPath: String?
    public var link: String?
    public var language: String?
    public var explicit: Bool
    public var categoriesJSON: Data?
    public var ownerName: String?
    public var ownerEmail: String?
    public var copyright: String?
    public var fundingURL: String?
    /// Podcasting 2.0 `podcast:funding` display label (feed content, rendered verbatim).
    public var fundingText: String?
    public var itunesCollectionID: Int64?
    public var podcastIndexID: Int64?
    /// Podcasting 2.0 `podcast:guid`: a stable, cross-platform show identity.
    /// Nil until a feed exposes the tag; not enforced unique (feeds may share or omit it).
    public var podcastGUID: String?
    public var httpETag: String?
    public var httpLastModified: String?
    public var lastRefreshedAt: Double?
    public var lastRefreshError: String?
    public var subscribed: Bool
    public var autoDownload: Bool
    public var sortIndex: Int
    public var addedAt: Double

    // MARK: - Init

    // swiftlint:disable function_default_parameter_at_end
    public init(
        id: Int64? = nil,
        feedURL: String,
        title: String,
        author: String? = nil,
        description: String? = nil,
        artworkURL: String? = nil,
        artworkPath: String? = nil,
        link: String? = nil,
        language: String? = nil,
        explicit: Bool = false,
        categoriesJSON: Data? = nil,
        ownerName: String? = nil,
        ownerEmail: String? = nil,
        copyright: String? = nil,
        fundingURL: String? = nil,
        fundingText: String? = nil,
        itunesCollectionID: Int64? = nil,
        podcastIndexID: Int64? = nil,
        podcastGUID: String? = nil,
        httpETag: String? = nil,
        httpLastModified: String? = nil,
        lastRefreshedAt: Double? = nil,
        lastRefreshError: String? = nil,
        subscribed: Bool = true,
        autoDownload: Bool = false,
        sortIndex: Int = 0,
        addedAt: Double
    ) {
        self.id = id
        self.feedURL = feedURL
        self.title = title
        self.author = author
        self.description = description
        self.artworkURL = artworkURL
        self.artworkPath = artworkPath
        self.link = link
        self.language = language
        self.explicit = explicit
        self.categoriesJSON = categoriesJSON
        self.ownerName = ownerName
        self.ownerEmail = ownerEmail
        self.copyright = copyright
        self.fundingURL = fundingURL
        self.fundingText = fundingText
        self.itunesCollectionID = itunesCollectionID
        self.podcastIndexID = podcastIndexID
        self.podcastGUID = podcastGUID
        self.httpETag = httpETag
        self.httpLastModified = httpLastModified
        self.lastRefreshedAt = lastRefreshedAt
        self.lastRefreshError = lastRefreshError
        self.subscribed = subscribed
        self.autoDownload = autoDownload
        self.sortIndex = sortIndex
        self.addedAt = addedAt
    }

    // swiftlint:enable function_default_parameter_at_end

    // MARK: - GRDB

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        self.id = inserted.rowID
    }

    // MARK: - CodingKeys

    private enum CodingKeys: String, CodingKey {
        case id
        case feedURL = "feed_url"
        case title
        case author
        case description
        case artworkURL = "artwork_url"
        case artworkPath = "artwork_path"
        case link
        case language
        case explicit
        case categoriesJSON = "categories_json"
        case ownerName = "owner_name"
        case ownerEmail = "owner_email"
        case copyright
        case fundingURL = "funding_url"
        case fundingText = "funding_text"
        case itunesCollectionID = "itunes_collection_id"
        case podcastIndexID = "podcast_index_id"
        case podcastGUID = "podcast_guid"
        case httpETag = "http_etag"
        case httpLastModified = "http_last_modified"
        case lastRefreshedAt = "last_refreshed_at"
        case lastRefreshError = "last_refresh_error"
        case subscribed
        case autoDownload = "auto_download"
        case sortIndex = "sort_index"
        case addedAt = "added_at"
    }
}
