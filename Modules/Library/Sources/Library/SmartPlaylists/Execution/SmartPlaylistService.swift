import Foundation
import GRDB
import Observability
import Persistence

// MARK: - SmartPlaylistService

/// Actor-isolated façade for smart playlist CRUD and track retrieval.
///
/// Criteria and limit/sort settings are persisted as JSON in the `smart_criteria`
/// and `smart_limit_sort` columns on the `playlists` table.
public actor SmartPlaylistService {
    // MARK: - Dependencies

    private let database: Persistence.Database
    private let log: AppLogger

    // MARK: - Init

    public init(database: Persistence.Database, logger: AppLogger = .make(.library)) {
        self.database = database
        self.log = logger
    }

    // MARK: - CRUD

    /// Creates a new smart playlist and returns the persisted row.
    @discardableResult
    public func create(
        name: String,
        criteria: SmartCriterion,
        limitSort: LimitSort = LimitSort(),
        parentID: Int64? = nil,
        presetKey: String? = nil
    ) async throws -> Playlist {
        try Validator.validate(criteria)
        let criteriaJSON = try Self.encode(criteria)
        let limitSortJSON = try Self.encodeLimitSort(limitSort)
        let now = Self.now()
        var playlist = Playlist(
            name: name,
            isSmart: true,
            smartCriteria: criteriaJSON,
            createdAt: now,
            updatedAt: now,
            parentID: parentID,
            kind: .smart,
            smartLimitSort: limitSortJSON,
            smartPresetKey: presetKey
        )
        let id = try await self.database.write { [playlist] db in
            var localPlaylist = playlist
            try localPlaylist.insert(db)
            guard let rowID = localPlaylist.id else {
                throw PersistenceError.notFound(entity: "Playlist", id: -1)
            }
            return rowID
        }
        playlist.id = id
        self.log.debug("smartPlaylist.create", ["id": id, "name": name])
        return playlist
    }

    /// Updates the criteria and limit/sort for an existing smart playlist.
    public func update(
        id: Int64,
        name: String? = nil,
        criteria: SmartCriterion,
        limitSort: LimitSort
    ) async throws {
        try Validator.validate(criteria)
        let criteriaJSON = try Self.encode(criteria)
        let limitSortJSON = try Self.encodeLimitSort(limitSort)
        let now = Self.now()
        try await self.database.write { db in
            guard var playlist = try Playlist.fetchOne(db, key: id) else {
                throw SmartPlaylistError.notFound(id)
            }
            guard playlist.kind == .smart else { throw SmartPlaylistError.notSmartPlaylist(id) }
            playlist.smartCriteria = criteriaJSON
            playlist.smartLimitSort = limitSortJSON
            playlist.updatedAt = now
            if let name { playlist.name = name }
            try playlist.update(db)
        }
        self.log.debug("smartPlaylist.update", ["id": id])
    }

    /// Deletes the smart playlist with `id`.
    public func delete(id: Int64) async throws {
        try await self.database.write { db in
            try db.execute(sql: "DELETE FROM playlists WHERE id = ?", arguments: [id])
        }
        self.log.debug("smartPlaylist.delete", ["id": id])
    }

    /// Resolves a smart playlist by `id`, returning its `SmartPlaylist` wrapper.
    public func resolve(id: Int64) async throws -> SmartPlaylist {
        let playlist = try await self.database.read { db in
            try Playlist.fetchOne(db, key: id)
        }
        guard let playlist else { throw SmartPlaylistError.notFound(id) }
        guard playlist.kind == .smart else { throw SmartPlaylistError.notSmartPlaylist(id) }
        return try Self.decode(playlist)
    }

    /// Executes the smart playlist's query and returns matching tracks.
    public func tracks(for id: Int64) async throws -> [Track] {
        let sp = try await self.resolve(id: id)
        let compiled = try CriteriaCompiler.compile(
            criteria: sp.criteria,
            limitSort: sp.limitSort,
            seed: sp.playlist.id ?? 0
        )
        return try await self.database.read { db in
            try Track.fetchAll(db, sql: compiled.selectSQL, arguments: compiled.arguments)
        }
    }

    /// Returns a live stream of track lists that re-emits whenever the relevant
    /// tables change. Debounces by 250ms to avoid flooding on consecutive plays.
    public func observe(_ id: Int64) -> AsyncThrowingStream<[Track], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let sp = try await self.resolve(id: id)
                    let compiled = try CriteriaCompiler.compile(
                        criteria: sp.criteria,
                        limitSort: sp.limitSort,
                        seed: sp.playlist.id ?? 0
                    )
                    let sql = compiled.selectSQL
                    let args = compiled.arguments
                    let stream = await self.database.observe { db in
                        try Track.fetchAll(db, sql: sql, arguments: args)
                    }
                    var lastEmit = Date.distantPast
                    for try await tracks in stream {
                        // Debounce: only emit if at least 250ms has passed.
                        let now = Date()
                        if now.timeIntervalSince(lastEmit) >= 0.25 {
                            continuation.yield(tracks)
                            lastEmit = now
                        } else {
                            // Brief delay then emit (simplified debounce).
                            try await Task.sleep(nanoseconds: 250_000_000)
                            continuation.yield(tracks)
                            lastEmit = Date()
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Returns all smart playlists, sorted by `sort_order` then `name`.
    public func listAll() async throws -> [Playlist] {
        try await self.database.read { db in
            try Playlist.filter(Column("kind") == PlaylistKind.smart.rawValue)
                .order(Column("sort_order").asc, Column("name").asc)
                .fetchAll(db)
        }
    }

    // MARK: - Private helpers

    private static func encode(_ criteria: SmartCriterion) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(criteria)
        guard let json = String(data: data, encoding: .utf8) else {
            throw SmartPlaylistError.decodeFailed("UTF-8 encoding failed")
        }
        return json
    }

    private static func encodeLimitSort(_ ls: LimitSort) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(ls)
        guard let json = String(data: data, encoding: .utf8) else {
            throw SmartPlaylistError.decodeFailed("UTF-8 encoding failed")
        }
        return json
    }

    private static func decode(_ playlist: Playlist) throws -> SmartPlaylist {
        guard let criteriaJSON = playlist.smartCriteria else {
            throw SmartPlaylistError.decodeFailed("Missing smart_criteria")
        }
        guard let data = criteriaJSON.data(using: .utf8) else {
            throw SmartPlaylistError.decodeFailed("Invalid UTF-8 in smart_criteria")
        }
        let criteria: SmartCriterion
        do {
            criteria = try JSONDecoder().decode(SmartCriterion.self, from: data)
        } catch {
            throw SmartPlaylistError.decodeFailed(String(describing: error))
        }

        var limitSort = LimitSort()
        if let lsJSON = playlist.smartLimitSort,
           let lsData = lsJSON.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(LimitSort.self, from: lsData) {
            limitSort = decoded
        }

        return SmartPlaylist(playlist: playlist, criteria: criteria, limitSort: limitSort)
    }

    private static func now() -> Int64 {
        Int64(Date().timeIntervalSince1970)
    }
}
