import Foundation
import Persistence

// MARK: - Show notes on demand

/// The episode lists leave `descriptionHTML` nil: a list re-reads on every
/// position write during playback, and the notes are most of a row's bytes.
/// The notes sheets read them here, one episode at a time. Split out of
/// `PodcastsViewModel.swift` for file_length headroom.
extension PodcastsViewModel {
    /// One episode's show notes, or nil when it has none. A failed read logs
    /// and returns nil, and the sheet shows its own empty state.
    func showNotesHTML(for item: EpisodeListItem) async -> String? {
        if let html = item.episode.descriptionHTML {
            return html
        }
        guard let library else { return nil }
        let podcastID = item.episode.podcastID
        let guid = item.episode.guid
        // Outer nil: the read failed (logged). Inner nil: no notes.
        let read: String?? = await recoveredRead("podcasts.showNotes.failed") {
            try await library.showNotesHTML(podcastID: podcastID, guid: guid)
        }
        return read.flatMap(\.self)
    }

    /// `item` with its show notes read in, for a sheet that renders
    /// `descriptionHTML` straight from the item.
    func withShowNotes(_ item: EpisodeListItem) async -> EpisodeListItem {
        var full = item
        full.episode.descriptionHTML = await self.showNotesHTML(for: item)
        return full
    }
}
