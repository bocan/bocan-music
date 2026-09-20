import Foundation
import Persistence

// MARK: - Downloads

/// The view model's download concerns: the per-show auto-download setting, and
/// the live progress of a running download (#551). Split out of
/// `PodcastsViewModel.swift` for file_length headroom, as
/// `PodcastsViewModel+ContinueListening.swift` was.
public extension PodcastsViewModel {
    /// The key ``PodcastsViewModel/downloadProgress`` is keyed by, and the id
    /// of ``UIEpisodeDownloadProgress``.
    static func downloadKey(podcastID: Int64, guid: String) -> String {
        "\(podcastID)/\(guid)"
    }

    /// Toggles auto-download for the open show.
    func toggleAutoDownload(_ on: Bool) async {
        guard let id = currentShow?.id else { return }
        await self.setAutoDownload(on, podcastID: id)
    }

    /// Sets auto-download for a specific show (used by the per-show settings sheet,
    /// which may be opened from the grid where there is no `currentShow`).
    func setAutoDownload(_ on: Bool, podcastID: Int64) async {
        do {
            try await self.actions?.setAutoDownload(on, podcastID: podcastID)
            if self.currentShow?.id == podcastID {
                self.currentShow?.autoDownload = on
            }
        } catch {
            self.log.error("podcasts.setAutoDownload.failed", ["id": podcastID, "error": String(reflecting: error)])
        }
    }
}

extension PodcastsViewModel {
    /// The seam is single-consumer, so this subscribes once: the guard makes a
    /// second `loadSubscribed()` a no-op rather than a second subscriber, which
    /// would divide the elements with the first (#545).
    func startObserveDownloadProgress() {
        guard self.downloadProgressTask == nil, let actions else { return }
        self.downloadProgressTask = Task { [weak self] in
            let stream = await actions.downloadProgress()
            for await event in stream {
                guard let self else { return }
                if Task.isCancelled {
                    return
                }
                self.apply(event)
            }
        }
    }

    private func apply(_ event: UIEpisodeDownloadProgress) {
        let key = Self.downloadKey(podcastID: event.podcastID, guid: event.guid)
        switch event.status {
        case .queued, .downloading:
            self.downloadProgress[key] = event.fractionComplete

        case .downloaded, .failed, .none:
            // The persisted state carries these; a stale fraction would leave
            // a part-filled ring on a finished episode.
            self.downloadProgress.removeValue(forKey: key)
        }
    }
}
