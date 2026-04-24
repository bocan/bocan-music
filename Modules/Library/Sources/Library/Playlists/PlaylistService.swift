import Foundation
import GRDB
import Observability
import Persistence

// Persistence and GRDB both export a type called `Database`. In this file,
// `Persistence.Database` is used for the actor-isolated gateway; the GRDB
// handle appears only as a closure parameter in `observe(_:)`. All bare
// references to `Database` below are qualified.

// MARK: - PlaylistService

/// Actor-isolated façade for every playlist mutation in the app.
///
/// Responsibilities:
/// - Creating, renaming, reparenting, and deleting playlists and folders.
/// - Managing membership with sparse integer positions (see `PositionArranger`).
/// - Preventing folder cycles.
/// - Producing the `PlaylistNode` forest the UI renders.
/// - Exposing an observation stream for a playlist's track list.
///
/// Higher-level UI flows (drag-to-reorder, "New Playlist from Selection",
/// the Add-to-Playlist menu) call through this actor so the DB, the
/// positional algebra, and the folder tree never drift out of sync.
public actor PlaylistService {
    // MARK: - Dependencies

    private let database: Persistence.Database
    private let repo: PlaylistRepository
    private let log: AppLogger

    // MARK: - Init

    /// Creates a service backed by `database`.
    public init(database: Persistence.Database, logger: AppLogger = .make(.library)) {
        self.database = database
        self.repo = PlaylistRepository(database: database)
        self.log = logger
    }

    // MARK: - CRUD

    /// Creates a new manual playlist and returns its persisted form.
    @discardableResult
    public func create(name: String, parentID: Int64? = nil) async throws -> Playlist {
        try await self.createRow(name: name, kind: .manual, parentID: parentID)
    }

    /// Creates a new folder (a playlist row with `kind = .folder`).
    @discardableResult
    public func createFolder(name: String, parentID: Int64? = nil) async throws -> Playlist {
        try await self.createRow(name: name, kind: .folder, parentID: parentID)
    }

    /// Renames the playlist with `id`.
    public func rename(_ id: Int64, to name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PlaylistError.emptyName }
        _ = try await self.requireExisting(id: id)
        try await self.repo.updateName(id: id, name: trimmed, now: Self.now())
        self.log.debug("playlist.rename", ["id": id])
    }

    /// Deletes the playlist or folder with `id`.
    ///
    /// For folders, children whose `parent_id == id` are reparented to the
    /// folder's own parent (i.e. moved up one level) before the folder is
    /// deleted. Callers wanting the "delete folder and all its playlists"
    /// semantics should call `deleteFolderRecursively(_:)` instead.
    public func delete(_ id: Int64) async throws {
        let existing = try await self.requireExisting(id: id)
        if existing.kind == .folder {
            let newParent = existing.parentID
            let children = try await self.repo.fetchChildren(parentID: id)
            let now = Self.now()
            for child in children {
                guard let childID = child.id else { continue }
                try await self.repo.updateParent(id: childID, parentID: newParent, now: now)
            }
        }
        try await self.repo.delete(id: id)
        self.log.debug("playlist.delete", ["id": id, "kind": existing.kind.rawValue])
    }

    /// Deletes `id` and every descendant playlist/folder.
    public func deleteRecursively(_ id: Int64) async throws {
        let existing = try await self.requireExisting(id: id)
        let rows = try await self.fetchTreeRows()
        let descendants = PlaylistFolderTree.descendantIDs(of: id, rows: rows)
        for descendantID in descendants {
            try await self.repo.delete(id: descendantID)
        }
        try await self.repo.delete(id: id)
        self.log.debug(
            "playlist.delete.recursive",
            ["id": id, "kind": existing.kind.rawValue, "descendants": descendants.count]
        )
    }

    /// Duplicates the playlist with `id`.
    ///
    /// The copy keeps the same order, cover, and accent colour; its name is
    /// `"<original> copy"`. Folders cannot be duplicated (call the spec-level
    /// "duplicate folder" flow in a later phase if needed).
    @discardableResult
    public func duplicate(_ id: Int64) async throws -> Playlist {
        let source = try await self.requireExisting(id: id)
        guard source.kind != .folder else {
            throw PlaylistError.wrongKind(id: id, expected: "playlist", actual: "folder")
        }
        let now = Self.now()
        var copy = source
        copy.id = nil
        copy.name = "\(source.name) copy"
        copy.createdAt = now
        copy.updatedAt = now
        let newID = try await self.repo.insert(copy)
        copy.id = newID
        let membership = try await self.repo.fetchMembership(playlistID: id)
        if !membership.isEmpty {
            let positions = PositionArranger.repackedPositions(count: membership.count)
            let rows = zip(membership, positions).map { pair, position in
                PlaylistTrack(playlistID: newID, trackID: pair.trackID, position: position)
            }
            try await self.repo.insertRows(rows, in: newID)
        }
        self.log.debug("playlist.duplicate", ["from": id, "to": newID])
        return copy
    }

    /// Sets or clears the user cover art for `id` (path to a cached image).
    public func setCoverArtPath(_ id: Int64, path: String?) async throws {
        _ = try await self.requireExisting(id: id)
        try await self.repo.updateCoverArtPath(id: id, path: path, now: Self.now())
    }

    /// Sets or clears the accent colour for `id`.
    public func setAccentColor(_ id: Int64, hex: String?) async throws {
        _ = try await self.requireExisting(id: id)
        if let hex {
            guard Self.isValidHex(hex) else { throw PlaylistError.invalidAccentColor(hex) }
        }
        try await self.repo.updateAccentColor(id: id, hex: hex, now: Self.now())
    }

    /// Moves `id` under `parentID` (or to the root when `nil`).
    ///
    /// Throws `.cycleDetected` if `parentID` refers to `id` itself or to
    /// any of `id`'s descendants.
    public func move(_ id: Int64, toParent parentID: Int64?) async throws {
        let existing = try await self.requireExisting(id: id)
        if let parentID {
            _ = try await self.requireExisting(id: parentID)
        }
        let rows = try await self.fetchTreeRows()
        if PlaylistFolderTree.wouldCreateCycle(candidateID: id, newParentID: parentID, rows: rows) {
            throw PlaylistError.cycleDetected(id: id, newParent: parentID ?? -1)
        }
        try await self.repo.updateParent(id: id, parentID: parentID, now: Self.now())
        self.log.debug(
            "playlist.move",
            ["id": id, "parent": parentID ?? -1, "kind": existing.kind.rawValue]
        )
    }

    // MARK: - Membership

    /// Appends `trackIDs` to `playlistID` at `index` (or the end when `nil`).
    public func addTracks(_ trackIDs: [Int64], to playlistID: Int64, at index: Int? = nil) async throws {
        guard !trackIDs.isEmpty else { return }
        let playlist = try await self.requireExisting(id: playlistID)
        guard playlist.kind == .manual else {
            throw PlaylistError.wrongKind(id: playlistID, expected: "manual", actual: playlist.kind.rawValue)
        }
        var current = try await self.repo.fetchMembership(playlistID: playlistID)
        let destination = index ?? current.count
        let existingPositions = current.map(\.position)
        let insertion = PositionArranger.insertPositions(
            count: trackIDs.count,
            at: destination,
            in: existingPositions
        )
        if insertion.needsRepack {
            try await self.applyRepackInsert(
                playlistID: playlistID,
                currentOrder: current.map(\.trackID),
                newTrackIDs: trackIDs,
                at: destination
            )
        } else {
            let rows = zip(trackIDs, insertion.positions).map { trackID, position in
                PlaylistTrack(playlistID: playlistID, trackID: trackID, position: position)
            }
            try await self.repo.insertRows(rows, in: playlistID)
        }
        current = try await self.repo.fetchMembership(playlistID: playlistID)
        let rebuiltPositions = current.map(\.position)
        if PositionArranger.needsRepack(rebuiltPositions) {
            try await self.repack(playlistID: playlistID, membership: current)
        }
        try await self.repo.updateName(
            id: playlistID,
            name: playlist.name,
            now: Self.now()
        ) // touch updated_at
        self.log.debug("playlist.add", ["id": playlistID, "count": trackIDs.count])
    }

    /// Removes the rows at the given `positions` within `playlistID`.
    public func removeTracks(at positions: IndexSet, from playlistID: Int64) async throws {
        guard !positions.isEmpty else { return }
        let membership = try await self.repo.fetchMembership(playlistID: playlistID)
        let indices = positions.filter { $0 >= 0 && $0 < membership.count }
        let doomedPositions = indices.map { membership[$0].position }
        try await self.repo.removePositions(doomedPositions, from: playlistID)
        try await self.repo.updateName(
            id: playlistID,
            name: (self.repo.fetch(id: playlistID)).name,
            now: Self.now()
        )
        self.log.debug("playlist.remove", ["id": playlistID, "count": doomedPositions.count])
    }

    /// Moves rows within `playlistID` using SwiftUI `move` semantics.
    public func moveTracks(
        in playlistID: Int64,
        from source: IndexSet,
        to destination: Int
    ) async throws {
        let membership = try await self.repo.fetchMembership(playlistID: playlistID)
        guard !membership.isEmpty else { return }
        let reordered = PositionArranger.applyMove(
            membership,
            fromOffsets: source,
            toOffset: destination
        )
        let positions = PositionArranger.repackedPositions(count: reordered.count)
        let paired = zip(reordered, positions).map { row, pos in
            (trackID: row.trackID, position: pos)
        }
        try await self.repo.replaceMembership(playlistID: playlistID, ordered: paired)
        try await self.repo.updateName(
            id: playlistID,
            name: (self.repo.fetch(id: playlistID)).name,
            now: Self.now()
        )
        self.log.debug("playlist.move_tracks", ["id": playlistID, "count": source.count])
    }

    /// Removes every track from `playlistID`.
    public func clear(_ playlistID: Int64) async throws {
        _ = try await self.requireExisting(id: playlistID)
        try await self.repo.clearMembership(playlistID: playlistID)
        self.log.debug("playlist.clear", ["id": playlistID])
    }

    // MARK: - Queries

    /// Returns the forest of playlists and folders.
    public func list() async throws -> [PlaylistNode] {
        let rows = try await self.fetchTreeRows()
        return PlaylistFolderTree.buildTree(from: rows)
    }

    /// Returns the tracks of `playlistID` in positional order.
    public func tracks(in playlistID: Int64) async throws -> [Track] {
        try await self.repo.fetchTracks(playlistID: playlistID)
    }

    /// Returns a stream of `[Track]` that emits on every change to the
    /// `playlist_tracks` membership of `playlistID`.
    ///
    /// Uses `Database.observe(value:)` to follow any SQL change that
    /// touches the joined tables.
    public func observe(_ playlistID: Int64) async -> AsyncThrowingStream<[Track], Error> {
        await self.database.observe { grdb in
            try Track.fetchAll(
                grdb,
                sql: """
                SELECT tracks.* FROM tracks
                INNER JOIN playlist_tracks ON playlist_tracks.track_id = tracks.id
                WHERE playlist_tracks.playlist_id = ?
                ORDER BY playlist_tracks.position
                """,
                arguments: [playlistID]
            )
        }
    }

    // MARK: - Private helpers

    private func createRow(name: String, kind: PlaylistKind, parentID: Int64?) async throws -> Playlist {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PlaylistError.emptyName }
        if let parentID {
            let parent = try await self.requireExisting(id: parentID)
            guard parent.kind == .folder else {
                throw PlaylistError.wrongKind(id: parentID, expected: "folder", actual: parent.kind.rawValue)
            }
        }
        let now = Self.now()
        var playlist = Playlist(
            name: trimmed,
            isSmart: kind == .smart,
            createdAt: now,
            updatedAt: now,
            parentID: parentID,
            kind: kind
        )
        let id = try await self.repo.insert(playlist)
        playlist.id = id
        self.log.debug("playlist.create", ["id": id, "kind": kind.rawValue])
        return playlist
    }

    private func requireExisting(id: Int64) async throws -> Playlist {
        do {
            return try await self.repo.fetch(id: id)
        } catch {
            throw PlaylistError.notFound(id)
        }
    }

    private func fetchTreeRows() async throws -> [PlaylistFolderTree.Row] {
        let playlists = try await self.repo.fetchAll()
        var rows: [PlaylistFolderTree.Row] = []
        rows.reserveCapacity(playlists.count)
        for playlist in playlists {
            guard let id = playlist.id else { continue }
            let trackCount: Int
            let totalDuration: TimeInterval
            if playlist.kind == .manual {
                // Smart playlists never store membership in playlist_tracks,
                // so trackCount and totalDuration are always 0 for them.
                trackCount = try await self.repo.trackCount(playlistID: id)
                totalDuration = try await self.repo.totalDuration(playlistID: id)
            } else {
                trackCount = 0
                totalDuration = 0
            }
            rows.append(
                PlaylistFolderTree.Row(
                    id: id,
                    name: playlist.name,
                    kind: playlist.kind,
                    parentID: playlist.parentID,
                    coverArtPath: playlist.coverArtPath,
                    accentHex: playlist.accentColor,
                    trackCount: trackCount,
                    totalDuration: totalDuration,
                    sortOrder: playlist.sortOrder
                )
            )
        }
        return rows
    }

    private func applyRepackInsert(
        playlistID: Int64,
        currentOrder: [Int64],
        newTrackIDs: [Int64],
        at index: Int
    ) async throws {
        var merged = currentOrder
        let clamped = max(0, min(index, merged.count))
        merged.insert(contentsOf: newTrackIDs, at: clamped)
        let positions = PositionArranger.repackedPositions(count: merged.count)
        let ordered = zip(merged, positions).map { id, pos in
            (trackID: id, position: pos)
        }
        try await self.repo.replaceMembership(playlistID: playlistID, ordered: ordered)
    }

    private func repack(
        playlistID: Int64,
        membership: [(trackID: Int64, position: Int)]
    ) async throws {
        let positions = PositionArranger.repackedPositions(count: membership.count)
        let rebuilt = zip(membership, positions).map { row, pos in
            (trackID: row.trackID, position: pos)
        }
        try await self.repo.replaceMembership(playlistID: playlistID, ordered: rebuilt)
        self.log.debug("playlist.repack", ["id": playlistID, "count": membership.count])
    }

    // MARK: - Utilities

    private static func now() -> Int64 {
        Int64(Date().timeIntervalSince1970)
    }

    private static func isValidHex(_ hex: String) -> Bool {
        // Accept "#RRGGBB" with optional leading "#".
        let stripped = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard stripped.count == 6 else { return false }
        return stripped.allSatisfy(\.isHexDigit)
    }
}
