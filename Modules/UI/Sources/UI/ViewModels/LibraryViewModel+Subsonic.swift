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

    /// Appends streamed Subsonic songs to the end of the Up Next queue, building
    /// `.subsonic` queue items from the drag payload. Powers dragging a server's
    /// song rows into the queue (#332).
    func addSubsonicSongsToQueue(_ payloads: [SubsonicSongDragPayload]) async {
        guard let qp = self.queuePlayer, !payloads.isEmpty else { return }
        let items = payloads.map { QueueItem.makeSubsonic(from: $0) }
        await qp.addToQueue(items: items)
        let text = payloads.count == 1
            ? "Added \u{201C}\(payloads[0].title)\u{201D} to Up Next"
            : "Added \(payloads.count) songs to Up Next"
        self.showToast(.init(text: text, kind: .success))
    }

    /// Starts playback of a Subsonic internet radio station. The queue is
    /// replaced with a single open-ended item; nothing pre-caches and no
    /// scrobble fires. Live streams have no fixed duration and don't
    /// support seek — the engine simply reads frames as they arrive.
    func play(internetRadioStation station: InternetRadioStation, serverID: UUID) async {
        guard let qp = self.queuePlayer else {
            self.playbackErrorMessage = "Playback engine isn't available."
            return
        }
        guard let url = URL(string: station.streamUrl) else {
            self.playbackErrorMessage = "\u{201C}\(station.name)\u{201D} has no valid stream URL."
            return
        }
        let item = QueueItem.makeInternetRadio(station: station, serverID: serverID, streamURL: url)
        do {
            try await qp.play(items: [item], startingAt: 0, shuffle: false)
        } catch {
            self.playbackErrorMessage = "Could not start \u{201C}\(station.name)\u{201D}."
        }
    }

    /// Plays a heterogeneous list of Subsonic songs sourced from multiple
    /// servers. Each `SubsonicSongHit` carries its own `serverID` so the
    /// queue stamps the right server on each `QueueItem`.
    func play(subsonicMultiSource hits: [SubsonicSongHit], startingAt index: Int = 0) async {
        guard let qp = self.queuePlayer else {
            self.playbackErrorMessage = "Playback engine isn't available."
            return
        }
        guard !hits.isEmpty else { return }
        let safeIndex = max(0, min(index, hits.count - 1))
        let queueItems = hits.map { QueueItem.makeSubsonic(from: $0.song, serverID: $0.serverID) }
        do {
            try await qp.play(items: queueItems, startingAt: safeIndex, shuffle: self.nowPlaying.shuffleOn)
        } catch {
            let title = hits[safeIndex].song.title
            self.playbackErrorMessage = "Could not play \"\(title)\" from this server."
        }
    }
}

// MARK: - QueueItem factory

extension QueueItem {
    /// Builds a `QueueItem` representing a Subsonic internet radio station.
    /// `duration = 0` flags the item as live — no scrobble, no gapless,
    /// no scrubbing in the now-playing UI.
    static func makeInternetRadio(
        station: InternetRadioStation,
        serverID: UUID,
        streamURL: URL
    ) -> QueueItem {
        let fmt = AudioSourceFormat(
            sampleRate: 44100,
            bitDepth: 16,
            channelCount: 2,
            isInterleaved: false,
            codec: "stream"
        )
        return QueueItem(
            trackID: -1,
            bookmark: nil,
            fileURL: streamURL.absoluteString,
            duration: 0,
            sourceFormat: fmt,
            title: station.name,
            artistName: "Internet Radio",
            albumName: station.homePageUrl,
            genre: nil,
            playableSource: .internetRadio(streamURL: streamURL)
        )
    }

    /// Builds a `QueueItem` from a SwiftSonic `Song`, marking it as a
    /// `.subsonic` `PlayableSource` so the audio engine routes it through
    /// `SubsonicStreamCache`.
    static func makeSubsonic(from song: Song, serverID: UUID) -> QueueItem {
        self.makeSubsonic(from: SubsonicSongDragPayload(
            serverID: serverID,
            songID: song.id,
            title: song.title,
            artist: song.artist ?? "",
            album: song.album ?? "",
            genre: song.genre ?? "",
            durationSeconds: song.duration ?? 0
        ))
    }

    /// Builds a `.subsonic` `PlayableSource` queue item from a drag payload, which
    /// doubles as the field bundle for both the drag path and the play path (#332).
    static func makeSubsonic(from payload: SubsonicSongDragPayload) -> QueueItem {
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
            fileURL: "subsonic://\(payload.serverID.uuidString)/\(payload.songID)",
            duration: TimeInterval(payload.durationSeconds),
            sourceFormat: fmt,
            title: payload.title,
            artistName: payload.artist,
            albumName: payload.album,
            genre: payload.genre,
            playableSource: .subsonic(serverID: payload.serverID, songID: payload.songID)
        )
    }
}
