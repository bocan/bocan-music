import GRDB

/// Per-episode playback and download state, stored in `podcast_episode_state`.
///
/// The composite primary key is `(podcast_id, guid)`, matching the episode's identity.
/// This table is keyed to `podcasts.id` (not `podcast_episodes.id`), so rows survive
/// a content refresh that replaces or temporarily removes the matching episode row.
///
/// Conforms to `PersistableRecord` (not `MutablePersistableRecord`) because there is
/// no auto-increment primary key and `didInsert` is not needed.
public struct PodcastEpisodeState: Codable, Equatable, Hashable, FetchableRecord, PersistableRecord, Sendable {
    // MARK: - Table

    public static let databaseTableName = "podcast_episode_state"

    // MARK: - Properties

    public var podcastID: Int64
    public var guid: String
    public var playPosition: Double
    public var playState: EpisodePlayState
    public var lastPlayedAt: Double?
    public var completedAt: Double?
    public var downloadState: EpisodeDownloadState
    public var downloadPath: String?
    public var downloadBytes: Int64?

    // MARK: - Init

    public init(
        podcastID: Int64,
        guid: String,
        playPosition: Double = 0,
        playState: EpisodePlayState = .unplayed,
        lastPlayedAt: Double? = nil,
        completedAt: Double? = nil,
        downloadState: EpisodeDownloadState = .none,
        downloadPath: String? = nil,
        downloadBytes: Int64? = nil
    ) {
        self.podcastID = podcastID
        self.guid = guid
        self.playPosition = playPosition
        self.playState = playState
        self.lastPlayedAt = lastPlayedAt
        self.completedAt = completedAt
        self.downloadState = downloadState
        self.downloadPath = downloadPath
        self.downloadBytes = downloadBytes
    }

    // MARK: - CodingKeys

    private enum CodingKeys: String, CodingKey {
        case podcastID = "podcast_id"
        case guid
        case playPosition = "play_position"
        case playState = "play_state"
        case lastPlayedAt = "last_played_at"
        case completedAt = "completed_at"
        case downloadState = "download_state"
        case downloadPath = "download_path"
        case downloadBytes = "download_bytes"
    }
}
