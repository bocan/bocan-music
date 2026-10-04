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
        for (podcastID, showItems) in byShow {
            let guids = showItems.map(\.episode.guid)
            if played {
                await actions.markPlayed(podcastID: podcastID, guids: guids)
            } else {
                await actions.markUnplayed(podcastID: podcastID, guids: guids)
            }
        }
    }
}
