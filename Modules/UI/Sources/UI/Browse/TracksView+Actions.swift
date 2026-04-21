import AppKit
import SwiftUI

// MARK: - TracksView context menu actions

extension TracksView {
    /// Assembles the `TrackContextMenuActions` struct that bridges the
    /// AppKit context menu in `TrackTable` to the library view-model.
    ///
    /// Each closure is called synchronously on the main thread by AppKit.
    /// Async library operations are wrapped in `Task { … }` inside the closures.
    var trackContextMenuActions: TrackContextMenuActions {
        let lib = self.library
        return TrackContextMenuActions(
            playNow: { track in
                Task { await lib.play(track: track) }
            },
            playNext: { tracks in
                Task { await lib.playNext(tracks: tracks) }
            },
            addToQueue: { tracks in
                Task { await lib.addToQueue(tracks: tracks) }
            },
            addToPlaylist: { playlistID, tracks in
                let ids = tracks.compactMap(\.id)
                Task { try? await lib.playlistService.addTracks(ids, to: playlistID) }
            },
            newPlaylistFromSelection: { _ in
                lib.playlistSidebar.beginNewPlaylist()
            },
            love: { _ in
                // TODO(phase-8): persist loved state
            },
            goToArtist: { artistID in
                Task { await lib.selectDestination(.artist(artistID)) }
            },
            goToAlbum: { albumID in
                Task { await lib.selectDestination(.album(albumID)) }
            },
            showInFinder: { track in
                if let url = URL(string: track.fileURL) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            },
            rescanFile: { track in
                if let id = track.id {
                    Task { await lib.rescanTrack(id: id) }
                }
            },
            getInfo: { tracks in
                lib.showInspector(tracks: tracks)
            },
            removeFromLibrary: { tracks in
                for track in tracks {
                    if let id = track.id {
                        Task { await lib.removeTrack(id: id) }
                    }
                }
            },
            deleteFromDisk: { track in
                if let id = track.id {
                    Task { await lib.deleteTrackFromDisk(id: id) }
                }
            },
            copy: { tracks in
                let tsv = tracks
                    .map { [$0.title ?? "", $0.genre ?? ""].joined(separator: "\t") }
                    .joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tsv, forType: .string)
            },
            toggleShuffle: { trackID, excluded in
                Task { await lib.setTrackExcludedFromShuffle(trackID: trackID, excluded: excluded) }
            }
        )
    }
}
