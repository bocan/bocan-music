import Foundation
import Library
import Observability
import Persistence

// MARK: - SmartPlaylistDetailViewModel

/// Drives the smart playlist detail pane.
///
/// Fires a live observation when `liveUpdate` is true, otherwise loads once.
@MainActor
public final class SmartPlaylistDetailViewModel: ObservableObject {
    // MARK: - Published state

    @Published public private(set) var playlist: Playlist?
    @Published public private(set) var smartPlaylist: SmartPlaylist?
    @Published public private(set) var tracks: [Track] = []
    @Published public private(set) var isLoading = false
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

    public var lastSnapshottedAt: Int64? {
        self.playlist?.smartLastSnapshotAt
    }

    // MARK: - Dependencies

    private let service: SmartPlaylistService
    private var observationTask: Task<Void, Never>?
    private let log = AppLogger.make(.ui)

    // MARK: - Init

    public init(service: SmartPlaylistService) {
        self.service = service
    }

    deinit {
        self.observationTask?.cancel()
    }

    // MARK: - Public API

    public func load(playlistID: Int64) async {
        self.observationTask?.cancel()
        self.observationTask = nil
        self.isLoading = true
        self.lastError = nil

        do {
            let sp = try await self.service.resolve(id: playlistID)
            self.smartPlaylist = sp
            self.playlist = sp.playlist

            if sp.limitSort.liveUpdate {
                self.isLoading = false
                self.startObservation(playlistID: playlistID)
            } else {
                // Snapshot mode is intentionally non-live: read once from
                // `playlist_tracks` and do not subscribe to updates.
                self.tracks = try await self.service.tracks(for: playlistID)
                self.isLoading = false
            }
        } catch {
            self.log.error("smartPlaylist.detail.load.failed", ["error": String(reflecting: error)])
            self.lastError = "Could not load smart playlist."
            self.isLoading = false
        }
    }

    /// Re-runs the smart playlist's query and atomically replaces the
    /// persisted `playlist_tracks` snapshot. Only meaningful for non-live
    /// playlists; live playlists update automatically.
    public func refresh() async {
        guard let id = self.playlist?.id else { return }
        do {
            _ = try await self.service.snapshot(playlistID: id)
            let refreshed = try await self.service.resolve(id: id)
            self.smartPlaylist = refreshed
            self.playlist = refreshed.playlist
            self.tracks = try await self.service.tracks(for: id)
        } catch {
            self.log.error("smartPlaylist.refresh.failed", ["error": String(reflecting: error)])
            self.lastError = "Could not refresh playlist."
        }
    }

    public var isLive: Bool {
        self.smartPlaylist?.limitSort.liveUpdate ?? true
    }

    // MARK: - Private

    private func startObservation(playlistID: Int64) {
        self.observationTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await newTracks in await self.service.observe(playlistID) {
                    await MainActor.run {
                        self.tracks = newTracks
                    }
                }
            } catch {
                await MainActor.run {
                    // Task cancellation is normal when the view dismisses — don't report it as an error.
                    guard !(error is CancellationError) else { return }
                    self.log.error("smartPlaylist.observe.failed", ["error": String(reflecting: error)])
                    self.lastError = "Live updates unavailable."
                }
            }
        }
    }
}
