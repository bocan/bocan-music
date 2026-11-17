import Foundation
import GRDB
import Observability

// MARK: - JellyfinServerRecord

/// GRDB record matching the `jellyfin_servers` table.
/// Kept internal to `Persistence`; callers receive the public `JellyfinServerDTO`.
struct JellyfinServerRecord: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "jellyfin_servers"

    var id: String
    var name: String
    var serverURL: String
    var userID: String
    var username: String?
    var deviceID: String
    var allowSelfSignedTLS: Bool
    var maxBitrate: String
    var preferredFormat: String
    var precacheNext: Bool
    var includeInSearch: Bool
    var showInSidebar: Bool
    var scrobble: Bool
    var syncStars: Bool
    var sortIndex: Int
    var createdAt: Double
    var lastConnectedAt: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case serverURL = "server_url"
        case userID = "user_id"
        case username
        case deviceID = "device_id"
        case allowSelfSignedTLS = "allow_self_signed_tls"
        case maxBitrate = "max_bitrate"
        case preferredFormat = "preferred_format"
        case precacheNext = "precache_next"
        case includeInSearch = "include_in_search"
        case showInSidebar = "show_in_sidebar"
        case scrobble
        case syncStars = "sync_stars"
        case sortIndex = "sort_index"
        case createdAt = "created_at"
        case lastConnectedAt = "last_connected_at"
    }
}

// MARK: - JellyfinServerDTO

/// Public data-transfer object used by the `Jellyfin` module to read and write server records.
/// Deliberately carries no secrets. The access token lives in the Keychain only.
public struct JellyfinServerDTO: Sendable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var serverURL: URL
    /// The Jellyfin user id (an opaque GUID string) the token belongs to.
    public var userID: String
    public var username: String?
    /// Client device id sent in the authorization header. Made once per server.
    public var deviceID: String
    public var allowSelfSignedTLS: Bool
    public var maxBitrate: String // "original" | "128" | "192" | "256" | "320"
    public var preferredFormat: String // "original" | "mp3" | "opus" | "aac" | "flac"
    public var precacheNext: Bool
    public var includeInSearch: Bool
    public var showInSidebar: Bool
    public var scrobble: Bool
    public var syncStars: Bool
    public var sortIndex: Int
    public var createdAt: Date
    public var lastConnectedAt: Date?

    public init(
        // swiftlint:disable function_default_parameter_at_end
        id: UUID = UUID(),
        name: String,
        serverURL: URL,
        userID: String,
        username: String? = nil,
        deviceID: String,
        // swiftlint:enable function_default_parameter_at_end
        allowSelfSignedTLS: Bool = false,
        maxBitrate: String = "original",
        preferredFormat: String = "original",
        precacheNext: Bool = true,
        includeInSearch: Bool = true,
        showInSidebar: Bool = true,
        scrobble: Bool = true,
        syncStars: Bool = true,
        sortIndex: Int = 0,
        createdAt: Date = Date(),
        lastConnectedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.serverURL = serverURL
        self.userID = userID
        self.username = username
        self.deviceID = deviceID
        self.allowSelfSignedTLS = allowSelfSignedTLS
        self.maxBitrate = maxBitrate
        self.preferredFormat = preferredFormat
        self.precacheNext = precacheNext
        self.includeInSearch = includeInSearch
        self.showInSidebar = showInSidebar
        self.scrobble = scrobble
        self.syncStars = syncStars
        self.sortIndex = sortIndex
        self.createdAt = createdAt
        self.lastConnectedAt = lastConnectedAt
    }
}

// MARK: - JellyfinServerRepository

/// CRUD repository for `jellyfin_servers` and `jellyfin_metadata_cache`.
///
/// Access tokens are never stored here. Callers write the token to the
/// Keychain before calling `insert` or `update`.
public struct JellyfinServerRepository: Sendable {
    // MARK: - Properties

    private let database: Database
    private let log = AppLogger.make(.persistence)

    // MARK: - Init

    public init(database: Database) {
        self.database = database
    }

    // MARK: - Conversions

    private func toRecord(_ dto: JellyfinServerDTO) -> JellyfinServerRecord {
        JellyfinServerRecord(
            id: dto.id.uuidString,
            name: dto.name,
            serverURL: dto.serverURL.absoluteString,
            userID: dto.userID,
            username: dto.username,
            deviceID: dto.deviceID,
            allowSelfSignedTLS: dto.allowSelfSignedTLS,
            maxBitrate: dto.maxBitrate,
            preferredFormat: dto.preferredFormat,
            precacheNext: dto.precacheNext,
            includeInSearch: dto.includeInSearch,
            showInSidebar: dto.showInSidebar,
            scrobble: dto.scrobble,
            syncStars: dto.syncStars,
            sortIndex: dto.sortIndex,
            createdAt: dto.createdAt.timeIntervalSince1970,
            lastConnectedAt: dto.lastConnectedAt?.timeIntervalSince1970
        )
    }

