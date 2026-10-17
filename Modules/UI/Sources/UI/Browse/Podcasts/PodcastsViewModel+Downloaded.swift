import Foundation
import Persistence

// MARK: - DownloadedShowGroup

/// One show's downloads, for the Downloaded list grouped by show (#651).
public struct DownloadedShowGroup: Identifiable, Equatable, Sendable {
    /// The show's `podcasts.id`.
    public let id: Int64
    /// Feed content, rendered verbatim.
    public let title: String
    public let items: [EpisodeListItem]
}

// MARK: - Downloaded list (#651)

/// The Downloaded list's view-model surface, and the Up Next actions the
/// Downloaded list and the show page share. Split out of
/// `PodcastsViewModel.swift` for file_length headroom, as
/// `PodcastsViewModel+ContinueListening.swift` was.
public extension PodcastsViewModel {
    /// Keeps ``downloaded`` live until the calling task is cancelled. The list
    /// runs it from `.task`, so leaving the list ends the observation: during
    /// playback every position write would otherwise re-run the query for a
    /// list nobody is looking at.
    func observeDownloaded() async {
        guard let library else { return }
        let stream = await library.observeDownloadedEpisodes()
        do {
            for try await items in stream {
                try Task.checkCancellation()
                self.downloaded = items
            }
        } catch is CancellationError {
            // Expected when the list leaves the screen.
        } catch {
            self.log.warning("podcasts.observeDownloaded.failed", ["error": String(reflecting: error)])
        }
    }

    /// Show titles keyed by id, for the Show column, the query match and the
    /// group headers.
    var showTitles: [Int64: String] {
        var titles: [Int64: String] = [:]
        for show in self.subscribed {
            if let id = show.id {
                titles[id] = show.title
            }
        }
        return titles
    }

    /// The shows that have at least one download, by title: the show filter's
    /// choices.
    var showsWithDownloads: [Podcast] {
        let ids = Set(self.downloaded.map(\.episode.podcastID))
        return self.subscribed
            .filter { $0.id.map(ids.contains) ?? false }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// The downloads as listed: kept to one show when `showFilter` is set,
    /// matched on episode or show title, in publish order. `items` arrive
    /// newest first, so oldest first is the exact reverse, ties included.
    static func visibleDownloads(
        _ items: [EpisodeListItem],
        showFilter: Int64?,
        query: String,
        order: EpisodeSortOrder,
        showTitles: [Int64: String]
    ) -> [EpisodeListItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let kept = items.filter { item in
            if let showFilter, item.episode.podcastID != showFilter {
                return false
            }
            guard !trimmed.isEmpty else { return true }
            return item.episode.title.localizedCaseInsensitiveContains(trimmed)
                || (showTitles[item.episode.podcastID]?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
        return order == .oldest ? kept.reversed() : kept
    }

    /// `visible` split into one group per show, shows by title, each group
    /// in the list's own order.
    static func groupedDownloads(
        _ visible: [EpisodeListItem],
        showTitles: [Int64: String]
    ) -> [DownloadedShowGroup] {
        var order: [Int64] = []
        var byShow: [Int64: [EpisodeListItem]] = [:]
        for item in visible {
            let id = item.episode.podcastID
            if byShow[id] == nil {
                order.append(id)
            }
            byShow[id, default: []].append(item)
        }
        return order
            .map { DownloadedShowGroup(id: $0, title: showTitles[$0] ?? "", items: byShow[$0] ?? []) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// What Play All queues: every listed episode not yet finished, in list
    /// order. A played download stays listed, but playing it again is a
    /// choice, not part of "play my downloads".
    static func episodesToPlayAll(_ visible: [EpisodeListItem]) -> [EpisodeListItem] {
        visible.filter { $0.state?.playState != .played }
    }

    /// Replaces Up Next with ``episodesToPlayAll(_:)`` and starts the first.
    func playAll(_ visible: [EpisodeListItem]) async {
        await self.enqueue(Self.episodesToPlayAll(visible), placement: .now)
    }

    /// Plays one episode from any show, as the show page's double-click does.
    func play(_ item: EpisodeListItem) async {
        await self.enqueue([item], placement: .now)
    }

    /// Puts episodes from any shows into Up Next. Each one's show comes from
    /// the live subscriptions (and the open show), so an episode of a show
    /// unsubscribed a moment ago is left out rather than played.
    func enqueue(_ items: [EpisodeListItem], placement: PodcastQueuePlacement) async {
        guard let actions, !items.isEmpty else { return }
        var shows: [Int64: Podcast] = [:]
        for show in self.subscribed {
            if let id = show.id {
                shows[id] = show
            }
        }
        if let show = self.currentShow, let id = show.id {
            shows[id] = show
        }
        await actions.enqueue(items, shows: shows, placement: placement)
    }

    /// Removes each episode's download; the list drops the rows as the
    /// observation re-emits.
    func removeDownloads(_ items: [EpisodeListItem]) async {
        for item in items {
            await self.actions?.removeDownload(podcastID: item.episode.podcastID, guid: item.episode.guid)
        }
    }
}
