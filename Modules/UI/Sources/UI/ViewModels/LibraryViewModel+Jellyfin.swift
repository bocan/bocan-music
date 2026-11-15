import Foundation
import Jellyfin

// MARK: - LibraryViewModel + Jellyfin playback

/// Jellyfin playback entry points on `LibraryViewModel` (ADR-097).
///
/// Slice 4 builds the browse views and the calls they make. Playing a Jellyfin
/// song needs the `.jellyfin` `PlayableSource` and its stream resolver, which
/// are slice 5. Until then these methods tell the user, in plain words, that
/// playback is not ready, so a double-click never looks like it did nothing.
/// Slice 5 replaces the bodies and keeps the signatures.
public extension LibraryViewModel {
    /// Plays a list of songs from one server, starting at `index`.
    func play(jellyfinSongs songs: [JellyfinSong], serverID: UUID, startingAt index: Int = 0) async {
        guard !songs.isEmpty else { return }
        self.playbackErrorMessage = L10n.string("Playing from Jellyfin is not ready yet.")
    }

    /// Plays a list of search hits that may come from several servers.
    func play(jellyfinMultiSource hits: [JellyfinSongHit], startingAt index: Int = 0) async {
        guard !hits.isEmpty else { return }
        self.playbackErrorMessage = L10n.string("Playing from Jellyfin is not ready yet.")
    }
}
