import Foundation
import Persistence

// MARK: - ADR-045: Search seam types

//
// UIPodcastSearchSource and UIPodcastSearchResult mirror the canonical types
// from the Podcasts module. The App layer maps between them so the UI module
// never imports Podcasts directly.

/// Mirror of `Podcasts.PodcastSearchSource` declared in UI.
public enum UIPodcastSearchSource: String, Sendable, Codable, CaseIterable, Hashable {
    case podcastIndex
    case itunes
}

/// Mirror of `Podcasts.PodcastSearchResult` declared in UI.
public struct UIPodcastSearchResult: Sendable, Hashable, Identifiable {
    public var id: String {
        self.canonicalFeedKey
    }

    public var canonicalFeedKey: String
    public var feedURL: URL
    public var title: String
    public var author: String?
    public var artworkURL: URL?
    public var description: String?
    public var episodeCount: Int?
    public var lastPublishedAt: Date?
    public var categories: [String]
    public var sources: Set<UIPodcastSearchSource>
    public var podcastIndexID: Int?
    public var itunesCollectionID: Int?

    public init(
        canonicalFeedKey: String,
        feedURL: URL,
        title: String,
        author: String? = nil,
        artworkURL: URL? = nil,
        description: String? = nil,
        episodeCount: Int? = nil,
        lastPublishedAt: Date? = nil,
        categories: [String] = [],
        sources: Set<UIPodcastSearchSource> = [],
        podcastIndexID: Int? = nil,
        itunesCollectionID: Int? = nil
    ) {
        self.canonicalFeedKey = canonicalFeedKey
        self.feedURL = feedURL
        self.title = title
        self.author = author
        self.artworkURL = artworkURL
        self.description = description
        self.episodeCount = episodeCount
        self.lastPublishedAt = lastPublishedAt
        self.categories = categories
        self.sources = sources
        self.podcastIndexID = podcastIndexID
        self.itunesCollectionID = itunesCollectionID
    }
}

/// Loading/error state of the podcast search dropdown.
public enum PodcastSearchState: Sendable, Equatable {
    case idle
    case searching
    case results
    case empty
    case error(String)
}

/// Channel metadata + recent-episode preview for the detail view, fetched
/// from the live feed and enriched from the search index.
public struct PodcastDetail: Sendable, Hashable {
    public var feedURL: URL
    public var title: String
    public var author: String?
    public var description: String?
    public var artworkURL: URL?
    public var link: URL?
    public var categories: [String]
    public var sources: Set<UIPodcastSearchSource>
    /// Newest first, capped at 25.
    public var episodePreview: [PodcastDetailEpisode]
    /// True when the canonical feed URL already exists in the subscriptions table.
    public var alreadySubscribed: Bool
    /// Set when `alreadySubscribed` is true; used for future "Go to Show" navigation.
    public var podcastID: Int64?
    /// Show-level Podcasting 2.0 `podcast:person` credits parsed from the feed.
    public var persons: [PodcastPerson]
    /// Directory identifiers from the search result the detail was opened
    /// from, carried through to `subscribe` so they land on the row (#409).
    public var podcastIndexID: Int?
    public var itunesCollectionID: Int?

    public init(
        feedURL: URL,
        title: String,
        author: String? = nil,
        description: String? = nil,
        artworkURL: URL? = nil,
        link: URL? = nil,
        categories: [String] = [],
        sources: Set<UIPodcastSearchSource> = [],
        episodePreview: [PodcastDetailEpisode] = [],
        alreadySubscribed: Bool = false,
        podcastID: Int64? = nil,
        persons: [PodcastPerson] = [],
        podcastIndexID: Int? = nil,
        itunesCollectionID: Int? = nil
    ) {
        self.feedURL = feedURL
        self.title = title
        self.author = author
        self.description = description
        self.artworkURL = artworkURL
        self.link = link
        self.categories = categories
        self.sources = sources
        self.episodePreview = episodePreview
        self.alreadySubscribed = alreadySubscribed
        self.podcastID = podcastID
        self.persons = persons
        self.podcastIndexID = podcastIndexID
        self.itunesCollectionID = itunesCollectionID
    }
}

