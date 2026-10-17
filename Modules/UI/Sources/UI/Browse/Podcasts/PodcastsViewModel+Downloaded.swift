import Foundation
import Persistence

// MARK: - DownloadedRow

/// One row of the Downloaded list: the episode with its show's title beside
/// it, so every sortable column is a plain key path (#651).
public struct DownloadedRow: Identifiable, Hashable, Sendable {
    public let item: EpisodeListItem
    /// Feed content, rendered verbatim.
    public let showTitle: String

    public var id: EpisodeListItem.ID {
        self.item.id
    }

    public var title: String {
        self.item.episode.title
    }

    /// Unknown dates sort as the oldest.
    public var published: Double {
        self.item.episode.publishedAt ?? 0
    }

    /// Unknown lengths sort as the shortest.
    public var length: Double {
        self.item.episode.duration ?? 0
    }
}

// MARK: - DownloadedShowGroup

/// One show's downloads, for the Downloaded list grouped by show (#651).
public struct DownloadedShowGroup: Identifiable, Equatable, Sendable {
    /// The show's `podcasts.id`.
    public let id: Int64
    /// Feed content, rendered verbatim.
    public let title: String
    public let rows: [DownloadedRow]
}

// MARK: - Downloaded list sort

/// The Downloaded list's column sort, and its round trip through the one
/// string `@AppStorage` keeps (`KeyPathComparator` is not `Codable`).
public enum DownloadedSort {
    /// Newest first, as the list opens before anyone clicks a heading.
    public static let defaultOrder = [KeyPathComparator(\DownloadedRow.published, order: .reverse)]

    /// Each sortable column by its stored name. Titles compare as Finder does.
    private static let columns: [(name: String, comparator: KeyPathComparator<DownloadedRow>)] = [
        ("episode", KeyPathComparator(\DownloadedRow.title, comparator: .localizedStandard)),
        ("show", KeyPathComparator(\DownloadedRow.showTitle, comparator: .localizedStandard)),
        ("published", KeyPathComparator(\DownloadedRow.published)),
        ("length", KeyPathComparator(\DownloadedRow.length)),
    ]

    /// The sort a stored string names, e.g. `"show.forward"`; the default for
    /// anything else.
    public static func order(from raw: String) -> [KeyPathComparator<DownloadedRow>] {
        let parts = raw.split(separator: ".").map(String.init)
        guard parts.count == 2, var comparator = columns.first(where: { $0.name == parts[0] })?.comparator else {
            return self.defaultOrder
        }
        comparator.order = parts[1] == "reverse" ? .reverse : .forward
        return [comparator]
    }

    /// The string that stores `order`'s primary column, or "" when it names
    /// no known column.
    public static func rawValue(for order: [KeyPathComparator<DownloadedRow>]) -> String {
        guard let first = order.first,
              let name = columns.first(where: { $0.comparator.keyPath == first.keyPath })?.name else { return "" }
        return "\(name).\(first.order == .reverse ? "reverse" : "forward")"
    }
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
    /// matched on episode or show title, then sorted by the clicked column.
    /// The sort is stable over the newest-first input, so rows that tie on
    /// the column (one show's episodes, say) stay newest first.
    static func visibleDownloads(
        _ items: [EpisodeListItem],
        showFilter: Int64?,
        query: String,
        sortOrder: [KeyPathComparator<DownloadedRow>],
        showTitles: [Int64: String]
    ) -> [DownloadedRow] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let rows = items.compactMap { item -> DownloadedRow? in
            if let showFilter, item.episode.podcastID != showFilter {
                return nil
            }
            let showTitle = showTitles[item.episode.podcastID] ?? ""
            guard trimmed.isEmpty
                || item.episode.title.localizedCaseInsensitiveContains(trimmed)
                || showTitle.localizedCaseInsensitiveContains(trimmed) else { return nil }
            return DownloadedRow(item: item, showTitle: showTitle)
        }
        return rows.sorted(using: sortOrder)
    }

    /// `visible` split into one group per show, shows by title, each group
    /// in the list's own order.
    static func groupedDownloads(_ visible: [DownloadedRow]) -> [DownloadedShowGroup] {
        var order: [Int64] = []
        var byShow: [Int64: [DownloadedRow]] = [:]
        for row in visible {
            let id = row.item.episode.podcastID
            if byShow[id] == nil {
                order.append(id)
            }
            byShow[id, default: []].append(row)
        }
        return order
            .map { DownloadedShowGroup(id: $0, title: byShow[$0]?.first?.showTitle ?? "", rows: byShow[$0] ?? []) }
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
