import Foundation
import Persistence

// MARK: - SortKey

/// The column by which a smart playlist's tracks are ordered.
public enum SortKey: String, Sendable, Codable, Hashable, CaseIterable {
    case title
    case artist
    case album
    case year
    case trackNumber
    case addedAt
    case lastPlayedAt
    case playCount
    case rating
    case duration
    case bpm
    case random
}

// MARK: - SmartSortDescriptor

/// A single ordered sort key with a direction. A smart playlist sorts by an
/// ordered list of these: the first descriptor is the primary sort, the next
/// breaks ties, and so on (e.g. Artist, then Track Number, then Title).
public struct SmartSortDescriptor: Sendable, Codable, Hashable {
    /// Column to order by.
    public var key: SortKey
    /// `true` = ascending, `false` = descending.
    public var ascending: Bool

    public init(key: SortKey, ascending: Bool = false) {
        self.key = key
        self.ascending = ascending
    }
}

// MARK: - LimitSort

/// Controls how many tracks a smart playlist returns and in what order.
///
/// Ordering is an ordered list of `SmartSortDescriptor`s so a playlist can sort
/// by several keys with priorities (primary, then tie-breakers). `random` is
/// mutually exclusive with column sorting: when the primary key is `random` the
/// rest of the list is ignored and a stable seeded shuffle is used instead.
public struct LimitSort: Sendable, Codable, Hashable {
    /// Ordered sort keys. Never empty after initialization / decoding.
    public var sortDescriptors: [SmartSortDescriptor]
    /// Maximum number of tracks; `nil` = unlimited.
    public var limit: Int?
    /// When `true` the playlist re-executes whenever its dependent tables change.
    public var liveUpdate: Bool

    /// The primary sort column. Reads/writes the first descriptor so existing
    /// single-key call sites keep working.
    public var sortBy: SortKey {
        get { self.sortDescriptors.first?.key ?? .addedAt }
        set {
            if self.sortDescriptors.isEmpty {
                self.sortDescriptors = [SmartSortDescriptor(key: newValue)]
            } else {
                self.sortDescriptors[0].key = newValue
            }
        }
    }

    /// The primary sort direction. Reads/writes the first descriptor.
    public var ascending: Bool {
        get { self.sortDescriptors.first?.ascending ?? false }
        set {
            if self.sortDescriptors.isEmpty {
                self.sortDescriptors = [SmartSortDescriptor(key: .addedAt, ascending: newValue)]
            } else {
                self.sortDescriptors[0].ascending = newValue
            }
        }
    }

    /// Single-key convenience initializer (back-compat with earlier callers).
    public init(
        sortBy: SortKey = .addedAt,
        ascending: Bool = false,
        limit: Int? = nil,
        liveUpdate: Bool = true
    ) {
        self.sortDescriptors = [SmartSortDescriptor(key: sortBy, ascending: ascending)]
        self.limit = limit
        self.liveUpdate = liveUpdate
    }

    /// Multi-key initializer. An empty `sortDescriptors` falls back to the
    /// default (Date Added, descending) so the list is never empty.
    public init(
        sortDescriptors: [SmartSortDescriptor],
        limit: Int? = nil,
        liveUpdate: Bool = true
    ) {
        self.sortDescriptors = sortDescriptors.isEmpty
            ? [SmartSortDescriptor(key: .addedAt)]
            : sortDescriptors
        self.limit = limit
        self.liveUpdate = liveUpdate
    }

    // MARK: - Codable (backward compatible)

    private enum CodingKeys: String, CodingKey {
        case sortDescriptors
        case sortBy
        case ascending
        case limit
        case liveUpdate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let descriptors = try container.decodeIfPresent([SmartSortDescriptor].self, forKey: .sortDescriptors),
           !descriptors.isEmpty {
            self.sortDescriptors = descriptors
        } else {
            // Legacy single-key shape: {"sortBy": …, "ascending": …}.
            let key = try container.decodeIfPresent(SortKey.self, forKey: .sortBy) ?? .addedAt
            let asc = try container.decodeIfPresent(Bool.self, forKey: .ascending) ?? false
            self.sortDescriptors = [SmartSortDescriptor(key: key, ascending: asc)]
        }
        self.limit = try container.decodeIfPresent(Int.self, forKey: .limit) ?? nil
        self.liveUpdate = try container.decodeIfPresent(Bool.self, forKey: .liveUpdate) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.sortDescriptors, forKey: .sortDescriptors)
        // Mirror the primary key into the legacy scalar fields so an older build
        // reading this JSON still recovers a sensible single-key sort.
        try container.encode(self.sortBy, forKey: .sortBy)
        try container.encode(self.ascending, forKey: .ascending)
        try container.encodeIfPresent(self.limit, forKey: .limit)
        try container.encode(self.liveUpdate, forKey: .liveUpdate)
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
