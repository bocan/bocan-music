import AppKit
import Foundation
import GRDB
import Library
import Observability
import Persistence

// MARK: - PlaylistDetailViewModel

/// Drives the playlist detail pane: header, ordered tracks, reorder, and membership edits.
@MainActor
public final class PlaylistDetailViewModel: ObservableObject {
    // MARK: - Published state

    @Published public private(set) var playlist: Playlist?
    @Published public private(set) var tracks: [Track] = []
    @Published public private(set) var isLoading = false
    @Published public var selection: Set<Track.ID> = []
    @Published public var lastError: String?
    /// Auto-generated 2×2 mosaic of the first four distinct album covers.
    /// `nil` when the playlist has a user-set cover or when no tracks have art.
    @Published public private(set) var mosaicImage: NSImage?

    // MARK: - Computed

    public var title: String {
        self.playlist?.name ?? ""
    }

    public var trackCount: Int {
        self.tracks.count
    }

    public var totalDuration: TimeInterval {
        self.tracks.reduce(0) { $0 + $1.duration }
    }

    // MARK: - Dependencies

    private let service: PlaylistService
    private let playlistRepository: PlaylistRepository
    private let database: Persistence.Database
    private let log = AppLogger.make(.ui)
    private var loadedID: Int64?
    private var mosaicTask: Task<Void, Never>?

    // MARK: - Init

    public init(service: PlaylistService, database: Persistence.Database) {
        self.service = service
        self.database = database
        self.playlistRepository = PlaylistRepository(database: database)
    }

    // MARK: - Public API

    public func load(playlistID: Int64) async {
        self.loadedID = playlistID
        self.isLoading = true
        do {
            self.playlist = try await self.playlistRepository.fetch(id: playlistID)
            self.tracks = try await self.service.tracks(in: playlistID)
        } catch {
            self.log.error("playlist.detail.load.failed", ["error": String(reflecting: error)])
            self.lastError = "Could not load playlist."
        }
        self.isLoading = false
        self.scheduleMosaicCompute()
    }

    // MARK: - Mosaic

    /// Cancels any in-flight mosaic computation and schedules a fresh one
    /// after a 500 ms debounce.  Skips computation when the playlist already
    /// has a user-set cover (mosaicImage stays `nil` so the user cover wins).
    private func scheduleMosaicCompute() {
        self.mosaicTask?.cancel()
        self.mosaicImage = nil
        guard self.playlist?.coverArtPath == nil else { return }
        let trackIDs: [Int64] = self.tracks.compactMap(\.id)
        guard !trackIDs.isEmpty else { return }
        let updatedAt = self.playlist?.updatedAt ?? 0
        let db = self.database
        self.mosaicTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            let paths = await (try? Self.fetchCoverPaths(trackIDs: trackIDs, database: db)) ?? []
            guard !Task.isCancelled, !paths.isEmpty else { return }
            let img = await PlaylistMosaicGenerator.shared.mosaic(
                paths: paths,
                updatedAt: updatedAt
            )
            guard !Task.isCancelled else { return }
            self.mosaicImage = img
        }
    }

    /// Returns up to 4 distinct cover-art file paths for tracks with IDs in `trackIDs`,
    /// ordered by first appearance in the playlist.
    private static func fetchCoverPaths(
        trackIDs: [Int64],
        database: Persistence.Database
    ) async throws -> [String] {
        guard !trackIDs.isEmpty else { return [] }
        return try await database.read { grdb in
            // Use the album cover-art path (denormalised on albums row) for the
            // first 4 distinct albums present in the playlist.
            let placeholders = trackIDs.map { _ in "?" }.joined(separator: ",")
            let sql = """
            SELECT DISTINCT a.cover_art_path
            FROM albums a
            INNER JOIN tracks t ON t.album_id = a.id
            WHERE t.id IN (\(placeholders))
            AND a.cover_art_path IS NOT NULL
            LIMIT 4
            """
            let args = StatementArguments(trackIDs.map { DatabaseValue(value: $0) })
            return try String.fetchAll(grdb, sql: sql, arguments: args)
        }
    }

    /// Reloads using the last loaded ID (no-op if nothing loaded).
    public func reload() async {
        guard let id = loadedID else { return }
        await self.load(playlistID: id)
    }

    public func rename(to name: String) async {
        guard let id = loadedID else { return }
        do {
            try await self.service.rename(id, to: name)
            await self.reload()
        } catch {
            self.lastError = String(describing: error)
        }
    }

    public func move(from source: IndexSet, to destination: Int) async {
        guard let id = loadedID else { return }
        // Optimistic update for snappy drag feedback.
        let preview = PositionArranger.applyMove(self.tracks, fromOffsets: source, toOffset: destination)
        self.tracks = preview
        do {
            try await self.service.moveTracks(in: id, from: source, to: destination)
        } catch {
            self.lastError = String(describing: error)
            await self.reload()
        }
    }

    public func remove(at offsets: IndexSet) async {
        guard let id = loadedID else { return }
        // Optimistic remove.
        var copy = self.tracks
        for index in offsets.sorted(by: >) where index < copy.count {
            copy.remove(at: index)
        }
        self.tracks = copy
        do {
            try await self.service.removeTracks(at: offsets, from: id)
        } catch {
            self.lastError = String(describing: error)
            await self.reload()
        }
    }

    public func removeSelected() async {
        guard !self.selection.isEmpty else { return }
        var offsets = IndexSet()
        for (index, track) in self.tracks.enumerated()
            where track.id.map({ self.selection.contains($0) }) == true {
            offsets.insert(index)
        }
        self.selection.removeAll()
        await self.remove(at: offsets)
    }

    public func addTracks(_ ids: [Int64], at index: Int? = nil) async {
        guard let pid = loadedID else { return }
        do {
            try await self.service.addTracks(ids, to: pid, at: index)
            await self.reload()
        } catch {
            self.lastError = String(describing: error)
        }
    }
}
