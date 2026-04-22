import Foundation
import Persistence

// MARK: - SortKey

/// The column by which a smart playlist's tracks are ordered.
public enum SortKey: String, Sendable, Codable, Hashable, CaseIterable {
    case title
    case artist
    case album
    case year
    case addedAt
    case lastPlayedAt
    case playCount
    case rating
    case duration
    case bpm
    case random
}

// MARK: - LimitSort

/// Controls how many tracks a smart playlist returns and in what order.
public struct LimitSort: Sendable, Codable, Hashable {
    /// Column to order by.
    public var sortBy: SortKey = .addedAt
    /// `true` = ascending, `false` = descending.
    public var ascending = false
    /// Maximum number of tracks; `nil` = unlimited.
    public var limit: Int? = nil
    /// When `true` the playlist re-executes whenever its dependent tables change.
    public var liveUpdate = true

    public init(
        sortBy: SortKey = .addedAt,
        ascending: Bool = false,
        limit: Int? = nil,
        liveUpdate: Bool = true
    ) {
        self.sortBy = sortBy
        self.ascending = ascending
        self.limit = limit
        self.liveUpdate = liveUpdate
    }
}

// MARK: - SmartPlaylist

/// A resolved smart playlist — its `Playlist` row plus decoded criteria and limit/sort.
public struct SmartPlaylist: Sendable {
    public let playlist: Playlist
    public let criteria: SmartCriterion
    public let limitSort: LimitSort

    public var id: Int64 {
        self.playlist.id ?? -1
    }

    public var name: String {
        self.playlist.name
    }
}
