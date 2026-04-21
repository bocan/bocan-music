import Foundation
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
    private let log = AppLogger.make(.ui)
    private var loadedID: Int64?

    // MARK: - Init

    public init(service: PlaylistService, database: Database) {
        self.service = service
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
