import Foundation
import Persistence

// MARK: - TrackRow

/// Decorated row backing the Songs table.
///
/// Holds a reference to the underlying `Track` plus every value used by
/// a sortable `TableColumn` pre-resolved to a non-optional stored
/// property.  This lets SwiftUI's `Table(sortOrder:)` drive ordering
/// directly via `KeyPathComparator<TrackRow>` — no dictionary lookups,
/// no view-model round-trip, no feedback loops.
///
/// Missing tag values collapse to sensible defaults (`""` / `0`) so the
/// `<` operator gives a deterministic total ordering without the
/// `Optional` comparison dance.  Missing strings cluster at the top in
/// ascending order, bottom in descending — the common convention in
/// music apps.
public struct TrackRow: Identifiable, Hashable, Sendable {
    // MARK: - Stored properties

    public let track: Track
    public let title: String
    public let artistName: String
    public let albumName: String
    public let genre: String
    public let year: Int
    public let yearText: String
    public let duration: Double
    public let playCount: Int
    public let rating: Int
    public let addedAt: Int64
    public let trackNumber: Int
    public let trackTotal: Int
    public let databaseID: Int64
    public let fileFormat: String
    public let bitrate: Int
    public let sampleRate: Int
    public let excludedFromShuffle: Bool

    // MARK: - Identifiable

    /// Matches `Track.ID` (Int64?) so selection bindings remain type-compatible.
    public var id: Track.ID {
        self.track.id
    }

    // MARK: - Init

    public init(track: Track, artistName: String?, albumName: String?) {
        self.track = track
        self.title = track.title ?? ""
        self.artistName = artistName ?? ""
        self.albumName = albumName ?? ""
        self.genre = track.genre ?? ""
        self.year = track.year ?? 0
        // Prefer the raw tag string if present; otherwise fall back to the
        // numeric year (imported from files scanned before M005).
        if let text = track.yearText?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
            self.yearText = text
        } else if let y = track.year {
            self.yearText = String(y)
        } else {
            self.yearText = ""
        }
        self.duration = track.duration
        self.playCount = track.playCount
        self.rating = track.rating
        self.addedAt = track.addedAt
        self.trackNumber = track.trackNumber ?? 0
        self.trackTotal = track.trackTotal ?? 0
        self.databaseID = track.id ?? 0
        self.fileFormat = track.fileFormat.uppercased()
        self.bitrate = track.bitrate ?? 0
        self.sampleRate = track.sampleRate ?? 0
        self.excludedFromShuffle = track.excludedFromShuffle
    }

    /// Integer key for header-sort on the Shuffle Exclude column (Bool isn't Comparable).
    public var shuffleSortKey: Int {
        self.excludedFromShuffle ? 1 : 0
    }

    // MARK: - Hashable

    /// Hash/equality by track identity only — two rows referring to the
    /// same DB row are treated as equal even if decorated fields differ.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.id)
    }
}