    private func toDTO(_ record: JellyfinServerRecord) throws -> JellyfinServerDTO {
        guard let id = UUID(uuidString: record.id) else {
            throw PersistenceError.notFound(entity: "JellyfinServer", id: -1)
        }
        guard let url = URL(string: record.serverURL) else {
            throw PersistenceError.notFound(entity: "JellyfinServer", id: -1)
        }
        return JellyfinServerDTO(
            id: id,
            name: record.name,
            serverURL: url,
            userID: record.userID,
            username: record.username,
            deviceID: record.deviceID,
            allowSelfSignedTLS: record.allowSelfSignedTLS,
            maxBitrate: record.maxBitrate,
            preferredFormat: record.preferredFormat,
            precacheNext: record.precacheNext,
            includeInSearch: record.includeInSearch,
            showInSidebar: record.showInSidebar,
            scrobble: record.scrobble,
            syncStars: record.syncStars,
            sortIndex: record.sortIndex,
            createdAt: Date(timeIntervalSince1970: record.createdAt),
            lastConnectedAt: record.lastConnectedAt.map { Date(timeIntervalSince1970: $0) }
        )
    }

    // MARK: - Write

    /// Inserts a new server record. Throws if `name` is not unique.
    public func insert(_ dto: JellyfinServerDTO) async throws {
        let snapshot = self.toRecord(dto)
        try await self.database.write { db in
            var record = snapshot
            try record.insert(db)
        }
        self.log.info("jellyfin.server.insert", ["id": dto.id.uuidString, "name": dto.name])
    }

    /// Updates an existing server record. Throws if no row matches `dto.id`.
    public func update(_ dto: JellyfinServerDTO) async throws {
        let snapshot = self.toRecord(dto)
        try await self.database.write { db in
            try snapshot.update(db)
        }
        self.log.debug("jellyfin.server.update", ["id": dto.id.uuidString])
    }

    /// Persists only `last_connected_at` for a server, avoiding a full
    /// read-modify-write round trip. Called by the connection monitor.
    public func updateLastConnected(id: UUID, at date: Date = Date()) async throws {
        try await self.database.write { db in
            try db.execute(
                sql: "UPDATE jellyfin_servers SET last_connected_at = ? WHERE id = ?",
                arguments: [date.timeIntervalSince1970, id.uuidString]
            )
        }
        self.log.debug("jellyfin.server.connected.updated", ["id": id.uuidString])
    }

    /// Deletes the server row. The caller must separately remove the Keychain item.
    public func delete(id: UUID) async throws {
        try await self.database.write { db in
            try db.execute(
                sql: "DELETE FROM jellyfin_servers WHERE id = ?",
                arguments: [id.uuidString]
            )
        }
        self.log.info("jellyfin.server.delete", ["id": id.uuidString])
    }

    // MARK: - Read

    /// Returns all servers, ordered by `sort_index` then `created_at`.
    public func fetchAll() async throws -> [JellyfinServerDTO] {
        let records = try await self.database.read { db in
            try JellyfinServerRecord
                .order(Column("sort_index"), Column("created_at"))
                .fetchAll(db)
        }
        return try records.map { try self.toDTO($0) }
    }

    /// Returns a single server by UUID, or `nil` if not found.
    public func fetch(id: UUID) async throws -> JellyfinServerDTO? {
        let record = try await self.database.read { db in
            try JellyfinServerRecord.fetchOne(db, key: id.uuidString)
        }
        return try record.map { try self.toDTO($0) }
    }

    // MARK: - Metadata cache

    /// Upserts a metadata cache entry.
    public func upsertCache(
        serverID: UUID,
        entityKind: String,
        entityID: String,
        payloadJSON: Data
    ) async throws {
        try await self.database.write { db in
            try db.execute(
                sql: """
                INSERT INTO jellyfin_metadata_cache
                    (server_id, entity_kind, entity_id, payload_json, fetched_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(server_id, entity_kind, entity_id)
                DO UPDATE SET payload_json = excluded.payload_json,
                              fetched_at   = excluded.fetched_at
                """,
                arguments: [
                    serverID.uuidString, entityKind, entityID, payloadJSON,
                    Date().timeIntervalSince1970,
                ]
            )
        }
    }

    /// Fetches a cached metadata entry, or `nil` if absent or stale (older than 7 days).
    public func fetchCache(
        serverID: UUID,
        entityKind: String,
        entityID: String
    ) async throws -> Data? {
        let staleCutoff = Date().timeIntervalSince1970 - 7 * 86400
        return try await self.database.read { db in
            try Data.fetchOne(
                db,
                sql: """
                SELECT payload_json FROM jellyfin_metadata_cache
                WHERE server_id = ? AND entity_kind = ? AND entity_id = ?
                  AND fetched_at > ?
                """,
                arguments: [serverID.uuidString, entityKind, entityID, staleCutoff]
            )
        }
    }

    /// Removes all cache entries for a server (call on server delete).
    public func deleteCache(serverID: UUID) async throws {
        try await self.database.write { db in
            try db.execute(
                sql: "DELETE FROM jellyfin_metadata_cache WHERE server_id = ?",
                arguments: [serverID.uuidString]
            )
        }
        self.log.debug("jellyfin.cache.cleared", ["serverID": serverID.uuidString])
    }

    /// Deletes cache entries older than 7 days across all servers.
    /// Call once on app launch.
    public func pruneStaleCache() async throws {
        let cutoff = Date().timeIntervalSince1970 - 7 * 86400
        let deleted = try await self.database.write { db -> Int in
            try db.execute(
                sql: "DELETE FROM jellyfin_metadata_cache WHERE fetched_at < ?",
                arguments: [cutoff]
            )
            return db.changesCount
        }
        if deleted > 0 {
            self.log.info("jellyfin.cache.pruned", ["rows": deleted])
        }
    }
}
