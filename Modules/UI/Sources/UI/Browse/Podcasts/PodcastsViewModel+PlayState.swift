import Foundation
import Persistence

// MARK: - Play state for a selection

/// Mark played / unplayed over a multi-row episode selection (#635). Split out
/// of `PodcastsViewModel.swift` for file_length headroom, as
/// `PodcastsViewModel+Downloads.swift` was.
public extension PodcastsViewModel {
    /// The open show's episodes whose ids are in `ids`, in list order.
    func selectedEpisodes(_ ids: Set<EpisodeListItem.ID>) -> [EpisodeListItem] {
        self.episodes.filter { ids.contains($0.id) }
    }

    /// The episodes in a selection that "Mark Selected as Played" would change:
    /// every one not already played, in-progress ones included. This matches the
    /// single-row menu, which offers Mark as Played for anything not played.
    static func episodesToMarkPlayed(_ items: [EpisodeListItem]) -> [EpisodeListItem] {
        items.filter { $0.state?.playState != .played }
    }

    /// The episodes in a selection that "Mark Selected as Unplayed" would change:
    /// the played ones. An in-progress episode keeps its place, as it does in the
    /// single-row menu, which offers Mark as Unplayed only for a played episode.
    static func episodesToMarkUnplayed(_ items: [EpisodeListItem]) -> [EpisodeListItem] {
        items.filter { $0.state?.playState == .played }
    }

    /// Marks `items` played or unplayed with one seam call per show, so the
    /// episode list refreshes once, not once per episode. The list only ever
    /// holds one show, but grouping keeps a cross-show caller correct.
    func setPlayed(_ played: Bool, episodes items: [EpisodeListItem]) async {
        guard let actions, !items.isEmpty else { return }
        let byShow = Dictionary(grouping: items, by: \.episode.podcastID)
        var failed = false
        for (podcastID, showItems) in byShow {
            let guids = showItems.map(\.episode.guid)
            do {
                if played {
                    try await actions.markPlayed(podcastID: podcastID, guids: guids)
                } else {
                    try await actions.markUnplayed(podcastID: podcastID, guids: guids)
                }
            } catch {
                self.log.error("podcasts.setPlayed.failed", [
                    "id": podcastID, "count": guids.count, "error": String(reflecting: error),
                ])
                failed = true
            }
        }
        if failed {
            self.reportPlayStateFailure(played: played)
        }
    }

    /// Marks one episode played. The single-row menus call this, not the seam,
    /// so a failed write reaches the listener (#640).
    func markPlayed(podcastID: Int64, guid: String) async {
        do {
            try await self.actions?.markPlayed(podcastID: podcastID, guid: guid)
        } catch {
            self.log.error("podcasts.markPlayed.failed", ["id": podcastID, "error": String(reflecting: error)])
            self.reportPlayStateFailure(played: true)
        }
    }

    /// Marks one episode unplayed, reporting a failed write as `markPlayed` does.
    func markUnplayed(podcastID: Int64, guid: String) async {
        do {
            try await self.actions?.markUnplayed(podcastID: podcastID, guid: guid)
        } catch {
            self.log.error("podcasts.markUnplayed.failed", ["id": podcastID, "error": String(reflecting: error)])
            self.reportPlayStateFailure(played: false)
        }
    }

    /// Marks every episode of the open show as played.
    func markAllPlayed() async {
        guard let id = currentShow?.id else { return }
        await self.markAllPlayed(podcastID: id)
    }

    /// Marks every episode of one show as played (the grid's context menu).
    func markAllPlayed(podcastID id: Int64) async {
        if await !self.markAllPlayedQuietly(podcastID: id) {
            self.reportPlayStateFailure(played: true)
        }
    }

    /// Marks every episode of every subscribed show as played. Backs the
    /// "Mark All as Played" toolbar action on the Podcasts home view. A show
    /// that fails does not stop the others, and the listener is told once.
    func markAllSubscribedPlayed() async {
        var failed = false
        for id in self.subscribed.compactMap(\.id) where await !self.markAllPlayedQuietly(podcastID: id) {
            failed = true
        }
        if failed {
            self.reportPlayStateFailure(played: true)
        }
    }

    /// - Returns: `false` when the write failed. The failure is logged here;
    ///   telling the listener is the caller's job, so a loop tells them once.
    private func markAllPlayedQuietly(podcastID id: Int64) async -> Bool {
        do {
            try await self.actions?.markAllPlayed(podcastID: id)
            return true
        } catch {
            self.log.error("podcasts.markAllPlayed.failed", ["id": id, "error": String(reflecting: error)])
            return false
        }
    }

    private func reportPlayStateFailure(played: Bool) {
        self.onActionFailed?(
            played ? L10n.string("Could not mark as played") : L10n.string("Could not mark as unplayed")
        )
    }
}
