import Foundation
import GRDB

/// One listen of a song in the library, joined to that song (ADR-094).
///
/// Two tables feed it. `play_history` holds what Bòcan recorded itself;
/// `imported_listens` holds a Last.fm export, of which only the rows matched
/// to a library song are listed here (slice 3, option C), so every row is a
/// real song with the full menu. Identity is the source plus that table's
/// row id, not the song, so a song played three times is three rows; that is
/// the reason the page keys its table by ``id`` rather than reusing the
/// songs table, which deduplicates by track.
///
/// Read-only. `play_history.duration_played` is deliberately not carried:
/// it is the elapsed time at the moment the recording rule fired (50% or
/// four minutes), never updated afterwards, so it says how long the rule
/// took to trigger and nothing about how much of the song was heard.
///
/// The song columns are optional because the local read is a `LEFT JOIN`.
/// Through the app they are never nil: `play_history.track_id` cascades on
/// delete, so a removed song takes its local plays with it. The join is
/// defence for a database opened with foreign keys off. An imported row's
/// link is `ON DELETE SET NULL` instead, so removing a song drops its
/// imported listens out of this list without deleting them.
public struct PlayHistoryRow: Codable, Equatable, Hashable, Sendable, FetchableRecord, Identifiable {
    /// Which table the row came from.
    public enum Source: String, Codable, Hashable, Sendable {
        /// Recorded by Bòcan's own player.
        case local
        /// A Last.fm listen, matched to a library song.
        case imported
    }

    /// Row identity across the two tables.
    public struct Key: Hashable, Sendable {
        public let source: Source
        public let rowID: Int64

        public init(source: Source, rowID: Int64) {
            self.source = source
            self.rowID = rowID
        }
    }

    public let source: Source
    /// `play_history.id` or `imported_listens.id`, by `source`.
    public let rowID: Int64
    /// Unix epoch seconds. Local: the recorder's clock at the threshold.
    /// Imported: Last.fm's timestamp, which is the start of the song.
    public let playedAt: Int64
    /// The song. Still set on a local row when the song row is gone.
    public let trackID: Int64
    /// The song's title, or nil when its row is missing.
    public let title: String?
    public let artistName: String?
    public let albumName: String?
    /// For Go to Artist and Go to Album; nil when the song has none, or is gone.
    public let artistID: Int64?
    public let albumID: Int64?
    /// The song's file, as a `file://` URL string, so a reveal in Finder
    /// needs no second read. Nil when the song row is gone.
    public let fileURL: String?
    /// `true` when the song's file is not where the library recorded it
    /// (`tracks.disabled`, set by the scanner), or the song row is gone. The
    /// play still lists, greyed, with the file actions left out of its menu.
    public let isMissing: Bool

    public var id: Key {
        Key(source: self.source, rowID: self.rowID)
    }

    public init(
        source: Source,
        rowID: Int64,
        playedAt: Int64,
        trackID: Int64,
        title: String? = nil,
        artistName: String? = nil,
        albumName: String? = nil,
        artistID: Int64? = nil,
        albumID: Int64? = nil,
        fileURL: String? = nil,
        isMissing: Bool = false
    ) {
        self.source = source
        self.rowID = rowID
        self.playedAt = playedAt
        self.trackID = trackID
        self.title = title
        self.artistName = artistName
        self.albumName = albumName
        self.artistID = artistID
        self.albumID = albumID
        self.fileURL = fileURL
        self.isMissing = isMissing
    }
}
