import Foundation
import GRDB

/// One recorded play, joined to the song it was a play of (ADR-094).
///
/// Read-only: `PlayHistoryRecorder` writes `play_history`, and this row is
/// what the History page reads back. Identity is the play, not the song, so
/// a song played three times is three rows with three ids; that is the
/// reason the page keys its table by `playID` rather than reusing the
/// songs table, which deduplicates by track.
///
/// The song columns are optional because the read is a `LEFT JOIN`. Through
/// the app they are never nil: `play_history.track_id` cascades on delete,
/// so a removed song takes its plays with it. The join is defence for a
/// database opened with foreign keys off.
public struct PlayHistoryRow: Codable, Equatable, Hashable, Sendable, FetchableRecord, Identifiable {
    /// `play_history.id`.
    public let playID: Int64
    /// The song, as recorded. Still set when the song row is gone.
    public let trackID: Int64
    /// Unix epoch seconds, from the recorder's clock at the threshold.
    public let playedAt: Int64
    /// Seconds of the song that were played when the threshold was reached.
    public let durationPlayed: Double
    /// The song's title, or nil when its row is missing.
    public let title: String?
    public let artistName: String?
    public let albumName: String?
    /// For Go to Artist and Go to Album; nil when the song has none, or is gone.
    public let artistID: Int64?
    public let albumID: Int64?
    /// The song's full length in seconds, for "played for" against it.
    public let trackDuration: Double?
    /// The song's file, as a `file://` URL string, so a reveal in Finder
    /// needs no second read. Nil when the song row is gone.
    public let fileURL: String?
    /// `true` when the song's file is not where the library recorded it
    /// (`tracks.disabled`, set by the scanner), or the song row is gone. The
    /// play still lists, greyed, with the file actions left out of its menu.
    public let isMissing: Bool

    public var id: Int64 {
        self.playID
    }

    public init(
        playID: Int64,
        trackID: Int64,
        playedAt: Int64,
        durationPlayed: Double,
        title: String? = nil,
        artistName: String? = nil,
        albumName: String? = nil,
        artistID: Int64? = nil,
        albumID: Int64? = nil,
        trackDuration: Double? = nil,
        fileURL: String? = nil,
        isMissing: Bool = false
    ) {
        self.playID = playID
        self.trackID = trackID
        self.playedAt = playedAt
        self.durationPlayed = durationPlayed
        self.title = title
        self.artistName = artistName
        self.albumName = albumName
        self.artistID = artistID
        self.albumID = albumID
        self.trackDuration = trackDuration
        self.fileURL = fileURL
        self.isMissing = isMissing
    }
}
