// swiftlint:disable file_length
import Acoustics
import AppKit
import AudioEngine
import Combine
import Foundation
import Library
import Observability
import Persistence
import Playback
import UniformTypeIdentifiers

// MARK: - UIStateV2

/// Serialised sidebar + table UI state persisted to `settings` key `ui.state.v2`.
///
/// Phase 4 audit H2: `sidebarWidth` is persisted here as a fallback for the
/// AppKit autosave name set on `NSSplitView` — autosave covers the common
/// case (window restore on relaunch); the explicit value lets us seed a
/// freshly-installed window or a profile copied between machines.
struct UIStateV2: Codable {
    var selectedDestination: SidebarDestination = .songs
    var sortColumn: TrackSortColumn = .artist
    var sortAscending = true
    /// Width of the navigation split-view's sidebar column, in points.
    /// `nil` when no width has been recorded yet (first launch).
    var sidebarWidth: Double?
    /// Persisted IDs of expanded playlist folders in the sidebar tree.
    var expandedPlaylistFolders: Set<Int64> = []

    private enum CodingKeys: String, CodingKey {
        case selectedDestination
        case sortColumn
        case sortAscending
        case sidebarWidth
        case expandedPlaylistFolders
    }

    init(
        selectedDestination: SidebarDestination = .songs,
        sortColumn: TrackSortColumn = .artist,
        sortAscending: Bool = true,
        sidebarWidth: Double? = nil,
        expandedPlaylistFolders: Set<Int64> = []
    ) {
        self.selectedDestination = selectedDestination
        self.sortColumn = sortColumn
        self.sortAscending = sortAscending
        self.sidebarWidth = sidebarWidth
        self.expandedPlaylistFolders = expandedPlaylistFolders
    }

    /// Forward-compatible decoder for old payloads (V1) that do not include
    /// `expandedPlaylistFolders`.
    init(from decoder: any Swift.Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.selectedDestination = try c.decode(SidebarDestination.self, forKey: .selectedDestination)
        self.sortColumn = try c.decode(TrackSortColumn.self, forKey: .sortColumn)
        self.sortAscending = try c.decode(Bool.self, forKey: .sortAscending)
        self.sidebarWidth = try c.decodeIfPresent(Double.self, forKey: .sidebarWidth)
        self.expandedPlaylistFolders = try c.decodeIfPresent(Set<Int64>.self, forKey: .expandedPlaylistFolders) ?? []
    }
}

// MARK: - LibraryViewModel

/// Root view-model that owns all child view-models and wires the play action.
///
/// Injected into `RootView` via the environment and passed down to child views.
@MainActor
public final class LibraryViewModel: ObservableObject { // swiftlint:disable:this type_body_length
    // MARK: - Published state

    @Published public var selectedDestination: SidebarDestination = .songs
    @Published public var searchQuery = ""

    // MARK: - Navigation history

    @Published public private(set) var canGoBack = false
    @Published public private(set) var canGoForward = false
    private var backStack: [SidebarDestination] = []
    private var forwardStack: [SidebarDestination] = []
    private static let historyLimit = 50

    // MARK: - Tag editor state

    /// Non-nil when the tag editor sheet should be presented.
    @Published public var tagEditorTrackIDs: [Int64]?
    /// `true` when at least one track is selected in the current track table.
    @Published public var hasTrackSelection = false
    /// `true` when exactly one track is selected — enables the "Identify Track…" toolbar button.
    @Published public var hasSingleTrackSelection = false
    /// Shared `MetadataEditService` (nil only if the backup directory is unavailable).
    public let metadataEditService: MetadataEditService?

    // MARK: - Identify track state

    /// Non-nil when the identify-track sheet should be shown.
    @Published public var identifyTrack: Track?
    /// Shared queue for acoustic identification requests.
    public let fingerprintQueue: FingerprintQueue?

    // MARK: - Error state

    /// Set when playback fails; cleared when the user dismisses the alert.
    @Published public var playbackErrorMessage: String?

