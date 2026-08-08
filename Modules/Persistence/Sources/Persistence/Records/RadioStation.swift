import Foundation
import GRDB

/// A user-curated internet radio station, stored in `radio_stations` (phase 27).
///
/// `name`, `streamURL`, and `homePageURL` are user-editable via the add/edit
/// sheet. The remaining optionals are the machine-owned station profile,
/// backfilled from ICY headers and measured stream parameters on a successful
/// connect (27-5) so the info sheet stays useful offline. Timestamps are epoch
/// seconds.
public struct RadioStation: Codable, Equatable, Hashable, FetchableRecord, MutablePersistableRecord,
    Sendable {
    // MARK: - Table

    public static let databaseTableName = "radio_stations"

    // MARK: - Properties

    /// Auto-incremented row identifier; `nil` before first insertion.
    public var id: Int64?
    /// Display name. Never empty: import falls back to the URL host (27-4).
    public var name: String
    /// Absolute http(s) stream URL. Unique: the catalog's identity key.
    public var streamURL: String
    /// Station homepage, from the user or backfilled from `icy-url`.
    public var homePageURL: String?
    /// Genre as advertised by `icy-genre`; free text, wildly inconsistent.
    public var genre: String?
    /// Blurb from `icy-description`.
    public var stationDescription: String?
    /// Codec measured on the last successful connect (e.g. "mp3", "aac").
    public var lastCodec: String?
    /// Bitrate measured on the last successful connect, in kbps.
    public var lastBitrateKbps: Int?
    /// When the stream last connected successfully, as epoch seconds.
    public var lastConnectedAt: Int64?
    /// When the station was added to the catalog, as epoch seconds.
    public var addedAt: Int64

    // MARK: - Init

    public init(
        name: String,
        streamURL: String,
        addedAt: Int64,
        homePageURL: String? = nil,
        genre: String? = nil,
        stationDescription: String? = nil,
        lastCodec: String? = nil,
        lastBitrateKbps: Int? = nil,
        lastConnectedAt: Int64? = nil,
        id: Int64? = nil
    ) {
        self.id = id
        self.name = name
        self.streamURL = streamURL
        self.homePageURL = homePageURL
        self.genre = genre
        self.stationDescription = stationDescription
        self.lastCodec = lastCodec
        self.lastBitrateKbps = lastBitrateKbps
        self.lastConnectedAt = lastConnectedAt
        self.addedAt = addedAt
    }

    /// Captures the auto-incremented row ID after insertion.
    public mutating func didInsert(_ inserted: InsertionSuccess) {
        self.id = inserted.rowID
    }

    // MARK: - CodingKeys

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case streamURL = "stream_url"
        case homePageURL = "home_page_url"
        case genre
        case stationDescription = "station_description"
        case lastCodec = "last_codec"
        case lastBitrateKbps = "last_bitrate_kbps"
        case lastConnectedAt = "last_connected_at"
        case addedAt = "added_at"
    }
}
