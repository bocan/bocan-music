import AppKit
import Persistence
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
        let removeFromPlaylistAction = self.removeFromPlaylist.map { remove in
            { tracks in
                Self.confirmRemoveFromPlaylist(tracks: tracks, remove: remove)
            }
        }
        return TrackContextMenuActions(
            playNow: { track in
                Task { await lib.play(track: track) }
            },
            playSingle: { track in
                // Replace the queue with just this single track — the
                // Option+double-click "play only this" gesture.
                Task { await lib.play(tracks: [track], startingAt: 0) }
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
            newPlaylistFromSelection: { tracks in
                let ids = tracks.compactMap(\.id)
                lib.playlistSidebar.beginNewPlaylist(trackIDs: ids)
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
                lib.showTagEditor(tracks: tracks)
            },
            identify: { track in
                lib.showIdentifyTrack(track)
            },
            removeFromLibrary: { tracks in
                Self.confirmRemoveFromLibrary(tracks: tracks, library: lib)
            },
            deleteFromDisk: { track in
                Self.confirmDeleteFromDisk(track: track, library: lib)
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
            },
            removeFromPlaylist: removeFromPlaylistAction
        )
    }

    // MARK: - Destructive confirmations

    /// `UserDefaults` key for "Don't ask again" on the soft-delete (Remove from
    /// Library) confirmation. Trash deletion is *never* suppressible — it
    /// touches the filesystem, so we always confirm.
    private static let suppressRemoveKey = "library.suppressRemoveConfirmation"

    /// Presents the soft-delete confirmation. Honours the suppression flag.
    /// Note: the flag only suppresses *Remove from Library* — trashing a file
    /// always asks, regardless.
    @MainActor
    static func confirmRemoveFromLibrary(tracks: [Track], library: LibraryViewModel) {
        let ids = tracks.compactMap(\.id)
        guard !ids.isEmpty else { return }

        let suppressed = UserDefaults.standard.bool(forKey: Self.suppressRemoveKey)
        if suppressed {
            for id in ids {
                Task { await library.removeTrack(id: id) }
            }
            return
        }

        let alert = NSAlert()
        if tracks.count == 1 {
            let title = tracks.first?.title ?? "track"
            alert.messageText = "Remove “\(title)” from library?"
        } else {
            alert.messageText = "Remove \(tracks.count) tracks from library?"
        }
        alert.informativeText = "The files will stay on disk and can be re-added later by rescanning the folder."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don’t ask again"

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        if alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(true, forKey: Self.suppressRemoveKey)
        }

        for id in ids {
            Task { await library.removeTrack(id: id) }
        }
    }

    /// Presents the trash-and-remove confirmation for a single track. Always
    /// asks — there's no "don't ask again" path because the action is
    /// destructive on disk.
    @MainActor
    static func confirmDeleteFromDisk(track: Track, library: LibraryViewModel) {
        guard let id = track.id else { return }
        let title = track.title ?? "this track"

        let alert = NSAlert()
        alert.messageText = "Move “\(title)” to Trash and remove from Bòcan?"
        alert.informativeText = "The file will be moved to the Trash. You can restore it from the Trash until you empty it."
        alert.alertStyle = .warning
        let trashButton = alert.addButton(withTitle: "Move to Trash")
        trashButton.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        Task { @MainActor in
            let outcome = await library.deleteTrackFromDisk(id: id)
            // Phase 5.5 audit M3: when trashing fails (external volume,
            // permission denied, …) we used to silently log and leave the
            // file on disk. Offer an explicit fallback to permanent deletion
            // so the user actually finds out and can choose what to do.
            if case let .trashFailed(error, _) = outcome {
                Self.confirmPermanentDelete(track: track, error: error, library: library)
            }
        }
    }

    /// Secondary confirmation shown when `trashItem` fails. Asks the user
    /// whether to permanently delete the file. Only called from
    /// `confirmDeleteFromDisk` after the user has already confirmed the
    /// initial trash request.
    @MainActor
    private static func confirmPermanentDelete(
        track: Track,
        error: any Error,
        library: LibraryViewModel
    ) {
        guard let id = track.id else { return }
        let title = track.title ?? "this track"

        let alert = NSAlert()
        alert.messageText = "Move to Trash failed: \(error.localizedDescription)"
        alert.informativeText =
            "Permanently delete “\(title)”? This cannot be undone — the file will not be moved to the Trash."
        alert.alertStyle = .critical
        let deleteButton = alert.addButton(withTitle: "Delete Permanently")
        deleteButton.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Task { await library.permanentlyDeleteTrackFromDisk(id: id) }
    }
}
