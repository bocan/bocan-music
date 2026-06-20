import Foundation
import Observability
import Persistence

// MARK: - PodcastsViewModel

/// Drives `PodcastsHomeView` (subscribed grid + Add bar) and `PodcastShowView`
/// (episode list). Owned by `LibraryViewModel`.
@MainActor
public final class PodcastsViewModel: ObservableObject {
    // MARK: - Published state

    @Published public private(set) var subscribed: [Podcast] = []
    @Published public private(set) var podcastEpisodeCounts: [Int64: Int] = [:]
    @Published public private(set) var isLoading = false
    @Published public private(set) var currentShow: Podcast?
    /// Episodes for the currently open show. Populated by `loadShow(_:)`.
    @Published public private(set) var episodes: [EpisodeListItem] = []
    @Published public var addBarText = ""
    /// Set by `openShow(_:)` and observed by `PodcastsGridView` to trigger navigation.
    @Published public var selectedShowID: Int64?

    // MARK: - Phase 21-8: search + detail state

    @Published public internal(set) var searchResults: [UIPodcastSearchResult] = []
    @Published public internal(set) var searchState: PodcastSearchState = .idle
    @Published public internal(set) var addByURLCandidate: URL?
    /// Controls the detail sheet. Publicly settable so SwiftUI's sheet binding can dismiss it.
    @Published public var showingDetail = false
    @Published public internal(set) var currentDetail: PodcastDetail?
    @Published public internal(set) var isLoadingDetail = false
    @Published public internal(set) var detailError: String?
    /// Chapters for the currently-playing episode, loaded by the Now Playing strip.
    @Published public internal(set) var nowPlayingChapters: [UIChapter] = []

    // MARK: - Dependencies

    private let library: (any PodcastLibraryDataSource)?
    let actions: (any PodcastActions)?
    let searchProvider: (any PodcastSearchProviding)?
    let transcriptProvider: (any PodcastTranscriptProviding)?
    let log = AppLogger.make(.ui)

    // MARK: - Observation tasks

    // Spurious compiler warning: `'nonisolated(unsafe)' has no effect on property 'X',
    // consider using 'nonisolated'` fires here. Its fix-it does not compile (nonisolated
    // is rejected on mutable stored properties). Leave nonisolated(unsafe) as-is -- see UI CLAUDE.md.
    private nonisolated(unsafe) var subscribedTask: Task<Void, Never>?
    private nonisolated(unsafe) var episodesTask: Task<Void, Never>?
    nonisolated(unsafe) var detailTask: Task<Void, Never>?

    // MARK: - Init

    public init(
        library: (any PodcastLibraryDataSource)?,
        actions: (any PodcastActions)?,
        searchProvider: (any PodcastSearchProviding)? = nil,
        transcriptProvider: (any PodcastTranscriptProviding)? = nil
    ) {
        self.library = library
        self.actions = actions
        self.searchProvider = searchProvider
        self.transcriptProvider = transcriptProvider
    }

    deinit {
        subscribedTask?.cancel()
        episodesTask?.cancel()
        detailTask?.cancel()
    }

    // MARK: - Transcripts

    /// Fetches (cache-first) and parses an episode transcript, off the main actor.
    /// Returns nil when there is no provider, no transcript, or the fetch fails;
    /// the viewer renders that as its empty state.
    func loadTranscript(podcastID: Int64, guid: String) async -> TranscriptContent? {
        guard let transcriptProvider else { return nil }
        do {
            let record = try await transcriptProvider.transcript(podcastID: podcastID, guid: guid)
            let content = record.content
            let format = record.format
            return await Task.detached { TranscriptParser.parse(content, format: format) }.value
        } catch {
            self.log.debug("podcasts.loadTranscript.failed", ["error": String(reflecting: error)])
            return nil
        }
    }

    /// Loads chapters for the currently-playing episode into `nowPlayingChapters`.
    /// Best-effort: any failure leaves the list empty so the UI hides the affordance.
    func loadChapters(podcastID: Int64, guid: String) async {
        guard let actions else {
            self.nowPlayingChapters = []
            return
        }
        do {
            self.nowPlayingChapters = try await actions.chapters(podcastID: podcastID, guid: guid)
        } catch {
            self.log.debug("podcasts.loadChapters.failed", ["error": String(reflecting: error)])
            self.nowPlayingChapters = []
        }
    }

    /// Clears chapters when the playing item is not a podcast (or stops).
    func clearNowPlayingChapters() {
        self.nowPlayingChapters = []
    }

    // MARK: - Home

