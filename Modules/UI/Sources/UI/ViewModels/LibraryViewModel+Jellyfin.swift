import Foundation
import Jellyfin
import Playback

// MARK: - LibraryViewModel + Jellyfin playback

/// Jellyfin playback entry points on `LibraryViewModel` (ADR-097 slice 5). They
/// mirror the Subsonic ones: each song becomes a `.jellyfin` queue item, and the
/// App's `JellyfinStreamResolver` turns it into a cached local file when it plays.
public extension LibraryViewModel {
    /// Plays a list of songs from one server, starting at `index`.
    func play(jellyfinSongs songs: [JellyfinSong], serverID: UUID, startingAt index: Int = 0) async {
        guard let qp = self.queuePlayer else {
            self.playbackErrorMessage = L10n.string("Playback engine isn't available.")
            return
        }
        guard !songs.isEmpty else { return }
        let safeIndex = max(0, min(index, songs.count - 1))
        let items = songs.map { QueueItem.makeJellyfin(from: JellyfinSongDragPayload(song: $0, serverID: serverID)) }
        do {
            try await qp.play(items: items, startingAt: safeIndex, shuffle: self.nowPlaying.shuffleOn)
        } catch {
            let title = songs[safeIndex].title
            self.playbackErrorMessage = L10n.string("Could not play \"\(title)\" from this server.")
        }
    }

    /// Plays a list of search hits that may come from several servers. Each hit
    /// carries its own server, so each queue item streams from the right one.
    func play(jellyfinMultiSource hits: [JellyfinSongHit], startingAt index: Int = 0) async {
        guard let qp = self.queuePlayer else {
            self.playbackErrorMessage = L10n.string("Playback engine isn't available.")
            return
        }
        guard !hits.isEmpty else { return }
        let safeIndex = max(0, min(index, hits.count - 1))
        let items = hits.map { QueueItem.makeJellyfin(from: JellyfinSongDragPayload(song: $0.song, serverID: $0.serverID)) }
        do {
            try await qp.play(items: items, startingAt: safeIndex, shuffle: self.nowPlaying.shuffleOn)
        } catch {
            let title = hits[safeIndex].song.title
            self.playbackErrorMessage = L10n.string("Could not play \"\(title)\" from this server.")
        }
    }

    /// Appends streamed Jellyfin songs to the end of Up Next, from the payload
    /// of a drag out of a server's song table.
    func addJellyfinSongsToQueue(_ payloads: [JellyfinSongDragPayload]) async {
        guard let qp = self.queuePlayer, !payloads.isEmpty else { return }
        await qp.addToQueue(items: payloads.map { QueueItem.makeJellyfin(from: $0) })
        let text = payloads.count == 1
            ? L10n.string("Added \u{201C}\(payloads[0].title)\u{201D} to Up Next")
            : L10n.string("Added \(payloads.count) songs to Up Next")
        self.showToast(.init(text: text, kind: .success))
    }
}

// MARK: - QueueItem factory

extension QueueItem {
    /// Builds a `.jellyfin` queue item from a drag payload, which is also the
    /// field bundle for the play path. Like a Subsonic item it has no `tracks`
    /// row (`trackID` -1); the title, artist and album come from the payload.
    static func makeJellyfin(from payload: JellyfinSongDragPayload) -> QueueItem {
        let format = AudioSourceFormat(
            sampleRate: 44100,
            bitDepth: 16,
            channelCount: 2,
            isInterleaved: false,
            codec: "jellyfin"
        )
        return QueueItem(
            trackID: -1,
            bookmark: nil,
            fileURL: "jellyfin://\(payload.serverID.uuidString)/\(payload.songID)",
            duration: TimeInterval(payload.durationSeconds),
            sourceFormat: format,
            title: payload.title,
            artistName: payload.artist,
            albumName: payload.album,
            genre: payload.genre,
            playableSource: .jellyfin(serverID: payload.serverID, itemID: payload.songID)
        )
    }
}