/// A lightweight episode row shown in the detail view preview.
public struct PodcastDetailEpisode: Sendable, Hashable, Identifiable {
    public var id: String {
        self.guid
    }

    public var guid: String
    public var title: String
    public var publishedAt: Date?
    public var duration: TimeInterval?
    public var descriptionHTML: String?

    public init(
        guid: String,
        title: String,
        publishedAt: Date? = nil,
        duration: TimeInterval? = nil,
        descriptionHTML: String? = nil
    ) {
        self.guid = guid
        self.title = title
        self.publishedAt = publishedAt
        self.duration = duration
        self.descriptionHTML = descriptionHTML
    }
}

// MARK: - PodcastSearchProviding

/// Dual-index search + detail-view seam declared in the UI module so UI never
/// imports `Podcasts`. The App layer implements this with `AppPodcastSearch`.
public protocol PodcastSearchProviding: Sendable {
    /// Concurrent Podcast Index + iTunes search, already merged, deduped, and
    /// badge-tagged. Returns `[]` for whitespace-only terms.
    func search(term: String) async throws -> [UIPodcastSearchResult]
    /// Channel metadata + a recent-episode preview built from the live feed,
    /// optionally enriched by the hint from the search index.
    func detail(feedURL: URL, hint: UIPodcastSearchResult?) async throws -> PodcastDetail
}

// MARK: - PodcastLibraryDataSource

/// Data-access protocol the UI uses to read podcast library state.
///
/// Declared in the UI module so UI never imports `Podcasts`. The App layer
/// conforms `PodcastService` to this protocol and injects it into
/// `LibraryViewModel`. Seam types (`Podcast`, `EpisodeListItem`) come from
/// `Persistence`, which UI already imports.
public protocol PodcastLibraryDataSource: Sendable {
    func subscribedPodcasts() async throws -> [Podcast]
    func episodes(podcastID: Int64) async throws -> [EpisodeListItem]
    /// Episode list in a specific sort order (the VM resolves it from the show).
    func episodes(podcastID: Int64, order: EpisodeSortOrder) async throws -> [EpisodeListItem]
    func observeSubscribed() async -> AsyncThrowingStream<[Podcast], Error>
    func observeEpisodes(podcastID: Int64) async -> AsyncThrowingStream<[EpisodeListItem], Error>
    /// Live episode list in a specific sort order.
    func observeEpisodes(podcastID: Int64, order: EpisodeSortOrder) async -> AsyncThrowingStream<[EpisodeListItem], Error>
    func episodeCounts() async throws -> [Int64: Int]
    /// Unread counts keyed by podcast ID (no state row or not yet played); zero-count shows absent.
    func unplayedCounts() async throws -> [Int64: Int]
    /// Live unread counts; re-emits after any play-state write so badges self-clear.
    func observeUnplayedCounts() async -> AsyncThrowingStream<[Int64: Int], Error>
    /// In-progress episodes across all subscribed shows, newest first (ADR-054).
    func continueListening() async throws -> [ContinueListeningItem]
    /// Live Continue Listening rail; re-emits on any state/content/show change.
    func observeContinueListening() async -> AsyncThrowingStream<[ContinueListeningItem], Error>
    /// Live list of every downloaded episode across all shows, newest first
    /// (#651); re-emits when a download lands or goes, and on play-state changes.
    func observeDownloadedEpisodes() async -> AsyncThrowingStream<[EpisodeListItem], Error>
    /// One episode's show notes HTML, nil when it has none. Every list read
    /// above leaves `descriptionHTML` nil, because a list re-reads on each
    /// position write and the notes are most of a row's bytes.
    func showNotesHTML(podcastID: Int64, guid: String) async throws -> String?
}

// MARK: - PodcastActions

