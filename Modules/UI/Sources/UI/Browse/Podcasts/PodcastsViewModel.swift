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
    @Published public private(set) var isLoading = false
    @Published public private(set) var currentShow: Podcast?
    /// Episodes for the currently open show. Populated by `loadShow(_:)`.
    @Published public private(set) var episodes: [EpisodeListItem] = []
    @Published public var addBarText = ""
    /// Set by `openShow(_:)` and observed by `PodcastsGridView` to trigger navigation.
    @Published public var selectedShowID: Int64?

    // MARK: - Dependencies

    private let library: (any PodcastLibraryDataSource)?
    private let actions: (any PodcastActions)?
    private let log = AppLogger.make(.ui)

    // MARK: - Observation tasks

    // Spurious compiler warning: `'nonisolated(unsafe)' has no effect on property 'X',
    // consider using 'nonisolated'` fires here. Its fix-it does not compile (nonisolated
    // is rejected on mutable stored properties). Leave nonisolated(unsafe) as-is -- see UI CLAUDE.md.
    private nonisolated(unsafe) var subscribedTask: Task<Void, Never>?
    private nonisolated(unsafe) var episodesTask: Task<Void, Never>?

    // MARK: - Init

    public init(library: (any PodcastLibraryDataSource)?, actions: (any PodcastActions)?) {
        self.library = library
        self.actions = actions
    }

    deinit {
        subscribedTask?.cancel()
        episodesTask?.cancel()
    }

    // MARK: - Home

    /// Fetches the subscribed-show list once, then starts a live observation so
    /// the grid updates automatically on subscribe/unsubscribe/refresh.
    public func loadSubscribed() async {
        guard let library else { return }
        self.isLoading = true
        do {
            self.subscribed = try await library.subscribedPodcasts()
        } catch {
            self.log.error("podcasts.loadSubscribed.failed", ["error": String(reflecting: error)])
        }
        self.isLoading = false
        self.startObserveSubscribed(library: library)
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

    public func unsubscribe(_ id: Int64) async {
        do {
            try await self.actions?.unsubscribe(podcastID: id)
        } catch {
            self.log.error("podcasts.unsubscribe.failed", ["id": id, "error": String(reflecting: error)])
        }
    }
}
