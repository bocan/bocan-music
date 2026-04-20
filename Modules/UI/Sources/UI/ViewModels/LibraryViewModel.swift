import AppKit
import AudioEngine
import Combine
import Foundation
import Library
import Observability
import Persistence
import Playback
import UniformTypeIdentifiers

// MARK: - UIStateV1

/// Serialised sidebar + table UI state persisted to `settings` key `ui.state.v1`.
struct UIStateV1: Codable {
    var selectedDestination: SidebarDestination = .songs
    var sortColumn: TrackSortColumn = .addedAt
    var sortAscending = false
}

// MARK: - LibraryViewModel

/// Root view-model that owns all child view-models and wires the play action.
///
/// Injected into `RootView` via the environment and passed down to child views.
@MainActor
public final class LibraryViewModel: ObservableObject {
    // MARK: - Published state

    @Published public var selectedDestination: SidebarDestination = .songs
    @Published public var searchQuery = ""

    // MARK: - Inspector state

    /// The track currently shown in the Inspector panel (`⌘I`).
    /// `nil` when the panel is closed or no selection exists.
    @Published public var inspectorTrack: Track?

    // MARK: - Error state

    /// Set when playback fails; cleared when the user dismisses the alert.
    @Published public var playbackErrorMessage: String?

    // MARK: - Scan state

    @Published public var isScanning = false
    @Published public var scanWalked = 0
    @Published public var scanInserted = 0
    @Published public var scanUpdated = 0
    @Published public var scanCurrentPath = ""
    @Published public var scanSummary: ScanProgress.Summary?
    @Published public var libraryRoots: [LibraryRoot] = []
    @Published public var isDragTargeted = false

    // MARK: - Child view-models

    public let tracks: TracksViewModel
    public let albums: AlbumsViewModel
    public let artists: ArtistsViewModel
    public let nowPlaying: NowPlayingViewModel

    // MARK: - Dependencies

    public let database: Database
    private let engine: any Transport
    private let settingsRepo: SettingsRepository
    let albumRepo: AlbumRepository
    let scanner: LibraryScanner?
    var scanTask: Task<Void, Never>?
    private var searchQueryCancellable: AnyCancellable?
    let log = AppLogger.make(.ui)

    // MARK: - Init

    public init(database: Database, engine: any Transport, scanner: LibraryScanner? = nil) {
        self.database = database
        self.engine = engine
        self.scanner = scanner
        self.settingsRepo = SettingsRepository(database: database)

        let trackRepo = TrackRepository(database: database)
        let albumRepo = AlbumRepository(database: database)
        let artistRepo = ArtistRepository(database: database)
        self.albumRepo = albumRepo

        self.tracks = TracksViewModel(
            repository: trackRepo,
            artistRepository: artistRepo,
            albumRepository: albumRepo
        )
        self.albums = AlbumsViewModel(repository: albumRepo)
        self.artists = ArtistsViewModel(repository: artistRepo)
        self.nowPlaying = NowPlayingViewModel(engine: engine, database: database)

        // React to search query changes: debounce 250 ms, then reload the current
        // destination with filtered data.  Clearing the query restores the full list.
        self.searchQueryCancellable = self.$searchQuery
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self else { return }
                Task { await self.loadCurrentDestination() }
            }