/// Mutation protocol the UI uses to drive podcast operations.
///
/// Declared in the UI module so UI never imports `Podcasts`. The App layer
/// implements `AppPodcastActions` over `PodcastService` + `QueuePlayer`.
///
/// `play(episode:podcast:)` lives in the App implementation because building a
/// podcast `QueueItem` requires both `PlayableSource.podcast` (from Playback)
/// and the `QueuePlayer` (also in Playback) -- two lower modules UI must not
/// see together.
public protocol PodcastActions: Sendable {
    /// Subscribes to `feedURL`. The directory IDs come from the search result
    /// the user subscribed from and are stored on the row (#409); pass nil for
    /// a URL typed by hand.
    @discardableResult func subscribe(feedURL: URL, podcastIndexID: Int?, itunesCollectionID: Int?) async throws -> Int64
    func unsubscribe(podcastID: Int64) async throws
    func refresh(podcastID: Int64) async throws
    func refreshAll() async
    func setAutoDownload(_ on: Bool, podcastID: Int64) async throws
    /// Per-show playback-speed override (nil = use the app default).
    func setPlaybackSpeed(_ speed: Double?, podcastID: Int64) async throws
    /// Per-show episode-sort override ("newest" | "oldest" | nil = derive from show type).
    func setEpisodeSort(_ sort: String?, podcastID: Int64) async throws
    /// Per-show retention limit (keep newest N; nil = keep all).
    func setRetentionLimit(_ limit: Int?, podcastID: Int64) async throws
    /// Builds and enqueues a podcast `QueueItem`, then begins playback.
    func play(episode: EpisodeListItem, podcast: Podcast) async
    /// Puts a run of episodes, from any shows, into Up Next in the order given
    /// (#651). `shows` maps each episode's `podcastID` to its show; an episode
    /// whose show is missing is left out. `.now` replaces the queue and starts
    /// the first one.
    func enqueue(_ episodes: [EpisodeListItem], shows: [Int64: Podcast], placement: PodcastQueuePlacement) async
    /// The play-state writes throw so the caller can tell the listener: a
    /// failed write leaves the list as it was, which looks like the click did
    /// nothing (#640). Views go through `PodcastsViewModel`, which reports it.
    func markPlayed(podcastID: Int64, guid: String) async throws
    func markUnplayed(podcastID: Int64, guid: String) async throws
    /// Marks a selection of one show's episodes in a single write, so the list
    /// refreshes once rather than once per episode (#635).
    func markPlayed(podcastID: Int64, guids: [String]) async throws
    func markUnplayed(podcastID: Int64, guids: [String]) async throws
    func markAllPlayed(podcastID: Int64) async throws
    /// No-op when ADR-043 downloads are not built. Throws when the download
    /// could not be queued; a transfer that fails later shows on the badge.
    func download(podcastID: Int64, guid: String) async throws
    func removeDownload(podcastID: Int64, guid: String) async
    /// Live download progress: one element per state change or throttled tick,
    /// so the episode badge can show how far a download has got. Persisted
    /// state still arrives through the episode observation; this carries only
    /// the fraction, which is not stored.
    ///
    /// Single-consumer: it is backed by one `AsyncStream`, so a second caller
    /// would divide the elements with the first (#545). `PodcastsViewModel`
    /// subscribes once for the life of the app; anything else needs the
    /// per-subscriber shape `PlaybackQueue.changes()` uses.
    func downloadProgress() async -> AsyncStream<UIEpisodeDownloadProgress>
    /// Returns [] when the episode has no chapters URL or the fetch fails.
    func chapters(podcastID: Int64, guid: String) async throws -> [UIChapter]
    /// Imports an OPML subscription list, subscribing reachable feeds and returning
    /// a partitioned summary. `progress` is called `(completed, total)` per attempt.
    func importOPML(data: Data, progress: @escaping @Sendable (Int, Int) -> Void) async throws -> UIOPMLImportSummary
    /// Serializes current subscriptions to OPML 2.0 UTF-8 data.
    func exportOPML() async throws -> Data
}

// MARK: - OPML import seam types

/// Mirror of `Podcasts.OPMLImportItem` declared in UI. Title and reason are
/// content/diagnostic strings rendered verbatim, never localized.
public struct UIOPMLImportItem: Sendable, Hashable, Identifiable {
    public var id: String {
        self.feedURL.absoluteString
    }

    public var title: String
    public var feedURL: URL
    public var reason: String

    public init(title: String, feedURL: URL, reason: String) {
        self.title = title
        self.feedURL = feedURL
        self.reason = reason
    }
}

/// Mirror of `Podcasts.OPMLImportSummary` declared in UI.
public struct UIOPMLImportSummary: Sendable, Hashable {
    public var succeeded: [UIOPMLImportItem]
    public var alreadySubscribed: [UIOPMLImportItem]
    public var failed: [UIOPMLImportItem]

