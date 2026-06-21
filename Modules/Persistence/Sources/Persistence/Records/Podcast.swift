import Foundation
import GRDB

/// A subscribed podcast show, stored in the `podcasts` table.
///
/// Content fields (title, author, artwork, etc.) come from the feed and may be updated
/// on every refresh. Identity / user-owned fields (`id`, `addedAt`, `subscribed`,
/// `autoDownload`, `sortIndex`, `playbackSpeed`, `episodeSort`, `retentionLimit`) are
/// preserved across refreshes by `PodcastRepository.upsertByFeedURL`. `showType` is
/// feed-derived and refreshes from the parse like the other content fields.
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
    /// Per-show playback rate override (user-owned); nil = use the app default.
    public var playbackSpeed: Double?
    /// Per-show episode sort override (user-owned): "newest" | "oldest"; nil = derive from `showType`.
    public var episodeSort: String?
    /// Per-show retention: keep newest N content rows (user-owned); nil = keep all.
    public var retentionLimit: Int?
    /// Feed-derived `itunes:type`: "episodic" | "serial". Refreshes from the parse.
    public var showType: String?
    /// Show-level Podcasting 2.0 `podcast:person` credits, JSON-encoded. Feed content.
    public var personsJSON: Data?
    public var addedAt: Double

    /// Show-level `podcast:person` credits, decoded from / encoded to `personsJSON`.
    public var persons: [PodcastPerson] {
        get { PodcastPerson.decodeList(self.personsJSON) }
        set { self.personsJSON = PodcastPerson.encodeList(newValue) }
    }

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
        playbackSpeed: Double? = nil,
        episodeSort: String? = nil,
        retentionLimit: Int? = nil,
        showType: String? = nil,
        personsJSON: Data? = nil,
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
        self.playbackSpeed = playbackSpeed
        self.episodeSort = episodeSort
        self.retentionLimit = retentionLimit
        self.showType = showType
        self.personsJSON = personsJSON
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
        case playbackSpeed = "playback_speed"
        case episodeSort = "episode_sort"
        case retentionLimit = "retention_limit"
        case showType = "show_type"
        case personsJSON = "persons_json"
        case addedAt = "added_at"
    }
}