    /// Fetches the subscribed-show list once, then starts a live observation so
    /// the grid updates automatically on subscribe/unsubscribe/refresh.
    public func loadSubscribed() async {
        guard let library else { return }
        self.isLoading = true
        do {
            self.subscribed = try await library.subscribedPodcasts()
            self.podcastEpisodeCounts = await (try? library.episodeCounts()) ?? [:]
        } catch {
            self.log.error("podcasts.loadSubscribed.failed", ["error": String(reflecting: error)])
        }
        self.isLoading = false
        self.startObserveSubscribed(library: library)
        self.healMissingArtwork()
    }

    /// Fires background refreshes for any subscribed shows whose artwork file has
    /// gone missing (e.g. macOS purged the old Caches location after an update).
    /// Staggered by 0.5 s so it doesn't hammer the network on launch.
    private func healMissingArtwork() {
        let stale = self.subscribed.filter { podcast in
            guard let path = podcast.artworkPath else { return false }
            return !FileManager.default.fileExists(atPath: path)
        }
        guard !stale.isEmpty else { return }
        self.log.debug("podcasts.artwork.stale", ["count": stale.count])
        let actions = self.actions
        Task.detached(priority: .background) {
            for podcast in stale {
                guard let id = podcast.id else { continue }
                try? await actions?.refresh(podcastID: id)
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func startObserveSubscribed(library: any PodcastLibraryDataSource) {
        self.subscribedTask?.cancel()
        self.subscribedTask = Task { [weak self] in
            let stream = await library.observeSubscribed()
            do {
                for try await podcasts in stream {
                    guard let self else { return }
                    try Task.checkCancellation()
                    self.subscribed = podcasts
                    self.podcastEpisodeCounts = await (try? library.episodeCounts()) ?? [:]
                }
            } catch is CancellationError {
                // Expected when the task is cancelled on navigation.
            } catch {
                self?.log.warning("podcasts.observe.failed", ["error": String(reflecting: error)])
            }
        }
    }

    /// Signals navigation to a show's episode list. The grid view observes
    /// `selectedShowID` and calls `library.selectDestination(.podcastShow(id))`.
    public func openShow(_ id: Int64) {
        self.selectedShowID = id
    }

    // MARK: - Show

    /// Fetches the show metadata and episode list, then starts a live observation
    /// so the episode table updates when playback state changes.
    public func loadShow(_ id: Int64) async {
        guard let library else { return }
        self.isLoading = true
        do {
            let podcasts = try await library.subscribedPodcasts()
            self.currentShow = podcasts.first { $0.id == id }
            self.episodes = try await library.episodes(podcastID: id)
        } catch {
            self.log.error("podcasts.loadShow.failed", ["id": id, "error": String(reflecting: error)])
        }
        self.isLoading = false
        self.startObserveEpisodes(podcastID: id, library: library)
    }

    private func startObserveEpisodes(podcastID: Int64, library: any PodcastLibraryDataSource) {
        self.episodesTask?.cancel()
        self.episodesTask = Task { [weak self] in
            let stream = await library.observeEpisodes(podcastID: podcastID)
            do {
                for try await items in stream {
                    guard let self else { return }
                    try Task.checkCancellation()
                    self.episodes = items
                }
            } catch is CancellationError {
                // Expected when the task is cancelled on navigation.
            } catch {
                self?.log.warning("podcasts.observeEpisodes.failed", ["error": String(reflecting: error)])
            }
        }
    }

    // MARK: - Actions

    public func refreshAll() async {
        await self.actions?.refreshAll()
    }

    public func refreshCurrentShow() async {
        guard let id = currentShow?.id else { return }
        do {
            try await self.actions?.refresh(podcastID: id)
        } catch {
            self.log.error("podcasts.refreshShow.failed", ["id": id, "error": String(reflecting: error)])
        }
    }

    public func unsubscribe(_ id: Int64) async {
        do {
            try await self.actions?.unsubscribe(podcastID: id)
        } catch {
            self.log.error("podcasts.unsubscribe.failed", ["id": id, "error": String(reflecting: error)])
        }
    }

    public func markAllPlayed() async {
        guard let id = currentShow?.id else { return }
        await self.actions?.markAllPlayed(podcastID: id)
    }

    public func toggleAutoDownload(_ on: Bool) async {
        guard let id = currentShow?.id else { return }
        do {
            try await self.actions?.setAutoDownload(on, podcastID: id)
        } catch {
            self.log.error("podcasts.setAutoDownload.failed", ["id": id, "error": String(reflecting: error)])
        }
    }
}