    public init(
        succeeded: [UIOPMLImportItem] = [],
        alreadySubscribed: [UIOPMLImportItem] = [],
        failed: [UIOPMLImportItem] = []
    ) {
        self.succeeded = succeeded
        self.alreadySubscribed = alreadySubscribed
        self.failed = failed
    }

    /// Feeds actually attempted (succeeded + failed); excludes skipped duplicates.
    public var totalAttempted: Int {
        self.succeeded.count + self.failed.count
    }
}

// MARK: - Chapters

/// Mirror of `Podcasts.Chapter`, declared in UI so UI never imports `Podcasts`.
/// `title` is feed content, rendered verbatim, never localized.
public struct UIChapter: Sendable, Hashable, Identifiable {
    public var id: Int
    public var startTime: TimeInterval
    public var title: String
    public var imageURL: URL?
    public var url: URL?

    public init(id: Int, startTime: TimeInterval, title: String, imageURL: URL? = nil, url: URL? = nil) {
        self.id = id
        self.startTime = startTime
        self.title = title
        self.imageURL = imageURL
        self.url = url
    }
}

/// Helpers for finding the chapter active at a playback position.
public extension [UIChapter] {
    /// The chapter active at `position`: the last whose `startTime` is at or before
    /// `position`. Nil before the first chapter's start, or when the list is empty.
    func current(at position: TimeInterval) -> UIChapter? {
        self.last { $0.startTime <= position }
    }
}

// MARK: - PodcastTranscriptProviding

/// Cached-or-fetched transcript for an episode, declared in UI so UI never imports
/// `Podcasts`. The seam type `PodcastTranscript` comes from `Persistence`. The App
/// layer implements this over `PodcastService.transcript(...)`. The viewer maps a
/// throw to its empty/disabled state (no transcript, or the fetch failed).
public protocol PodcastTranscriptProviding: Sendable {
    func transcript(podcastID: Int64, guid: String) async throws -> PodcastTranscript
}

/// Convenience overloads for `PodcastActions` callers without directory IDs.
public extension PodcastActions {
    /// Subscribe with no directory identifiers (hand-typed or OPML feed URLs).
    @discardableResult
    func subscribe(feedURL: URL) async throws -> Int64 {
        try await self.subscribe(feedURL: feedURL, podcastIndexID: nil, itunesCollectionID: nil)
    }

    /// No live progress: the badge falls back to the plain downloading icon.
    func downloadProgress() async -> AsyncStream<UIEpisodeDownloadProgress> {
        AsyncStream { $0.finish() }
    }

    /// Nothing to queue into: test doubles that do not play. `AppPodcastActions`
    /// implements the real one, and its adapter test calls it through the
    /// protocol so this default cannot stand in for it unnoticed.
    func enqueue(_: [EpisodeListItem], shows _: [Int64: Podcast], placement _: PodcastQueuePlacement) async {}
}

// MARK: - PodcastQueuePlacement

/// Where ``PodcastActions/enqueue(_:shows:placement:)`` puts the episodes.
public enum PodcastQueuePlacement: Sendable, Equatable {
    /// Replace Up Next and start playing the first episode.
    case now
    /// Right after what is playing.
    case next
    /// At the end of Up Next.
    case last
}

// MARK: - UIEpisodeDownloadProgress

/// One episode download's live progress, mirrored from
/// `Podcasts.EpisodeDownload` so UI never imports `Podcasts`. `status` is the
/// `Persistence` vocabulary the badge already speaks.
public struct UIEpisodeDownloadProgress: Sendable, Hashable, Identifiable {
    public var podcastID: Int64
    public var guid: String
    /// 0...1, or 0 while the total size is still unknown.
    public var fractionComplete: Double
    public var status: EpisodeDownloadState

    /// Matches ``PodcastsViewModel/downloadKey(podcastID:guid:)``.
    public var id: String {
        "\(self.podcastID)/\(self.guid)"
    }

    public init(podcastID: Int64, guid: String, fractionComplete: Double, status: EpisodeDownloadState) {
        self.podcastID = podcastID
        self.guid = guid
        self.fractionComplete = fractionComplete
        self.status = status
    }
}
