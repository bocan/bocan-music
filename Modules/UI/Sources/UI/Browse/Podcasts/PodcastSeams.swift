import Foundation
import Persistence

// MARK: - Phase 21-8: Search seam types

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
        podcastID: Int64? = nil
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
    func observeSubscribed() async -> AsyncThrowingStream<[Podcast], Error>
    func observeEpisodes(podcastID: Int64) async -> AsyncThrowingStream<[EpisodeListItem], Error>
    func episodeCounts() async throws -> [Int64: Int]
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
    @discardableResult func subscribe(feedURL: URL) async throws -> Int64
    func unsubscribe(podcastID: Int64) async throws
    func refresh(podcastID: Int64) async throws
    func refreshAll() async
    func reorder(podcastIDs: [Int64]) async throws
    func setAutoDownload(_ on: Bool, podcastID: Int64) async throws
    /// Builds and enqueues a podcast `QueueItem`, then begins playback.
    func play(episode: EpisodeListItem, podcast: Podcast) async
    func markPlayed(podcastID: Int64, guid: String) async
    func markUnplayed(podcastID: Int64, guid: String) async
    func markAllPlayed(podcastID: Int64) async
    /// No-op when phase 21-6 downloads are not built.
    func download(podcastID: Int64, guid: String) async
    func removeDownload(podcastID: Int64, guid: String) async
    /// Returns [] when the episode has no chapters URL or the fetch fails.
    func chapters(podcastID: Int64, guid: String) async throws -> [UIChapter]
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