        // Wire the NowPlayingStrip play button to start from the library when the
        // queue is empty.
        self.nowPlaying.onPlayFromEmptyQueue = { [weak self] in
            guard let self else { return }
            Task { await self.playCurrentLibrary() }
        }
    }

    // MARK: - Public API

    /// Loads data for the current destination.
    public func loadCurrentDestination() async {
        await self.loadDestination(self.selectedDestination)
    }

    /// Responds to a sidebar selection change.
    public func selectDestination(_ destination: SidebarDestination) async {
        // Clear search when drilling into a detail page (album or artist).
        // For top-level browse views (songs/albums/artists/etc) keep the active
        // query so the new view shows filtered results immediately.
        switch destination {
        case .album, .artist:
            self.searchQuery = ""

        default:
            break
        }
        self.selectedDestination = destination
        await self.loadDestination(destination)
    }

    /// Plays `track` immediately, replacing the queue with the full current track
    /// list so that auto-advance, shuffle, and the forward button all work as expected.
    ///
    /// Called by TracksView / AlbumDetailView on double-click or Return key.
    public func play(track: Track) async {
        // Ensure the track list is populated.
        if self.tracks.tracks.isEmpty {
            await self.loadCurrentDestination()
        }
        // Build the full context list.  Fall back to just this track if context is empty.
        let contextTracks = self.tracks.tracks.isEmpty ? [track] : self.tracks.tracks
        let startIndex = contextTracks.firstIndex { $0.id == track.id } ?? 0
        if let qp = engine as? QueuePlayer {
            do {
                // Build items in-memory from the already-loaded Track objects and
                // artistNames dictionary.  This avoids the per-track DB round-trips
                // inside QueuePlayer.buildItems (32k queries for a 16k library) which
                // otherwise cause a multi-second stall before playback begins.
                let names = self.tracks.artistNames
                let items: [QueueItem] = contextTracks.map { t in
                    let name = t.artistID.flatMap { names[$0] }
                    return QueueItem.make(from: t, artistName: name)
                }
                try await qp.play(items: items, startingAt: startIndex)
            } catch {
                self.log.error("library.play.failed", ["error": String(reflecting: error)])
                self.playbackErrorMessage = "Could not play \"\(track.title ?? track.fileURL)\". Try re-scanning your library."
            }
            return
        }
        guard let url = URL(string: track.fileURL) else {
            self.log.error("library.play.badURL", ["url": track.fileURL])
            return
        }
        do {
            self.nowPlaying.setCurrentTrack(track)
            try await self.engine.load(url)
            try await self.engine.play()
            self.log.debug("library.play", ["id": track.id ?? -1])
        } catch {
            self.log.error("library.play.failed", ["error": String(reflecting: error)])
        }
    }

    /// Plays `tracks` starting at `index`, replacing the queue.
    public func play(tracks: [Track], startingAt index: Int = 0) async {
        guard let qp = engine as? QueuePlayer else { return }
        let names = self.tracks.artistNames
        let items: [QueueItem] = tracks.map { t in
            let name = t.artistID.flatMap { names[$0] }
            return QueueItem.make(from: t, artistName: name)
        }
        do {
            try await qp.play(items: items, startingAt: index)
        } catch {
            self.log.error("library.playAll.failed", ["error": String(reflecting: error)])
            self.playbackErrorMessage = "Could not play tracks. Try re-scanning your library."
        }
    }

    /// Starts playing all tracks in the current Songs view from the beginning,
    /// honouring the current sort order.  Called when the play button is pressed
    /// with an empty queue (nothing ever loaded, or queue exhausted).
    public func playCurrentLibrary() async {
        // Ensure the track list is populated — it may be empty on fast startup
        // if the view's .task hasn't completed before the play button is pressed.
        if self.tracks.tracks.isEmpty {
            await self.loadCurrentDestination()
        }
        guard !self.tracks.tracks.isEmpty else { return }
        await self.play(tracks: self.tracks.tracks, startingAt: 0)
    }

    /// Inserts `tracks` to play immediately after the current item.
    public func playNext(tracks: [Track]) async {
        guard let qp = engine as? QueuePlayer else { return }
        let ids = tracks.compactMap(\.id)
        do {
            try await qp.playNext(ids)
        } catch {
            self.log.error("library.playNext.failed", ["error": String(reflecting: error)])
        }
    }

    /// Appends `tracks` to the end of the queue.
    public func addToQueue(tracks: [Track]) async {
        guard let qp = engine as? QueuePlayer else { return }
        let ids = tracks.compactMap(\.id)
        do {
            try await qp.addToQueue(ids)
        } catch {
            self.log.error("library.addToQueue.failed", ["error": String(reflecting: error)])
        }
    }

    /// Plays all tracks from the album of `track`.
    public func playAlbum(track: Track, shuffle: Bool = false) async {
        guard let qp = engine as? QueuePlayer, let albumID = track.albumID else { return }
        do {
            try await qp.playAlbum(albumID, shuffle: shuffle)
        } catch {
            self.log.error("library.playAlbum.failed", ["error": String(reflecting: error)])
            self.playbackErrorMessage = "Could not play album."
        }
    }

    /// Plays all tracks by the artist of `track`.
    public func playArtist(track: Track) async {
        guard let qp = engine as? QueuePlayer, let artistID = track.artistID else { return }
        do {
            try await qp.playArtist(artistID)
        } catch {
            self.log.error("library.playArtist.failed", ["error": String(reflecting: error)])
            self.playbackErrorMessage = "Could not play artist."
        }
    }

    /// Toggles shuffle on the queue player.
    public func setShuffle(_ on: Bool) async {
        guard let qp = engine as? QueuePlayer else { return }
        await qp.setShuffle(on)
    }

    /// Reorders the playback queue to match the current track-list sort order,
    /// keeping the currently-playing track in place.
    public func reorderQueue() async {
        guard let qp = engine as? QueuePlayer else { return }
        let contextTracks = self.tracks.tracks
        guard !contextTracks.isEmpty else { return }
        let names = self.tracks.artistNames
        let items: [QueueItem] = contextTracks.map { t in
            let name = t.artistID.flatMap { names[$0] }
            return QueueItem.make(from: t, artistName: name)
        }
        await qp.queue.reorder(to: items)
    }

    /// Changes the repeat mode on the queue player.
    public func setRepeat(_ mode: RepeatMode) async {
        guard let qp = engine as? QueuePlayer else { return }
        await qp.setRepeat(mode)
    }

    /// The underlying `QueuePlayer` if the engine is one; otherwise `nil`.
    public var queuePlayer: QueuePlayer? {
        self.engine as? QueuePlayer
    }

    /// Persists current UI state to settings.
    public func saveUIState() async {
        let state = UIStateV1(
            selectedDestination: selectedDestination,
            sortColumn: tracks.sortColumn,
            sortAscending: self.tracks.sortAscending
        )
        do {
            try await self.settingsRepo.set(state, for: "ui.state.v1")
        } catch {
            self.log.error("library.saveState.failed", ["error": String(reflecting: error)])
        }
    }

    /// Restores UI state from settings.
    public func restoreUIState() async {
        do {
            guard let state = try await settingsRepo.get(UIStateV1.self, for: "ui.state.v1") else { return }
            self.selectedDestination = state.selectedDestination
            self.tracks.setSort(column: state.sortColumn, ascending: state.sortAscending)
        } catch {
            self.log.error("library.restoreState.failed", ["error": String(reflecting: error)])
        }
    }

    // MARK: - Inspector

    /// Sets `inspectorTrack` to the first track in `tracks` and triggers the
    /// inspector window to open (via the `@Environment(\.openWindow)` binding
    /// set by `RootView`).
    public func showInspector(tracks: [Track]) {
        self.inspectorTrack = tracks.first
        self.openInspectorWindow?()
    }

    /// Injected by `RootView` after `@Environment(\.openWindow)` is available.
    public var openInspectorWindow: (() -> Void)?
}
