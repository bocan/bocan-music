import Foundation
import GRDB
import Observability

/// Typed access to `radio_stations`, the local internet radio catalog (ADR-078).
///
/// Writes come from three places: the add/edit sheet (`insert` / `update` /
/// `delete`), playlist import (`upsert`, which never clobbers user edits), and
/// the engine's station-profile capture after a successful connect
/// (`recordConnection`). The Radio pane stays live through `observeAll`.
public struct RadioStationRepository: Sendable {
    // MARK: - Properties

    private let database: Database
    private let log = AppLogger.make(.persistence)

    // MARK: - Init

    public init(database: Database) {
        self.database = database
    }

    // MARK: - Read

    /// All stations, name-ordered (Finder-like, case-insensitive).
    public func fetchAll() async throws -> [RadioStation] {
        try await self.database.read { db in
            try RadioStation
                .order(Column("name").collating(.localizedStandardCompare))
                .fetchAll(db)
        }
    }

    /// The station with `streamURL`, if the catalog holds it.
    public func fetchOne(streamURL: String) async throws -> RadioStation? {
        try await self.database.read { db in
            try RadioStation
                .filter(Column("stream_url") == streamURL)
                .fetchOne(db)
        }
    }

    // MARK: - Write

    /// Inserts a new station and returns it with its row id set.
    /// Throws on a duplicate `stream_url`; the add sheet surfaces that as
    /// "station already exists" rather than silently merging.
    @discardableResult
    public func insert(_ station: RadioStation) async throws -> RadioStation {
        let saved = try await self.database.write { db in
            var copy = station
            try copy.insert(db)
            return copy
        }
        self.log.debug("radio_station.insert", ["name": saved.name])
        return saved
    }

    /// Updates an existing station (the edit sheet, and 27-5's junk-name rescue).
    public func update(_ station: RadioStation) async throws {
        try await self.database.write { db in
            try station.update(db)
        }
        self.log.debug("radio_station.update", ["name": station.name])
    }

    /// Deletes a station.
    public func delete(id: Int64) async throws {
        let removed = try await self.database.write { db in
            try RadioStation.deleteOne(db, key: id)
        }
        self.log.debug("radio_station.delete", ["removed": removed])
    }

    /// Inserts `station` unless a row with the same `stream_url` already
    /// exists, in which case the existing row, and any user edits on it, is
    /// left untouched. Returns whether a new row was inserted, so playlist
    /// import can report an honest "stations added" count. This insert-if-new
    /// behaviour is what makes re-importing the same playlist idempotent (27-4).
    @discardableResult
    public func upsert(_ station: RadioStation) async throws -> Bool {
        let inserted = try await self.database.write { db in
            let exists = try RadioStation
                .filter(Column("stream_url") == station.streamURL)
                .fetchCount(db) > 0
            if exists { return false }
            var copy = station
            try copy.insert(db)
            return true
        }
        self.log.debug("radio_station.upsert", ["name": station.name, "inserted": inserted])
        return inserted
    }

    /// Records a successful connect (27-5): stamps `last_connected_at` and
    /// refreshes the machine-owned profile columns. A `nil` argument keeps the
    /// stored value, because an absent ICY header must not erase a previously
    /// seen one. `homePageURL` only fills a NULL column, because the field is
    /// user-editable. `name` is deliberately untouched here; 27-5's junk-name
    /// rescue goes through `update` at the call site.
    public func recordConnection(
        streamURL: String,
        at connectedAt: Int64,
        genre: String? = nil,
        stationDescription: String? = nil,
        homePageURL: String? = nil,
        lastCodec: String? = nil,
        lastBitrateKbps: Int? = nil,
        lastContainer: String? = nil,
        lastSampleRateHz: Int? = nil,
        lastChannels: Int? = nil
    ) async throws {
        try await self.database.write { db in
            try db.execute(
                sql: """
                UPDATE radio_stations SET
                    genre = COALESCE(?, genre),
                    station_description = COALESCE(?, station_description),
                    home_page_url = COALESCE(home_page_url, ?),
                    last_codec = COALESCE(?, last_codec),
                    last_bitrate_kbps = COALESCE(?, last_bitrate_kbps),
                    last_container = COALESCE(?, last_container),
                    last_sample_rate_hz = COALESCE(?, last_sample_rate_hz),
                    last_channels = COALESCE(?, last_channels),
                    last_connected_at = ?
                WHERE stream_url = ?
                """,
                arguments: [
                    genre, stationDescription, homePageURL,
                    lastCodec, lastBitrateKbps, lastContainer,
                    lastSampleRateHz, lastChannels, connectedAt, streamURL,
                ]
            )
        }
        self.log.debug("radio_station.connect", ["url": streamURL])
    }

    // MARK: - Observation

    /// Streams the full catalog immediately and again on every change, so the
    /// Radio pane picks up imports and profile backfills without a reload.
    public func observeAll() async -> AsyncThrowingStream<[RadioStation], Error> {
        await self.database.observe { db in
            try RadioStation
                .order(Column("name").collating(.localizedStandardCompare))
                .fetchAll(db)
        }
    }
}
