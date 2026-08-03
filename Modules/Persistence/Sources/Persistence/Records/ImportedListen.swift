import Foundation
import GRDB

/// One backfilled play from an external listening-history export (phase 25).
///
/// `trackID` is nullable by design: an export usually contains years of plays
/// for music the library no longer (or never) held. Unlinked rows still feed
/// time-based analytics, and the re-match pass links them up when the library
/// grows. `playedAt` is Unix epoch seconds (Last.fm's `uts`, always UTC).
public struct ImportedListen: Codable, Equatable, FetchableRecord, MutablePersistableRecord, Sendable {
    /// The database table name.
    public static let databaseTableName = "imported_listens"

    /// Auto-incremented row identifier; `nil` before first insertion.
    public var id: Int64?

    /// Where the row came from (`"lastfm"` for now).
    public var source: String

    /// Unix timestamp of the play (UTC).
    public var playedAt: Int64

    /// Artist name exactly as exported.
    public var artist: String

    /// Track title exactly as exported.
    public var title: String

    /// Album title as exported, when present.
    public var album: String?

    /// MusicBrainz track id from the export, when present; the strongest
    /// match key when the library carries MusicBrainz tags.
    public var trackMbid: String?

    /// Matched library track, `nil` while unmatched.
    public var trackID: Int64?

    public init(
        playedAt: Int64,
        artist: String,
        title: String,
        album: String? = nil,
        trackMbid: String? = nil,
        trackID: Int64? = nil,
        id: Int64? = nil,
        source: String = "lastfm"
    ) {
        self.id = id
        self.source = source
        self.playedAt = playedAt
        self.artist = artist
        self.title = title
        self.album = album
        self.trackMbid = trackMbid
        self.trackID = trackID
    }

    /// Captures the auto-incremented row ID after insertion.
    public mutating func didInsert(_ inserted: InsertionSuccess) {
        self.id = inserted.rowID
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case source
        case playedAt = "played_at"
        case artist
        case title
        case album
        case trackMbid = "track_mbid"
        case trackID = "track_id"
    }
}
