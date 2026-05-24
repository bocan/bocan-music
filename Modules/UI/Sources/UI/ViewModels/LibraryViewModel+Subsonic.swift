import Foundation
import Playback
import Subsonic
import SwiftSonic

// MARK: - LibraryViewModel + Subsonic playback

/// Subsonic playback helpers on `LibraryViewModel`. Bridges Subsonic song
/// lists into the shared `QueuePlayer` via `.subsonic` `PlayableSource` items.
public extension LibraryViewModel {
    /// Plays a list of Subsonic songs by enqueuing them as `.subsonic`
    /// `PlayableSource` items (Phase 19 step 10).
    ///
    /// The `AudioEngine` stream cache (Phase 19 step 6) resolves each
    /// `.subsonic` source to a local playable URL on demand.
    func play(subsonicSongs songs: [Song], serverID: UUID, startingAt index: Int = 0) async {
        guard let qp = self.queuePlayer else {
            self.playbackErrorMessage = "Playback engine isn't available."
            return
        }
        guard !songs.isEmpty else { return }
        let safeIndex = max(0, min(index, songs.count - 1))
        let items = songs.map { QueueItem.makeSubsonic(from: $0, serverID: serverID) }
        do {
            try await qp.play(items: items, startingAt: safeIndex, shuffle: self.nowPlaying.shuffleOn)
        } catch {
            let title = songs[safeIndex].title
            self.playbackErrorMessage = "Could not play \"\(title)\" from this server."
        }
    }
}

// MARK: - QueueItem factory

extension QueueItem {
    /// Builds a `QueueItem` from a SwiftSonic `Song`, marking it as a
    /// `.subsonic` `PlayableSource` so the audio engine routes it through
    /// `SubsonicStreamCache`.
    static func makeSubsonic(from song: Song, serverID: UUID) -> QueueItem {
        let duration = TimeInterval(song.duration ?? 0)
        let fmt = AudioSourceFormat(
            sampleRate: 44100,
            bitDepth: 16,
            channelCount: 2,
            isInterleaved: false,
            codec: "subsonic"
        )
        return QueueItem(
            trackID: -1,
            bookmark: nil,
            fileURL: "subsonic://\(serverID.uuidString)/\(song.id)",
            duration: duration,
            sourceFormat: fmt,
            title: song.title,
            artistName: song.artist,
            albumName: song.album,
            genre: song.genre,
            playableSource: .subsonic(serverID: serverID, songID: song.id)
        )
    }
}
