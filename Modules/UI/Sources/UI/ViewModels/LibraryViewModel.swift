import AudioEngine
import Foundation
import Observability
import Persistence

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
    /// Phase 5 will replace this with `QueuePlayer.playNow(_:)`.
    public func play(track: Track) async {
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

        case let .genre(g):
            await self.tracks.load(genre: g)

        case let .composer(c):
            await self.tracks.load(composer: c)

        case .playlist, .smartPlaylist:
            // TODO(phase-6): wire playlist loading
            break

        case let .search(q):
            self.search.query = q
            self.search.queryChanged()
        }
    }
}
