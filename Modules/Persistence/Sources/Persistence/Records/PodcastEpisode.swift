import GRDB

/// One episode in the `podcast_episodes` table.
///
/// Content is replaced freely on every feed refresh (upserted by `EpisodeRepository`).
/// Playback state is kept separately in `podcast_episode_state` and is never touched
/// by a content refresh.
public struct PodcastEpisode: Codable, Equatable, Hashable, FetchableRecord, MutablePersistableRecord, Sendable {
    // MARK: - Table

    public static let databaseTableName = "podcast_episodes"

    // MARK: - Properties

    public var id: Int64?
    public var podcastID: Int64
    public var guid: String
    public var title: String
    public var subtitle: String?
    public var descriptionHTML: String?
    public var audioURL: String
    public var audioMIME: String?
    public var audioByteLength: Int64?
    public var duration: Double?
    public var publishedAt: Double?
    public var season: Int?
    public var episodeNumber: Int?
    public var episodeType: String?
    public var artworkURL: String?
    public var artworkPath: String?
    public var chaptersURL: String?
    public var transcriptURL: String?
    public var link: String?
    public var explicit: Bool
    public var addedAt: Double

    // MARK: - Init

    // swiftlint:disable function_default_parameter_at_end
    public init(
        id: Int64? = nil,
        podcastID: Int64,
        guid: String,
        title: String,
        subtitle: String? = nil,
        descriptionHTML: String? = nil,
        audioURL: String,
        audioMIME: String? = nil,
        audioByteLength: Int64? = nil,
        duration: Double? = nil,
        publishedAt: Double? = nil,
        season: Int? = nil,
        episodeNumber: Int? = nil,
        episodeType: String? = nil,
        artworkURL: String? = nil,
        artworkPath: String? = nil,
        chaptersURL: String? = nil,
        transcriptURL: String? = nil,
        link: String? = nil,
        explicit: Bool = false,
        addedAt: Double
    ) {
        self.id = id
        self.podcastID = podcastID
        self.guid = guid
        self.title = title
        self.subtitle = subtitle
        self.descriptionHTML = descriptionHTML
        self.audioURL = audioURL
        self.audioMIME = audioMIME
        self.audioByteLength = audioByteLength
        self.duration = duration
        self.publishedAt = publishedAt
        self.season = season
        self.episodeNumber = episodeNumber
        self.episodeType = episodeType
        self.artworkURL = artworkURL
        self.artworkPath = artworkPath
        self.chaptersURL = chaptersURL
        self.transcriptURL = transcriptURL
        self.link = link
        self.explicit = explicit
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
        case podcastID = "podcast_id"
        case guid
        case title
        case subtitle
        case descriptionHTML = "description_html"
        case audioURL = "audio_url"
        case audioMIME = "audio_mime"
        case audioByteLength = "audio_byte_length"
        case duration
        case publishedAt = "published_at"
        case season
        case episodeNumber = "episode_number"
        case episodeType = "episode_type"
        case artworkURL = "artwork_url"
        case artworkPath = "artwork_path"
        case chaptersURL = "chapters_url"
        case transcriptURL = "transcript_url"
        case link
        case explicit
        case addedAt = "added_at"
    }
}
