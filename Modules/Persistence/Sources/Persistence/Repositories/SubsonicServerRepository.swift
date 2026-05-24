import Foundation
import GRDB
import Observability

// MARK: - SubsonicServerRecord

/// GRDB record matching the `subsonic_servers` table.
/// Kept internal to `Persistence`; callers receive the public `SubsonicServerDTO`.
struct SubsonicServerRecord: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "subsonic_servers"

    var id: String
    var name: String
    var serverURL: String
    var authKind: String
    var username: String?
    var keychainAccount: String
    var allowSelfSignedTLS: Bool
    var maxBitrate: String
    var preferredFormat: String
    var precacheNext: Bool
    var includeInSearch: Bool
    var showInSidebar: Bool
    var scrobble: Bool
    var syncStars: Bool
    var syncRatings: Bool
    var sortIndex: Int
    var createdAt: Double
    var lastConnectedAt: Double?
    var capabilitiesJSON: Data?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case serverURL = "server_url"
        case authKind = "auth_kind"
        case username
        case keychainAccount = "keychain_account"
        case allowSelfSignedTLS = "allow_self_signed_tls"
        case maxBitrate = "max_bitrate"
        case preferredFormat = "preferred_format"
        case precacheNext = "precache_next"
        case includeInSearch = "include_in_search"
        case showInSidebar = "show_in_sidebar"
        case scrobble
        case syncStars = "sync_stars"
        case syncRatings = "sync_ratings"
        case sortIndex = "sort_index"
        case createdAt = "created_at"
        case lastConnectedAt = "last_connected_at"
        case capabilitiesJSON = "capabilities_json"
    }
}

// MARK: - SubsonicServerDTO

/// Public data-transfer object used by the `Subsonic` module to read/write server records.
/// Deliberately carries no secrets — credentials live in the Keychain only.
public struct SubsonicServerDTO: Sendable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var serverURL: URL
    public var authKind: String // "tokenSalt" | "apiKey"
    public var username: String?
    public var keychainAccount: String
    public var allowSelfSignedTLS: Bool
    public var maxBitrate: String // "original" | "128" | "192" | "256" | "320"
    public var preferredFormat: String // "original" | "mp3" | "opus" | "aac" | "flac"
    public var precacheNext: Bool
    public var includeInSearch: Bool
    public var showInSidebar: Bool
    public var scrobble: Bool
    public var syncStars: Bool
    public var syncRatings: Bool
    public var sortIndex: Int
    public var createdAt: Date
    public var lastConnectedAt: Date?
    public var capabilitiesJSON: Data?

    public init(
        // swiftlint:disable function_default_parameter_at_end
        id: UUID = UUID(),
        name: String,
        serverURL: URL,
        authKind: String,
        username: String? = nil,
        keychainAccount: String,
        // swiftlint:enable function_default_parameter_at_end
        allowSelfSignedTLS: Bool = false,
        maxBitrate: String = "original",
        preferredFormat: String = "original",
        precacheNext: Bool = true,
        includeInSearch: Bool = true,
        showInSidebar: Bool = true,
        scrobble: Bool = true,
        syncStars: Bool = true,
        syncRatings: Bool = true,
        sortIndex: Int = 0,
        createdAt: Date = Date(),
        lastConnectedAt: Date? = nil,
        capabilitiesJSON: Data? = nil
    ) {
        self.id = id
        self.name = name
        self.serverURL = serverURL
        self.authKind = authKind
        self.username = username
        self.keychainAccount = keychainAccount
        self.allowSelfSignedTLS = allowSelfSignedTLS
        self.maxBitrate = maxBitrate
        self.preferredFormat = preferredFormat
        self.precacheNext = precacheNext
        self.includeInSearch = includeInSearch
        self.showInSidebar = showInSidebar
        self.scrobble = scrobble
        self.syncStars = syncStars
        self.syncRatings = syncRatings
        self.sortIndex = sortIndex
        self.createdAt = createdAt
        self.lastConnectedAt = lastConnectedAt
        self.capabilitiesJSON = capabilitiesJSON
    }
}

// MARK: - SubsonicServerRepository

/// CRUD repository for `subsonic_servers` and `subsonic_metadata_cache`.
///
/// Passwords / API keys are never stored here — callers are responsible for
/// writing secrets to the Keychain before calling `insert` or `update`.
public struct SubsonicServerRepository: Sendable {
    // MARK: - Properties

    private let database: Database
    private let log = AppLogger.make(.persistence)

    // MARK: - Init

    public init(database: Database) {
        self.database = database
    }

    // MARK: - Conversions

    private func toRecord(_ dto: SubsonicServerDTO) -> SubsonicServerRecord {
        SubsonicServerRecord(
            id: dto.id.uuidString,
            name: dto.name,
            serverURL: dto.serverURL.absoluteString,
            authKind: dto.authKind,
            username: dto.username,
            keychainAccount: dto.keychainAccount,
            allowSelfSignedTLS: dto.allowSelfSignedTLS,
            maxBitrate: dto.maxBitrate,
            preferredFormat: dto.preferredFormat,
            precacheNext: dto.precacheNext,
            includeInSearch: dto.includeInSearch,
            showInSidebar: dto.showInSidebar,
            scrobble: dto.scrobble,
            syncStars: dto.syncStars,
            syncRatings: dto.syncRatings,
            sortIndex: dto.sortIndex,
            createdAt: dto.createdAt.timeIntervalSince1970,
            lastConnectedAt: dto.lastConnectedAt?.timeIntervalSince1970,
            capabilitiesJSON: dto.capabilitiesJSON
        )
    }

