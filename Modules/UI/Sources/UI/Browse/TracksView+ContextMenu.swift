import AppKit
import Library
import Persistence
import SwiftUI

// MARK: - TracksView context menu

extension TracksView {
    @ViewBuilder
    func trackContextMenu(ids: Set<Track.ID>) -> some View {
        let selected = self.vm.tracks.filter { ids.contains($0.id) }
        let first = selected.first
        self.trackContextMenuQueue(first: first, selected: selected)
        Divider()
        self.trackContextMenuNavigate(first: first)
        Divider()
        self.trackContextMenuLibrary(first: first, selected: selected)
        Divider()
        self.trackContextMenuEdit(first: first, selected: selected)
    }

    @ViewBuilder
    private func trackContextMenuNavigate(first: Track?) -> some View {
        if let artistID = first?.artistID {
            Button("Go to Artist") {
                Task { await self.library.selectDestination(.artist(artistID)) }
            }
        }
        if let albumID = first?.albumID {
            Button("Go to Album") {
                Task { await self.library.selectDestination(.album(albumID)) }
            }
        }
    }

    @ViewBuilder
    private func trackContextMenuQueue(first: Track?, selected: [Track]) -> some View {
        if let track = first {
            Button("Play Now") {
                Task { await self.library.play(track: track) }
            }
        }
        Button("Play Next") {
            Task { await self.library.playNext(tracks: selected) }
        }
        .disabled(selected.isEmpty)
        Button("Add to Queue") {
            Task { await self.library.addToQueue(tracks: selected) }
        }
        .disabled(selected.isEmpty)
        AddToPlaylistMenu(
            nodes: self.library.playlistSidebar.nodes,
            onNewPlaylistFromSelection: {
                self.library.playlistSidebar.beginNewPlaylist()
            },
            onAddToPlaylist: { playlistID in
                let ids = selected.compactMap(\.id)
                Task { try? await self.library.playlistService.addTracks(ids, to: playlistID) }
            }
        )
        if let first {
            Divider()
            Button(first.loved ? "Unlove" : "Love") {
                // TODO(phase-8): persist loved state
            }
        }
    }

    @ViewBuilder
    private func trackContextMenuLibrary(first: Track?, selected: [Track]) -> some View {
        if let first {
            Button("Show in Finder") {
                if let url = URL(string: first.fileURL) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            .keyboardShortcut(KeyBindings.revealInFinder)
            Button("Re-scan File") {
                if let id = first.id {
                    Task { await self.library.rescanTrack(id: id) }
                }
            }
        }
        Button("Get Info") {
            self.library.showInspector(tracks: selected)
        }
        .keyboardShortcut(KeyBindings.getInfo)
        .disabled(selected.isEmpty)
    }

    @ViewBuilder
    private func trackContextMenuEdit(first: Track?, selected: [Track]) -> some View {
        Button("Remove from Library") {
            for track in selected {
                if let id = track.id {
                    Task { await self.library.removeTrack(id: id) }
                }
            }
        }
        .disabled(selected.isEmpty)
        if let first {
            Button("Delete from Disk", role: .destructive) {
                if let id = first.id {
                    Task { await self.library.deleteTrackFromDisk(id: id) }
                }
            }
        }
        Divider()
        Button("Copy") {
            let tsv = selected.map { [$0.title ?? "", $0.genre ?? ""].joined(separator: "\t") }.joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(tsv, forType: .string)
        }
    }
}
