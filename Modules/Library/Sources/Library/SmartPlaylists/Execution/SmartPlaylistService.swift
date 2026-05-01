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
        try await self.rejectSmartPlaylistReferences(in: criteria)
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
            smartPresetKey: presetKey,
            smartRandomSeed: Int64.random(in: Int64.min ... Int64.max)
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
        if !limitSort.liveUpdate {
            try await self.snapshot(playlistID: id)
        }
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
        try await self.rejectSmartPlaylistReferences(in: criteria, excluding: id)
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
        if !limitSort.liveUpdate {
            try await self.snapshot(playlistID: id)
        } else {
            // Switching back to live mode: clear any stale snapshot rows so
            // tracks(for:) starts returning live results immediately.
            try await self.database.write { db in
                try db.execute(
                    sql: "DELETE FROM playlist_tracks WHERE playlist_id = ?",
                    arguments: [id]
                )
            }
        }
    }

    /// Deletes the smart playlist with `id`.
    public func delete(id: Int64) async throws {
        try await self.database.write { db in
            try db.execute(sql: "DELETE FROM playlists WHERE id = ?", arguments: [id])
        }
        self.log.debug("smartPlaylist.delete", ["id": id])
    }

    /// Regenerates and persists a smart playlist's random seed.
    ///
    /// Callers should refresh/reload tracks after this when presenting random
    /// ordering so the new seed is applied to query compilation.
    @discardableResult
    public func shuffleSeed(id: Int64) async throws -> Int64 {
        let newSeed = Int64.random(in: Int64.min ... Int64.max)
        let now = Self.now()
        try await self.database.write { db in
            guard var playlist = try Playlist.fetchOne(db, key: id) else {
                throw SmartPlaylistError.notFound(id)
            }
            guard playlist.kind == .smart else {
                throw SmartPlaylistError.notSmartPlaylist(id)
            }
            playlist.smartRandomSeed = newSeed
            playlist.updatedAt = now
            try playlist.update(db)
        }
        self.log.debug("smartPlaylist.shuffleSeed", ["id": id])
        return newSeed
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
    ///
    /// Live playlists (`liveUpdate == true`) execute the compiled SELECT.
    /// Snapshot playlists (`liveUpdate == false`) read from the persisted
    /// `playlist_tracks` rows so the contents stay frozen until the user
    /// calls `snapshot(id:)`.
    public func tracks(for id: Int64) async throws -> [Track] {
        let sp = try await self.resolve(id: id)
        if !sp.limitSort.liveUpdate {
            return try await self.database.read { db in
                try Track.fetchAll(db, sql: """
                SELECT tracks.* FROM tracks
                INNER JOIN playlist_tracks ON playlist_tracks.track_id = tracks.id
                WHERE playlist_tracks.playlist_id = ?
                ORDER BY playlist_tracks.position
                """, arguments: [id])
            }
        }
        let compiled = try CriteriaCompiler.compile(
            criteria: sp.criteria,
            limitSort: sp.limitSort,
            seed: Self.querySeed(for: sp)
        )
        return try await self.database.read { db in
            try Track.fetchAll(db, sql: compiled.selectSQL, arguments: compiled.arguments)
        }
    }

    /// Runs the smart playlist's query and atomically replaces its
    /// `playlist_tracks` rows with the result. Used by snapshot playlists
    /// (`liveUpdate == false`) and the manual "Refresh" affordance.
    ///
    /// The query and the replace happen inside a single `database.write`
    /// transaction so observers never see a half-populated playlist.
    @discardableResult
    public func snapshot(playlistID: Int64) async throws -> Int {
        let sp = try await self.resolve(id: playlistID)
        let compiled = try CriteriaCompiler.compile(
            criteria: sp.criteria,
            limitSort: sp.limitSort,
            seed: Self.querySeed(for: sp)
        )
        let snappedAt = Self.now()
        let count = try await self.database.write { db -> Int in
            let tracks = try Track.fetchAll(db, sql: compiled.selectSQL, arguments: compiled.arguments)
            try db.execute(
                sql: "DELETE FROM playlist_tracks WHERE playlist_id = ?",
                arguments: [playlistID]
            )
            let positions = PositionArranger.repackedPositions(count: tracks.count)
            for (track, position) in zip(tracks, positions) {
                guard let tid = track.id else { continue }
                try db.execute(
                    sql: """
                    INSERT INTO playlist_tracks (playlist_id, track_id, position)
                    VALUES (?, ?, ?)
                    """,
                    arguments: [playlistID, tid, position]
                )
            }
            try db.execute(
                sql: "UPDATE playlists SET smart_last_snapshot_at = ?, updated_at = ? WHERE id = ?",
                arguments: [snappedAt, snappedAt, playlistID]
            )
            return tracks.count
        }
        self.log.debug("smartPlaylist.snapshot", ["id": playlistID, "count": count])
        return count
    }

    /// Backwards-compatible wrapper.
    @discardableResult
    public func snapshot(id: Int64) async throws -> Int {
        try await self.snapshot(playlistID: id)
    }

    /// Returns a live stream of track lists that re-emits whenever the relevant
    /// tables change. Debounces by 250ms to avoid flooding on consecutive plays.
    public func observe(_ id: Int64) -> AsyncThrowingStream<[Track], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let sp = try await self.resolve(id: id)
                    let sql: String
                    let args: StatementArguments
                    let regions: [any DatabaseRegionConvertible]
                    if sp.limitSort.liveUpdate {
                        let compiled = try CriteriaCompiler.compile(
                            criteria: sp.criteria,
                            limitSort: sp.limitSort,
                            seed: Self.querySeed(for: sp)
                        )
                        sql = compiled.selectSQL
                        args = compiled.arguments
                        let regionRequest = SQLRequest<Row>(
                            sql: compiled.observationRegionSQL,
                            arguments: compiled.arguments
                        )
                        regions = [regionRequest]
                    } else {
                        // Snapshot mode: observe playlist_tracks so the UI
                        // refreshes when snapshot(id:) writes new rows.
                        sql = """
                        SELECT tracks.* FROM tracks
                        INNER JOIN playlist_tracks ON playlist_tracks.track_id = tracks.id
                        WHERE playlist_tracks.playlist_id = ?
                        ORDER BY playlist_tracks.position
                        """
                        args = [id]
                        let regionRequest = SQLRequest<Row>(
                            sql: """
                            SELECT tracks.id, playlist_tracks.position FROM tracks
                            INNER JOIN playlist_tracks ON playlist_tracks.track_id = tracks.id
                            WHERE playlist_tracks.playlist_id = ?
                            ORDER BY playlist_tracks.position
                            """,
                            arguments: [id]
                        )
                        regions = [regionRequest]
                    }
                    let stream = await self.database.observe(regions: regions) { db in
                        try Track.fetchAll(db, sql: sql, arguments: args)
                    }
                    let debounceMs = max(0, SmartPlaylistPreferences.observeDebounceMilliseconds())
                    let debounceNs = UInt64(debounceMs) * 1_000_000
                    var hasEmittedInitial = false
                    let pending = PendingTracks()
                    var flushTask: Task<Void, Never>?
                    for try await tracks in stream {
                        if !hasEmittedInitial {
                            hasEmittedInitial = true
                            continuation.yield(tracks)
                            continue
                        }

                        let currentGeneration = await pending.store(tracks)
                        flushTask?.cancel()

                        if debounceNs == 0 {
                            if let latest = await pending.takeLatest() {
                                continuation.yield(latest)
                            }
                            continue
                        }

                        flushTask = Task {
                            do {
                                try await Task.sleep(nanoseconds: debounceNs)
                                guard !Task.isCancelled else { return }
                                if let latest = await pending.takeIfMatchingGeneration(currentGeneration) {
                                    continuation.yield(latest)
                                }
                            } catch {
                                // Cancellation is expected when new values arrive.
                            }
                        }
                    }
                    flushTask?.cancel()
                    if let latest = await pending.takeLatest() {
                        continuation.yield(latest)
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

    private static func querySeed(for smartPlaylist: SmartPlaylist) -> Int64 {
        guard smartPlaylist.limitSort.sortBy == .random else { return 0 }
        return smartPlaylist.playlist.smartRandomSeed ?? 0
    }

    /// Walks `criteria` collecting every `playlistRef` referenced by a
    /// `memberOf` / `notMemberOf` rule, and throws
    /// `SmartPlaylistError.cannotReferenceSmartPlaylist` if any of those rows
    /// is itself a smart playlist. `excluding` is used on update to ignore the
    /// playlist's own row (a self-reference will resolve to empty for the
    /// same reason; we still reject smart-on-smart).
    private func rejectSmartPlaylistReferences(
        in criteria: SmartCriterion,
        excluding: Int64? = nil
    ) async throws {
        let refs = Self.collectPlaylistRefs(in: criteria)
        guard !refs.isEmpty else { return }
        let smartRefs = try await self.database.read { db -> [Int64] in
            var found: [Int64] = []
            for id in refs where id != excluding {
                if let row = try Playlist.fetchOne(db, key: id), row.kind == .smart {
                    found.append(id)
                }
            }
            return found
        }
        if let first = smartRefs.first {
            throw SmartPlaylistError.cannotReferenceSmartPlaylist(id: first)
        }
    }

    private static func collectPlaylistRefs(in criteria: SmartCriterion) -> [Int64] {
        switch criteria {
        case let .rule(rule):
            guard rule.comparator == .memberOf || rule.comparator == .notMemberOf else { return [] }
            if case let .playlistRef(id) = rule.value { return [id] }
            return []
        case .invalid:
            return []
        case let .group(_, children):
            return children.flatMap(Self.collectPlaylistRefs(in:))
        }
    }
}

private actor PendingTracks {
    private var tracks: [Track]?
    private var generation: UInt64 = 0

    func store(_ newTracks: [Track]) -> UInt64 {
        self.tracks = newTracks
        self.generation &+= 1
        return self.generation
    }

    func takeIfMatchingGeneration(_ expectedGeneration: UInt64) -> [Track]? {
        guard self.generation == expectedGeneration else { return nil }
        let latest = self.tracks
        self.tracks = nil
        return latest
    }

    func takeLatest() -> [Track]? {
        let latest = self.tracks
        self.tracks = nil
        return latest
    }
}
