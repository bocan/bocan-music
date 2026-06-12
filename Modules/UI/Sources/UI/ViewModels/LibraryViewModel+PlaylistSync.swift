import Foundation
import Library
import Persistence
import Playback

// MARK: - LibraryViewModel + Playlist Queue Sync

extension LibraryViewModel {
    /// Plays `tracks` from a manual playlist and starts synchronising the live queue
    /// with any subsequent membership edits (adds, removes, reorders).
    ///
    /// The sync observation runs until another queue-replacing play command fires,
    /// the playlist is deleted, or `stopPlaylistSync()` is called explicitly.
    public func play(
        tracks: [Track],
        fromPlaylistID playlistID: Int64,
        startingAt index: Int = 0,
        shuffle: Bool = false
    ) async {
        // play(tracks:) calls stopPlaylistSync() internally, so we start fresh.
        await self.play(tracks: tracks, startingAt: index, shuffle: shuffle)
        self.startPlaylistSync(playlistID: playlistID)
    }

    /// Cancels an active playlist-sync observation and clears `activePlaylistID`.
    ///
    /// Called automatically when any other queue-replacing play command fires.
    func stopPlaylistSync() {
        self.activePlaylistID = nil
        self.playlistSyncTask?.cancel()
        self.playlistSyncTask = nil
    }

    // MARK: - Internal

    func startPlaylistSync(playlistID: Int64) {
        self.activePlaylistID = playlistID
        self.playlistSyncTask?.cancel()
        let service = self.playlistService
        self.playlistSyncTask = Task { [weak self] in
            guard let self else { return }
            var isFirst = true
            do {
                for try await updatedTracks in await service.observe(playlistID) {
                    // Skip the initial emission - it reflects what was just loaded for play.
                    if isFirst { isFirst = false
                        continue
                    }
                    guard !Task.isCancelled else { return }
                    await self.syncQueueToPlaylist(updatedTracks: updatedTracks)
                }
            } catch is CancellationError {
                // Normal shutdown via stopPlaylistSync().
            } catch {
                self.log.debug("playlist.sync.ended", ["error": String(reflecting: error)])
                self.activePlaylistID = nil
            }
        }
    }

    // MARK: - Private

    private func syncQueueToPlaylist(updatedTracks: [Track]) async {
        guard let qp = self.queuePlayer else { return }
        let shuffleState = await qp.queue.shuffleState
        let currentItems = await qp.queue.items
        let artistNames = self.tracks.artistNames

        switch shuffleState {
        case .off:
            // Sequential mode: reorder the queue to match the updated playlist.
            // Existing QueueItems are reused (preserving UUIDs) so the Up Next
            // list animates cleanly. Newly-added tracks get fresh QueueItems.
            let pairs = currentItems.map { ($0.trackID, $0) }
            let existingByTrackID: [Int64: QueueItem] = Dictionary(pairs) { first, _ in first }
            let newItems: [QueueItem] = updatedTracks.compactMap { (track: Track) -> QueueItem? in
                guard let tid = track.id else { return nil }
                if let existing = existingByTrackID[tid] { return existing }
                let name = track.artistID.flatMap { artistNames[$0] }
                return QueueItem.make(from: track, artistName: name)
            }
            // Skip the reorder when the track order is unchanged.
            let newTrackIDs: [Int64] = newItems.map(\.trackID)
            let oldTrackIDs: [Int64] = currentItems.map(\.trackID)
            guard newTrackIDs != oldTrackIDs else { return }
            await qp.queue.reorder(to: newItems)

        case .on:
            // Shuffle mode: drop removed tracks, append new ones at the end
            // (in shuffled queues order is already randomised, so appending is fine).
            let queuedTrackIDs = Set(currentItems.map(\.trackID))
            let playlistTrackIDs = Set(updatedTracks.compactMap(\.id))

            let removedIDs = Set(
                currentItems
                    .filter { !playlistTrackIDs.contains($0.trackID) }
                    .map(\.id)
            )
            if !removedIDs.isEmpty {
                await qp.queue.remove(ids: removedIDs)
            }

            let newTracks = updatedTracks.filter { track in
                guard let tid = track.id else { return false }
                return !queuedTrackIDs.contains(tid)
            }
            if !newTracks.isEmpty {
                let newItems = newTracks.map { track -> QueueItem in
                    let name = track.artistID.flatMap { artistNames[$0] }
                    return QueueItem.make(from: track, artistName: name)
                }
                await qp.queue.append(newItems)
            }
        }
    }
}
