import AudioEngine
import Foundation
import Observability
import Persistence
import Playback

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

    // MARK: - Child view-models

    public let tracks: TracksViewModel
    public let albums: AlbumsViewModel
    public let artists: ArtistsViewModel
    public let search: SearchViewModel
    public let nowPlaying: NowPlayingViewModel

    // MARK: - Dependencies

    public let database: Database
    private let engine: any Transport
    private let settingsRepo: SettingsRepository
    private let log = AppLogger.make(.ui)

    // MARK: - Init

    public init(database: Database, engine: any Transport) {
        self.database = database
        self.engine = engine
        self.settingsRepo = SettingsRepository(database: database)

        let trackRepo = TrackRepository(database: database)
        let albumRepo = AlbumRepository(database: database)
        let artistRepo = ArtistRepository(database: database)

        self.tracks = TracksViewModel(repository: trackRepo)
        self.albums = AlbumsViewModel(repository: albumRepo)
        self.artists = ArtistsViewModel(repository: artistRepo)
        self.search = SearchViewModel(
            trackRepo: trackRepo,
            albumRepo: albumRepo,
            artistRepo: artistRepo
        )
        self.nowPlaying = NowPlayingViewModel(engine: engine, database: database)
    }

    // MARK: - Public API

    /// Loads data for the current destination.
    public func loadCurrentDestination() async {
        await self.loadDestination(self.selectedDestination)
    }

    /// Responds to a sidebar selection change.
    public func selectDestination(_ destination: SidebarDestination) async {
        self.selectedDestination = destination
        await self.loadDestination(destination)
    }

    /// Plays `track` immediately via the engine.
    ///
    /// Called by TracksView / AlbumDetailView on double-click or Return key.
    public func play(track: Track) async {
        // Prefer QueuePlayer's proper queue-based playback if available.
        if let qp = engine as? QueuePlayer, let id = track.id {
            do {
                try await qp.play(trackIDs: [id], startingAt: 0)
            } catch {
                self.log.error("library.play.failed", ["error": String(reflecting: error)])
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
        let ids = tracks.compactMap(\.id)
        do {
            try await qp.play(trackIDs: ids, startingAt: index)
        } catch {
            self.log.error("library.playAll.failed", ["error": String(reflecting: error)])
        }
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

    /// Toggles shuffle on the queue player.
    public func setShuffle(_ on: Bool) async {
        guard let qp = engine as? QueuePlayer else { return }
        await qp.setShuffle(on)
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

    // MARK: - Private

    private func loadDestination(_ destination: SidebarDestination) async {
        switch destination {
        case .songs:
            await self.tracks.load()

        case .albums:
            await self.albums.load()

        case .artists:
            await self.artists.load()

        case .genres, .composers:
            await self.tracks.load()

        case .recentlyAdded:
            let trackRepo = TrackRepository(database: database)
            let result = await (try? trackRepo.recentlyAdded()) ?? []
            self.tracks.setTracks(result)

        case .recentlyPlayed:
            let trackRepo = TrackRepository(database: database)
            let result = await (try? trackRepo.recentlyPlayed()) ?? []
            self.tracks.setTracks(result)

        case .mostPlayed:
            let trackRepo = TrackRepository(database: database)
            let result = await (try? trackRepo.mostPlayed()) ?? []
            self.tracks.setTracks(result)

        case let .artist(id):
            await self.artists.load()
            await self.tracks.load(artistID: id)
            await self.albums.load(albumArtistID: id)

        case let .album(id):
            await self.tracks.load(albumID: id)

        case let .genre(genre):
            await self.tracks.load(genre: genre)

        case let .composer(c):
            await self.tracks.load(composer: c)

        case .playlist, .smartPlaylist:
            // TODO(phase-6): wire playlist loading
            break

        case .upNext:
            break // QueueView reads directly from QueuePlayer.queue

        case let .search(searchQuery):
            self.search.query = searchQuery
            self.search.queryChanged()
        }
    }
}