    /// Set when a single-track re-scan fails so the UI can surface a sheet
    /// distinct from the playback-error alert. Cleared when the user
    /// dismisses the alert.
    @Published public var rescanErrorMessage: String?

    // MARK: - Lightweight toast surface

    /// Transient confirmation toast (e.g. "Re-scanned «Title»"). Auto-cleared
    /// after a short delay by ``showToast(_:)``.
    @Published public var toast: ToastMessage?

    /// Identifier for an inflight toast-dismiss task so a newer toast can
    /// cancel the auto-dismiss for a stale one.
    private var toastDismissID = UUID()

    /// Shows a toast and auto-clears it after 2 seconds. Calling again before
    /// the timer fires replaces the toast and resets the timer.
    public func showToast(_ message: ToastMessage) {
        let token = UUID()
        self.toastDismissID = token
        self.toast = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.toastDismissID == token else { return }
            self.toast = nil
        }
    }

    // MARK: - ReplayGain analysis state

    /// Non-nil while a batch ReplayGain analysis is running.
    @Published public var replayGainProgress: ReplayGainBatchProgress?

    // MARK: - Scan state

    @Published public var isScanning = false
    @Published public var scanWalked = 0
    @Published public var scanInserted = 0
    @Published public var scanUpdated = 0
    @Published public var scanCurrentPath = ""
    @Published public var scanSummary: ScanProgress.Summary?
    @Published public var libraryRoots: [LibraryRoot] = []
    @Published public var isDragTargeted = false

    // MARK: - Playlist import/export sheet flags

    @Published public var isPlaylistImportSheetPresented = false
    @Published public var playlistExportRequest: PlaylistExportRequest?

    // MARK: - Tools sheet flags

    /// Set to `true` to present the "Fetch Missing Cover Art" progress sheet.
    @Published public var isBatchCoverArtSheetPresented = false

    /// Set to `true` to present the "Find Duplicates" review sheet.
    @Published public var isDuplicateReviewSheetPresented = false

    /// Presents the batch cover-art fetch sheet.
    public func showBatchCoverArt() {
        self.isBatchCoverArtSheetPresented = true
    }

    /// Presents the duplicate-track review sheet.
    public func showDuplicateReview() {
        self.isDuplicateReviewSheetPresented = true
    }

    public struct PlaylistExportRequest: Identifiable, Equatable {
        public let id: Int64
        public let name: String
    }

    // MARK: - Child view-models

    public let tracks: TracksViewModel
    public let albums: AlbumsViewModel
    public let artists: ArtistsViewModel
    public let nowPlaying: NowPlayingViewModel
    public let playlistSidebar: PlaylistSidebarViewModel
    public let playlistService: PlaylistService
    public let smartPlaylistService: SmartPlaylistService
    public let playlistImporter: PlaylistImportService
    public let playlistExporter: PlaylistExportService

    // MARK: - Dependencies

    public let database: Database
    private let engine: any Transport
    private let settingsRepo: SettingsRepository
    let albumRepo: AlbumRepository
    let artistRepo: ArtistRepository
    let scanner: LibraryScanner?
    var scanTask: Task<Void, Never>?
    /// Phase 5.5 audit L2: scan progress is coalesced into these "pending"
    /// counters and flushed to the `@Published` properties at ~4 Hz so a
    /// 50k-file scan doesn't drown the main actor in objectWillChange ticks
    /// while audio is playing.
    var pendingScanWalked = 0
    var pendingScanInserted = 0
    var pendingScanUpdated = 0
    var pendingScanCurrentPath = ""
    var scanFlushTask: Task<Void, Never>?
    private var searchQueryCancellable: AnyCancellable?
    private var expandedFoldersCancellable: AnyCancellable?
    let log = AppLogger.make(.ui)

    // MARK: - Init

    public init(database: Database, engine: any Transport, scanner: LibraryScanner? = nil) {
        self.database = database
        self.engine = engine
        self.scanner = scanner
        self.settingsRepo = SettingsRepository(database: database)
        self.metadataEditService = try? MetadataEditService(database: database)

        self.fingerprintQueue = Self.makeFingerprintQueue(database: database)

        let trackRepo = TrackRepository(database: database)
        let albumRepo = AlbumRepository(database: database)
        let artistRepo = ArtistRepository(database: database)
        self.albumRepo = albumRepo
        self.artistRepo = artistRepo

        self.tracks = TracksViewModel(
            repository: trackRepo,
            artistRepository: artistRepo,
            albumRepository: albumRepo
        )
        self.albums = AlbumsViewModel(repository: albumRepo)
        let playlistService = PlaylistService(database: database)
        self.playlistService = playlistService
        self.playlistSidebar = PlaylistSidebarViewModel(service: playlistService)
        self.smartPlaylistService = SmartPlaylistService(database: database)
        let (importer, exporter) = Self.makePlaylistIO(
            database: database,
            trackRepo: trackRepo,
            playlistService: playlistService
        )
        self.playlistImporter = importer
        self.playlistExporter = exporter
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

        self.wirePlaylistCallbacks()

        // Seed built-in smart presets on first run (idempotent), then reload
        // the sidebar so presets appear even if the initial load raced ahead.
        let sps = self.smartPlaylistService
        Task {
            try? await BuiltInSmartPresets.seed(using: sps)
            await self.playlistSidebar.reload()
        }

        self.observeTracksSelection()
        self.wireExpandedFoldersPersistence()
    }

    /// Bridges `TracksViewModel` (`@Observable`) selection state into the
    /// `@Published` properties that `ObservableObject` consumers depend on.
    ///
    /// Uses a recursive `withObservationTracking` loop: the `apply` closure
    /// both reads `tracks.selection` (registering the dependency) and writes
    /// the derived `@Published` flags; `onChange` re-schedules the same
    /// function so the next mutation is also caught.
    private func observeTracksSelection() {
        withObservationTracking {
            let sel = self.tracks.selection
            self.hasTrackSelection = !sel.isEmpty
            self.hasSingleTrackSelection = sel.count == 1
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeTracksSelection() }
        }
    }

    private func wireExpandedFoldersPersistence() {
        // Phase 6 audit: persist expanded playlist folders bidirectionally.
        // Restore happens in `restoreUIState()`, and updates are saved with a
        // short debounce to avoid frequent writes while users rapidly expand/collapse.
        self.expandedFoldersCancellable = self.playlistSidebar.$expandedFolders
            .dropFirst()
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { await self.saveUIState() }
            }
    }

    private func wirePlaylistCallbacks() {
        // Wire the NowPlayingStrip play button to start from the library when the
        // queue is empty.
        self.nowPlaying.onPlayFromEmptyQueue = { [weak self] in
            guard let self else { return }
            Task { await self.playCurrentLibrary() }
        }

        self.playlistSidebar.onDidDelete = { [weak self] deletedIDs in
            guard let self else { return }
            switch self.selectedDestination {
            case let .playlist(id) where deletedIDs.contains(id):
                self.selectedDestination = .songs

            case let .smartPlaylist(id) where deletedIDs.contains(id):
                self.selectedDestination = .songs

            case let .folder(id) where deletedIDs.contains(id):
                self.selectedDestination = .songs

            default:
                break
            }
        }

        self.playlistSidebar.onRequestExport = { [weak self] id, name in
            self?.playlistExportRequest = .init(id: id, name: name)
        }
    }

    private static func makeFingerprintQueue(database: Database) -> FingerprintQueue? {
        let apiKey = Bundle.main.infoDictionary?["AcoustIDAPIKey"] as? String ?? ""
        guard let fpcalcURL = Bundle.main.url(forResource: "fpcalc", withExtension: nil),
              !apiKey.isEmpty else { return nil }
        let service = FingerprintService(database: database, fpcalcURL: fpcalcURL, acoustIDAPIKey: apiKey)
        return FingerprintQueue(service: service)
    }

    private static func makePlaylistIO(
        database: Database,
        trackRepo: TrackRepository,
        playlistService: PlaylistService
    ) -> (PlaylistImportService, PlaylistExportService) {
        let resolver = TrackResolver(trackRepo: trackRepo)
        let importer = PlaylistImportService(resolver: resolver, playlists: playlistService)
        let exporter = PlaylistExportService(database: database)
        return (importer, exporter)
    }

    // MARK: - Tag editor

    /// Opens the tag editor sheet for the given tracks.
    public func showTagEditor(tracks: [Track]) {
        let ids = tracks.compactMap(\.id)
        guard !ids.isEmpty else { return }
        self.tagEditorTrackIDs = ids
    }

    /// Opens the tag editor for the track currently loaded in the player.
    public func showTagEditorForNowPlaying() {
        guard let id = self.nowPlaying.nowPlayingTrackID else { return }
        self.tagEditorTrackIDs = [id]
    }

    /// Navigates the sidebar to the album of the currently-playing track.
    ///
    /// No-op when nothing is playing or when the playing track has no album ID.
    public func goToCurrentAlbum() async {
        guard let albumID = self.nowPlaying.nowPlayingAlbumID else { return }
        await self.selectDestination(.album(albumID))
    }

    /// Navigates the sidebar to the artist of the currently-playing track.
    ///
    /// No-op when nothing is playing or when the playing track has no artist ID.
    public func goToCurrentArtist() async {
        guard let artistID = self.nowPlaying.nowPlayingArtistID else { return }
        await self.selectDestination(.artist(artistID))
    }

    /// Scrolls the track list to reveal the currently-playing track.
    ///
    /// If the now-playing track is not in the current destination (e.g. an album
    /// or artist drill-down that doesn't contain it), the sidebar first navigates
    /// to the Songs view before requesting the scroll.
    public func scrollToNowPlayingTrack() async {
        guard let id = self.nowPlaying.nowPlayingTrackID else { return }
        if !self.tracks.rows.contains(where: { $0.id == id }) {
            await self.selectDestination(.songs)
        }
        self.tracks.requestScrollToNowPlaying()
    }

    /// Opens the tag editor for whatever is currently selected in the track table.
    public func showTagEditorForCurrentSelection() {
        let ids = self.tracks.selection.compactMap(\.self)
        guard !ids.isEmpty else { return }
        self.tagEditorTrackIDs = ids
    }

    /// Opens the identify-track sheet for a single track.
    public func showIdentifyTrack(_ track: Track) {
        self.identifyTrack = track
    }

    /// Opens the identify-track sheet for the first track in the current selection.
    public func showIdentifyTrackForCurrentSelection() {
        guard let track = self.tracks.tracks.first(where: { self.tracks.selection.contains($0.id) }) else {
            return
        }
        self.identifyTrack = track
    }

    /// Reveals all selected tracks in Finder.
    public func revealSelectedInFinder() {
        let urls = self.tracks.tracks
            .filter { self.tracks.selection.contains($0.id) }
            .compactMap { URL(string: $0.fileURL) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    // MARK: - Public API

    /// Loads data for the current destination.
    public func loadCurrentDestination() async {
        await self.loadDestination(self.selectedDestination)
    }

    /// Responds to a sidebar selection change.
    ///
    /// - Parameter addToHistory: Pass `false` when navigating via back/forward
    ///   so the stacks are not double-pushed.
    public func selectDestination(_ destination: SidebarDestination, addToHistory: Bool = true) async {
        self.log.info("nav.select", ["destination": String(describing: destination)])

        if addToHistory, destination != self.selectedDestination {
            self.backStack.append(self.selectedDestination)
            if self.backStack.count > Self.historyLimit { self.backStack.removeFirst() }
            self.forwardStack.removeAll()
            self.canGoBack = true
            self.canGoForward = false
        }

        // Clear search when drilling into a detail page (album or artist).
        // For top-level browse views (songs/albums/artists/etc) keep the active
        // query so the new view shows filtered results immediately.
        switch destination {
        case .album, .artist, .playlist, .smartPlaylist, .folder:
            self.searchQuery = ""

        default:
            break
        }
        self.selectedDestination = destination
        await self.loadDestination(destination)
    }

    /// Navigates to the previous destination in history.
    public func goBack() async {
        guard let previous = self.backStack.popLast() else { return }
        self.forwardStack.append(self.selectedDestination)
        self.canGoBack = !self.backStack.isEmpty
        self.canGoForward = true
        await self.selectDestination(previous, addToHistory: false)
    }

    /// Navigates to the next destination in history.
    public func goForward() async {
        guard let next = self.forwardStack.popLast() else { return }
        self.backStack.append(self.selectedDestination)
        if self.backStack.count > Self.historyLimit { self.backStack.removeFirst() }
        self.canGoBack = true
        self.canGoForward = !self.forwardStack.isEmpty
        await self.selectDestination(next, addToHistory: false)
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
                try await qp.play(items: items, startingAt: startIndex, shuffle: self.nowPlaying.shuffleOn)
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
    ///
    /// Pass `shuffle: true` to pre-shuffle before playback so the very first
    /// track heard is randomly selected (not `tracks[0]`).
    public func play(tracks: [Track], startingAt index: Int = 0, shuffle: Bool = false) async {
        guard let qp = engine as? QueuePlayer else { return }
        let names = self.tracks.artistNames
        let items: [QueueItem] = tracks.map { t in
            let name = t.artistID.flatMap { names[$0] }
            return QueueItem.make(from: t, artistName: name)
        }
        do {
            try await qp.play(items: items, startingAt: index, shuffle: shuffle)
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

    /// Appends raw track IDs (e.g. from a pasteboard drop) to the end of the queue.
    /// Used by the Up Next sidebar drop target where only the IDs are available.
    public func addToQueue(trackIDs ids: [Int64]) async {
        guard let qp = engine as? QueuePlayer, !ids.isEmpty else { return }
        do {
            try await qp.addToQueue(ids)
        } catch {
            self.log.error("library.addToQueue.failed", ["error": String(reflecting: error)])
        }
    }

    /// Selects all currently visible tracks in the track list.
    public func selectAllTracks() {
        self.tracks.selectAll()
    }

    /// Clears the track selection.
    public func deselectAllTracks() {
        self.tracks.deselectAll()
    }

    /// Plays the first selected track now, with full browse-context (same as double-click).
    public func playNowForCurrentSelection() {
        guard let track = self.tracks.tracks.first(where: { self.tracks.selection.contains($0.id) }) else {
            return
        }
        Task { await self.play(track: track) }
    }

    /// Inserts all selected tracks immediately after the current item.
    public func playNextForCurrentSelection() {
        let selected = self.tracks.tracks.filter { self.tracks.selection.contains($0.id) }
        guard !selected.isEmpty else { return }
        Task { await self.playNext(tracks: selected) }
    }

    /// Appends all selected tracks to the end of the queue.
    public func addToQueueForCurrentSelection() {
        let selected = self.tracks.tracks.filter { self.tracks.selection.contains($0.id) }
        guard !selected.isEmpty else { return }
        Task { await self.addToQueue(tracks: selected) }
    }

    /// Plays the album of the first selected track, replacing the queue.
    public func playAlbumForCurrentSelection(shuffle: Bool = false) {
        guard let track = self.tracks.tracks.first(where: { self.tracks.selection.contains($0.id) }) else {
            return
        }
        Task { await self.playAlbum(track: track, shuffle: shuffle) }
    }

    /// Plays all tracks by the artist of the first selected track, replacing the queue.
    public func playArtistForCurrentSelection() {
        guard let track = self.tracks.tracks.first(where: { self.tracks.selection.contains($0.id) }) else {
            return
        }
        Task { await self.playArtist(track: track) }
    }

    // Plays all tracks from the album of `track`.

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
        await self.nowPlaying.setShuffle(on)
    }

    /// Reorders the playback queue to match the current track-list sort order,
    /// keeping the currently-playing track in place.
    ///
    /// No-op when nothing is playing or when the currently-playing track isn't
    /// in the view's current track list — sorting an unrelated browse view
    /// should not silently replace the playback queue.  The heavy QueueItem
    /// construction runs off the main actor so large libraries don't stall the UI.
    public func reorderQueue() async {
        guard let qp = engine as? QueuePlayer else { return }
        let contextTracks = self.tracks.tracks
        guard !contextTracks.isEmpty else { return }

        // Only reorder when the currently-playing track is actually in the
        // view's list; otherwise the user is sorting an unrelated context.
        let currentTrackID = self.nowPlaying.nowPlayingTrackID
        guard let currentTrackID,
              contextTracks.contains(where: { $0.id == currentTrackID }) else { return }

        let names = self.tracks.artistNames
        // Build QueueItems off the main actor so 20k-track libraries don't stall the UI.
        let items = await Task.detached(priority: .userInitiated) {
            contextTracks.map { t -> QueueItem in
                let name = t.artistID.flatMap { names[$0] }
                return QueueItem.make(from: t, artistName: name)
            }
        }.value
        await qp.queue.reorder(to: items)
    }

    /// Changes the repeat mode on the queue player.
    public func setRepeat(_ mode: RepeatMode) async {
        guard let qp = engine as? QueuePlayer else { return }
        await qp.setRepeat(mode)
    }

    /// Clears the entire playback queue and stops playback.  Used by the
    /// Playback menu's "Clear Queue" command (Phase 5 audit H1) and the
    /// matching Up Next toolbar / context-menu surfaces.
    public func clearQueue() async {
        guard let qp = engine as? QueuePlayer else { return }
        await qp.stop()
        await qp.queue.clear()
    }

    /// Jumps to and starts playing the queue item at `index` in the existing
    /// queue.  Used by the Up Next "Play From Here" context-menu action
    /// (Phase 5 audit M1).
    public func playFromQueueIndex(_ index: Int) async {
        guard let qp = engine as? QueuePlayer else { return }
        do {
            try await qp.playAt(index: index)
        } catch {
            self.log.error("library.playFromQueueIndex.failed", [
                "index": index,
                "error": String(reflecting: error),
            ])
        }
    }

    /// Moves a queue item to the top of the queue.  Used by the Up Next
    /// "Move to Top" context-menu action (Phase 5 audit M1).
    public func moveQueueItemToTop(id: QueueItem.ID) async {
        guard let qp = engine as? QueuePlayer else { return }
        let items = await qp.queue.items
        guard let from = items.firstIndex(where: { $0.id == id }), from != 0 else { return }
        await qp.queue.move(fromIndex: from, toIndex: 0)
    }

    /// Moves a queue item to the bottom of the queue.  Used by the Up Next
    /// "Move to Bottom" context-menu action (Phase 5 audit M1).
    public func moveQueueItemToBottom(id: QueueItem.ID) async {
        guard let qp = engine as? QueuePlayer else { return }
        let items = await qp.queue.items
        let last = items.count - 1
        guard let from = items.firstIndex(where: { $0.id == id }), from != last, last >= 0 else { return }
        await qp.queue.move(fromIndex: from, toIndex: last)
    }

    /// The underlying `QueuePlayer` if the engine is one; otherwise `nil`.
    public var queuePlayer: QueuePlayer? {
        self.engine as? QueuePlayer
    }

    /// Last sidebar width reported by the AppKit split-view, used to seed
    /// `UIStateV2.sidebarWidth` at save time.  Phase 4 audit H2.
    @Published public var sidebarWidth: Double?

    /// Bumped by the global ⌘F command; observed by `BocanRootView` to move
    /// `@FocusState` onto the toolbar search field.  Phase 4 audit H5.
    @Published public var searchFocusRequestID = UUID()

    /// One-shot request for `SmartPlaylistDetailView` to open `RuleBuilderView`
    /// as soon as the requested smart playlist is visible.
    @Published public var smartPlaylistRuleBuilderRequestID: Int64?

    /// Asks the root view to focus the toolbar search field.
    public func requestSearchFocus() {
        self.searchFocusRequestID = UUID()
    }

    /// Requests that the smart-playlist detail for `playlistID` opens rule editor.
    public func requestSmartPlaylistRuleBuilder(for playlistID: Int64) {
        self.smartPlaylistRuleBuilderRequestID = playlistID
    }

    /// Consumes a pending rule-builder request if it targets `playlistID`.
    @discardableResult
    public func consumeSmartPlaylistRuleBuilderRequest(for playlistID: Int64) -> Bool {
        guard self.smartPlaylistRuleBuilderRequestID == playlistID else { return false }
        self.smartPlaylistRuleBuilderRequestID = nil
        return true
    }

    /// Persists current UI state to settings.
    public func saveUIState() async {
        let state = UIStateV2(
            selectedDestination: selectedDestination,
            sortColumn: tracks.sortColumn,
            sortAscending: self.tracks.sortAscending,
            sidebarWidth: self.sidebarWidth,
            expandedPlaylistFolders: self.playlistSidebar.expandedFolders
        )
        do {
            try await self.settingsRepo.set(state, for: "ui.state.v2")
        } catch {
            self.log.error("library.saveState.failed", ["error": String(reflecting: error)])
        }
    }

    /// Restores UI state from settings.
    public func restoreUIState() async {
        do {
            guard let state = try await settingsRepo.get(UIStateV2.self, for: "ui.state.v2") else { return }
            self.selectedDestination = state.selectedDestination
            // Validate the restored destination. `playlistSidebar.reload()` is always
            // called before this method in the startup sequence, so `nodes` is already
            // populated. If the saved folder/playlist was deleted since last launch,
            // fall back to Songs rather than showing "Folder Not Found" on every startup.
            let savedDestID: Int64? = switch self.selectedDestination {
            case let .folder(id):
                id

            case let .playlist(id):
                id

            case let .smartPlaylist(id):
                id

            default:
                nil
            }
            if let id = savedDestID, self.playlistSidebar.findNode(id: id) == nil {
                self.log.warning("ui.restoreState.destinationGone", ["id": id])
                self.selectedDestination = .songs
            }
            self.tracks.setSort(column: state.sortColumn, ascending: state.sortAscending)
            self.sidebarWidth = state.sidebarWidth
            self.playlistSidebar.setExpandedFolders(state.expandedPlaylistFolders)
        } catch {
            self.log.error("library.restoreState.failed", ["error": String(reflecting: error)])
        }
    }

    // MARK: - Targeted track refresh

    /// Fetch only the given tracks from the database and update their rows in-place.
    ///
    /// Use this instead of `loadCurrentDestination()` after a tag edit or track
    /// identification so the table keeps its scroll position and selection.
    public func refreshTracks(ids: [Int64]) async {
        guard !ids.isEmpty else { return }
        let repo = TrackRepository(database: self.database)
        var updated: [Track] = []
        for id in ids {
            if let track = try? await repo.fetch(id: id) {
                updated.append(track)
            }
        }
        guard !updated.isEmpty else { return }
        self.tracks.updateRows(for: updated)
    }

    // MARK: - ReplayGain batch analysis

    /// Analyse ReplayGain for a specific set of track IDs (e.g. the current selection).
    ///
    /// Only tracks whose IDs exist in the database are analysed; IDs that are not
    /// found are silently skipped.  Any existing ReplayGain values for the supplied
    /// tracks are replaced.
    public func computeReplayGain(forTrackIDs ids: [Int64]) async {
        guard self.replayGainProgress == nil else { return }
        guard !ids.isEmpty else { return }
        let repo = TrackRepository(database: self.database)
        do {
            let all = try await repo.fetchAll()
            let selected = all.filter { ids.contains($0.id ?? -1) }
            await self.runReplayGainBatch(tracks: selected, repo: repo)
        } catch {
            self.log.error("rg.selection.fetchFailed", ["error": String(reflecting: error)])
        }
    }

    /// Analyse only tracks that currently have no ReplayGain data.
    public func computeMissingReplayGain() async {
        guard self.replayGainProgress == nil else { return } // already running
        let repo = TrackRepository(database: self.database)
        do {
            let all = try await repo.fetchAll()
            let missing = all.filter { $0.replaygainTrackGain == nil }
            await self.runReplayGainBatch(tracks: missing, repo: repo)
        } catch {
            self.log.error("rg.batch.fetchFailed", ["error": String(reflecting: error)])
        }
    }

    /// Re-analyse every track in the library, replacing existing values.
    public func recomputeAllReplayGain() async {
        guard self.replayGainProgress == nil else { return }
        let repo = TrackRepository(database: self.database)
        do {
            let all = try await repo.fetchAll()
            await self.runReplayGainBatch(tracks: all, repo: repo)
        } catch {
            self.log.error("rg.batch.fetchFailed", ["error": String(reflecting: error)])
        }
    }

    /// Runs off the main actor on the cooperative thread pool so multiple tracks
    /// can be decoded and measured in parallel.
    private nonisolated static func analyzeTrack(_ track: Track) async -> Result<Track, Error> {
        let log = AppLogger.make(.audio)
        do {
            let url: URL
            if let bookmarkData = track.fileBookmark {
                url = try BookmarkBlob(data: bookmarkData).resolve()
            } else {
                guard let raw = URL(string: track.fileURL) else { throw URLError(.badURL) }
                url = raw
            }
            defer { url.stopAccessingSecurityScopedResource() }
            let rg = try await ReplayGainAnalyzer.analyze(url: url)
            var updated = track
            updated.replaygainTrackGain = rg.trackGainDB
            updated.replaygainTrackPeak = rg.trackPeakLinear
            return .success(updated)
        } catch {
            log.error("rg.batch.trackFailed", [
                "url": track.fileURL,
                "error": String(reflecting: error),
            ])
            return .failure(error)
        }
    }

    private func runReplayGainBatch(tracks: [Track], repo: TrackRepository) async {
        guard !tracks.isEmpty else {
            self.replayGainProgress = ReplayGainBatchProgress(done: 0, total: 0, failed: 0)
            return
        }
        self.replayGainProgress = ReplayGainBatchProgress(done: 0, total: tracks.count, failed: 0)

        // Keep up to `concurrency` analysis tasks in flight at once.
        // Cap at 8: each in-flight track holds ~30 MB of Float32 PCM samples.
        let concurrency = min(ProcessInfo.processInfo.activeProcessorCount, 8)
        var done = 0
        var failed = 0
        var nextIndex = 0

        await withTaskGroup(of: Result<Track, Error>.self) { group in
            // Seed the initial pool.
            while nextIndex < tracks.count, nextIndex < concurrency {
                let track = tracks[nextIndex]
                nextIndex += 1
                group.addTask { await Self.analyzeTrack(track) }
            }

            // Drain results on the main actor; refill immediately after each.
            for await result in group {
                switch result {
                case let .success(updatedTrack):
                    do {
                        try await repo.update(updatedTrack)
                    } catch {
                        self.log.error("rg.batch.updateFailed", ["error": String(reflecting: error)])
                        failed += 1
                    }
                    done += 1

                case .failure:
                    failed += 1
                    done += 1
                }

                self.replayGainProgress = ReplayGainBatchProgress(
                    done: done,
                    total: tracks.count,
                    failed: failed
                )

                if nextIndex < tracks.count {
                    let track = tracks[nextIndex]
                    nextIndex += 1
                    group.addTask { await Self.analyzeTrack(track) }
                }
            }
        }
    }
}

// MARK: - ReplayGainBatchProgress

/// Progress snapshot for a running or completed ReplayGain batch analysis.
public struct ReplayGainBatchProgress: Sendable {
    public let done: Int
    public let total: Int
    public let failed: Int

    public var isComplete: Bool {
        self.done == self.total
    }

    public var succeeded: Int {
        self.done - self.failed
    }
}