    private func toDTO(_ record: SubsonicServerRecord) throws -> SubsonicServerDTO {
        guard let id = UUID(uuidString: record.id) else {
            throw PersistenceError.notFound(entity: "SubsonicServer", id: -1)
        }
        guard let url = URL(string: record.serverURL) else {
            throw PersistenceError.notFound(entity: "SubsonicServer", id: -1)
        }
        return SubsonicServerDTO(
            id: id,
            name: record.name,
            serverURL: url,
            authKind: record.authKind,
            username: record.username,
            keychainAccount: record.keychainAccount,
            allowSelfSignedTLS: record.allowSelfSignedTLS,
            maxBitrate: record.maxBitrate,
            preferredFormat: record.preferredFormat,
            precacheNext: record.precacheNext,
            includeInSearch: record.includeInSearch,
            showInSidebar: record.showInSidebar,
            scrobble: record.scrobble,
            syncStars: record.syncStars,
            syncRatings: record.syncRatings,
            sortIndex: record.sortIndex,
            createdAt: Date(timeIntervalSince1970: record.createdAt),
            lastConnectedAt: record.lastConnectedAt.map { Date(timeIntervalSince1970: $0) },
            capabilitiesJSON: record.capabilitiesJSON
        )
    }

    // MARK: - Write

    /// Inserts a new server record. Throws if `name` is not unique.
    public func insert(_ dto: SubsonicServerDTO) async throws {
        let snapshot = self.toRecord(dto)
        try await self.database.write { db in
            var record = snapshot
            try record.insert(db)
        }
        self.log.info("subsonic.server.insert", ["id": dto.id.uuidString, "name": dto.name])
    }

    /// Updates an existing server record. Throws if no row matches `dto.id`.
    public func update(_ dto: SubsonicServerDTO) async throws {
        let snapshot = self.toRecord(dto)
        try await self.database.write { db in
            try snapshot.update(db)
        }
        self.log.debug("subsonic.server.update", ["id": dto.id.uuidString])
    }

    /// Persists only the capabilities JSON and `last_connected_at` for a server,
    /// avoiding a full round-trip read-modify-write.
    public func updateCapabilities(
        id: UUID,
        capabilitiesJSON: Data?,
        lastConnectedAt: Date = Date()
    ) async throws {
        try await self.database.write { db in
            try db.execute(
                sql: """
                UPDATE subsonic_servers
                SET capabilities_json = ?, last_connected_at = ?
                WHERE id = ?
                """,
                arguments: [capabilitiesJSON, lastConnectedAt.timeIntervalSince1970, id.uuidString]
            )
        }
        self.log.debug("subsonic.server.capabilities.updated", ["id": id.uuidString])
    }

    /// Deletes the server row. The caller must separately remove the Keychain item.
    public func delete(id: UUID) async throws {
        try await self.database.write { db in
            try db.execute(
                sql: "DELETE FROM subsonic_servers WHERE id = ?",
                arguments: [id.uuidString]
            )
        }
        self.log.info("subsonic.server.delete", ["id": id.uuidString])
    }

    // MARK: - Read

    /// Returns all servers, ordered by `sort_index` then `created_at`.
    public func fetchAll() async throws -> [SubsonicServerDTO] {
        let records = try await self.database.read { db in
            try SubsonicServerRecord
                .order(Column("sort_index"), Column("created_at"))
                .fetchAll(db)
        }
        return try records.map { try self.toDTO($0) }
    }

    /// Returns a single server by UUID, or `nil` if not found.
    public func fetch(id: UUID) async throws -> SubsonicServerDTO? {
        let record = try await self.database.read { db in
            try SubsonicServerRecord.fetchOne(db, key: id.uuidString)
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
                INSERT INTO subsonic_metadata_cache
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

    /// Fetches a cached metadata entry, or `nil` if absent / stale (>7 days).
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
                SELECT payload_json FROM subsonic_metadata_cache
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
                sql: "DELETE FROM subsonic_metadata_cache WHERE server_id = ?",
                arguments: [serverID.uuidString]
            )
        }
        self.log.debug("subsonic.cache.cleared", ["serverID": serverID.uuidString])
    }

    /// Deletes cache entries older than 7 days across all servers.
    /// Call once on app launch.
    public func pruneStaleCache() async throws {
        let cutoff = Date().timeIntervalSince1970 - 7 * 86400
        let deleted = try await self.database.write { db -> Int in
            try db.execute(
                sql: "DELETE FROM subsonic_metadata_cache WHERE fetched_at < ?",
                arguments: [cutoff]
            )
            return db.changesCount
        }
        if deleted > 0 {
            self.log.info("subsonic.cache.pruned", ["rows": deleted])
        }
    }
}
