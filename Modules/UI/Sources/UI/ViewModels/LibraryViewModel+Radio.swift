import Foundation
import Persistence
import Playback

// MARK: - LibraryViewModel + Radio playback

/// Local radio-station playback on `LibraryViewModel` (phase 27-2). Bridges
/// catalog `RadioStation` rows into the shared `QueuePlayer` via the same
/// `.internetRadio` `PlayableSource` path the Subsonic station rows use.
public extension LibraryViewModel {
    /// Starts playback of a catalog radio station. The queue is replaced with
    /// a single open-ended item; nothing pre-caches and no scrobble fires.
    /// Live streams have no fixed duration and don't support seek, so the
    /// engine simply reads frames as they arrive.
    func play(radioStation station: RadioStation) async {
        guard let qp = self.queuePlayer else {
            self.playbackErrorMessage = L10n.string("Playback engine isn't available.")
            return
        }
        guard let url = URL(string: station.streamURL) else {
            self.playbackErrorMessage = L10n.string("\u{201C}\(station.name)\u{201D} has no valid stream URL.")
            return
        }
        let item = QueueItem.makeInternetRadio(
            name: station.name,
            streamURL: url,
            homePage: station.homePageURL
        )
        do {
            try await qp.play(items: [item], startingAt: 0, shuffle: false)
        } catch {
            self.playbackErrorMessage = L10n.string("Could not start \u{201C}\(station.name)\u{201D}.")
        }
    }
}

// MARK: - QueueItem factory

extension QueueItem {
    /// Builds a `QueueItem` representing an internet radio station, local or
    /// Subsonic. `duration = 0` flags the item as live: no scrobble, no
    /// gapless, no scrubbing in the now-playing UI.
    static func makeInternetRadio(name: String, streamURL: URL, homePage: String?) -> QueueItem {
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
            title: name,
            artistName: L10n.string("Internet Radio"),
            albumName: homePage,
            genre: nil,
            playableSource: .internetRadio(streamURL: streamURL)
        )
    }
}
