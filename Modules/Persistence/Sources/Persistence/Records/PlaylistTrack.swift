import GRDB

/// A membership row linking a track to a playlist.
///
/// The composite primary key is `(playlist_id, position)`.
/// Deleting a playlist cascades to all its `PlaylistTrack` rows.
public struct PlaylistTrack: Codable, FetchableRecord, PersistableRecord, Sendable {
    // MARK: - Table

    /// The database table name.
    public static let databaseTableName = "playlist_tracks"

    // MARK: - Properties

    /// The owning playlist identifier.
    public var playlistID: Int64

    /// The track identifier.
    public var trackID: Int64

    /// 1-based position within the playlist.
    public var position: Int

    // MARK: - Init

    /// Memberwise initialiser.
    public init(playlistID: Int64, trackID: Int64, position: Int) {
        self.playlistID = playlistID
        self.trackID = trackID
        self.position = position
    }

    // MARK: - CodingKeys

    private enum CodingKeys: String, CodingKey {
        case playlistID = "playlist_id"
        case trackID = "track_id"
        case position
    }
}
