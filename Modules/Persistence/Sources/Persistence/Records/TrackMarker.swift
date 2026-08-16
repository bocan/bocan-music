import Foundation
import GRDB

/// A CUE point inside a track (ADR-087): the chapters model. Markers change
/// how the player bar looks and navigates for the track they belong to; they
/// never split the track. Rows cascade away with their track.
public struct TrackMarker: Codable, Equatable, Hashable, Identifiable, FetchableRecord,
    MutablePersistableRecord, Sendable {
    // MARK: - Table

    public static let databaseTableName = "track_markers"

    // MARK: - Properties

    /// Auto-incremented row identifier; `nil` before first insertion.
    public var id: Int64?
    /// Owning track.
    public var trackID: Int64
    /// Marker position from the start of the track, in milliseconds
    /// (converted from the cue's 75 fps `INDEX 01`).
    public var positionMs: Int64
    /// The cue TRACK's TITLE, verbatim.
    public var title: String?
    /// The cue TRACK's PERFORMER (falling back to the sheet's), verbatim.
    public var performer: String?

    // MARK: - Coding

    enum CodingKeys: String, CodingKey {
        case id
        case trackID = "track_id"
        case positionMs = "position_ms"
        case title
        case performer
    }

    public init(
        trackID: Int64,
        positionMs: Int64,
        title: String? = nil,
        performer: String? = nil,
        id: Int64? = nil
    ) {
        self.id = id
        self.trackID = trackID
        self.positionMs = positionMs
        self.title = title
        self.performer = performer
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        self.id = inserted.rowID
    }
}

// MARK: - TrackMarkerRepository

/// Typed access to `track_markers`.
public struct TrackMarkerRepository: Sendable {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    /// Markers for a track, ordered by position.
    public func markers(forTrack trackID: Int64) async throws -> [TrackMarker] {
        try await self.database.read { db in
            try TrackMarker
                .filter(Column("track_id") == trackID)
                .order(Column("position_ms"))
                .fetchAll(db)
        }
    }

    /// Replaces a track's markers wholesale, so re-importing an edited cue
    /// updates in place. One write transaction.
    public func replaceMarkers(forTrack trackID: Int64, with markers: [TrackMarker]) async throws {
        try await self.database.write { db in
            try TrackMarker.filter(Column("track_id") == trackID).deleteAll(db)
            for var marker in markers {
                marker.trackID = trackID
                try marker.insert(db)
            }
        }
    }
}
