import Persistence

// MARK: - Continue Listening (ADR-054)

/// The Continue Listening rail's view-model surface, split from the main file
/// for `file_length` headroom. `loadSubscribed()` calls the observation
/// starter; the rail view calls `resume`.
extension PodcastsViewModel {
    /// Keeps the Continue Listening rail live: a position write, mark-played,
    /// or unsubscribe re-emits and the rail follows with no manual refresh.
    func startObserveContinueListening(library: any PodcastLibraryDataSource) {
        self.continueListeningTask?.cancel()
        self.continueListeningTask = Task { [weak self] in
            let stream = await library.observeContinueListening()
            do {
                for try await items in stream {
                    guard let self else { return }
                    try Task.checkCancellation()
                    self.continueListening = items
                }
            } catch is CancellationError {
                // Expected when the task is cancelled on navigation.
            } catch {
                self?.log.warning(
                    "podcasts.observeContinueListening.failed",
                    ["error": String(reflecting: error)]
                )
            }
        }
    }

    /// Resumes an episode from the rail through the normal play path. The
    /// resolver seeks to the saved position on load (ADR-042), so no position
    /// is passed. The show is resolved from the live `subscribed` array, not a
    /// card-build-time snapshot, so a mid-session unsubscribe cannot resume a
    /// gone show.
    public func resume(_ item: ContinueListeningItem) async {
        guard let actions, let show = self.subscribed.first(where: { $0.id == item.podcastID }) else {
            self.log.warning("podcasts.resume.showMissing", ["podcastID": item.podcastID])
            return
        }
        // A minimal content row: the play path only reads guid, title, and
        // duration (the resolver keys playback off feed URL + guid).
        let episode = PodcastEpisode(
            podcastID: item.podcastID,
            guid: item.guid,
            title: item.episodeTitle,
            audioURL: "",
            duration: item.duration,
            addedAt: 0
        )
        await actions.play(episode: EpisodeListItem(episode: episode, state: nil), podcast: show)
    }
}
