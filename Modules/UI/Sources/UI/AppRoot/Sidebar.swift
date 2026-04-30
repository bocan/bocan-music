import Library
import Persistence
import SwiftUI

// MARK: - Sidebar

/// The navigation sidebar listing Library, Recents, and Playlists sections.
///
/// Each row sends a `SidebarDestination` to `LibraryViewModel.selectDestination(_:)`.
public struct Sidebar: View {
    @ObservedObject public var vm: LibraryViewModel

    public init(vm: LibraryViewModel) {
        self.vm = vm
    }

    public var body: some View {
        List(selection: Binding(
            get: { self.vm.selectedDestination },
            set: { newValue in
                if let dest = newValue {
                    Task { await self.vm.selectDestination(dest) }
                }
            }
        )) {
            Section("Library") {
                self.sidebarRow(.songs, symbol: "music.note", label: "Songs")
                self.sidebarRow(.albums, symbol: "square.grid.2x2", label: "Albums")
                self.sidebarRow(.artists, symbol: "music.mic", label: "Artists")
                self.sidebarRow(.genres, symbol: "tag", label: "Genres")
                self.sidebarRow(.composers, symbol: "music.note.list", label: "Composers")
            }

            Section("Recents") {
                self.sidebarRow(.recentlyAdded, symbol: "clock", label: "Recently Added")
                self.sidebarRow(.recentlyPlayed, symbol: "clock.arrow.circlepath", label: "Recently Played")
                self.sidebarRow(.mostPlayed, symbol: "chart.bar", label: "Most Played")
            }

            Section("Queue") {
                self.sidebarRow(.upNext, symbol: "list.bullet.indent", label: "Up Next")
                    .overlay(TrackDropTarget { ids in
                        Task { await self.vm.addToQueue(trackIDs: ids) }
                    })
                    // Phase 5 audit L4: announce that this row is also a drop
                    // target for tracks dragged from the library.
                    .accessibilityHint("Shows the playback queue. Drop tracks here to add them to the end of the queue.")
            }

            PlaylistSidebarSection(vm: self.vm.playlistSidebar, smartPlaylistService: self.vm.smartPlaylistService)
        }
        .listStyle(.sidebar)
        .frame(minWidth: Theme.sidebarMinWidth)
        .accessibilityIdentifier(A11y.Sidebar.list)
    }

    // MARK: - Row builder

    private func sidebarRow(_ dest: SidebarDestination, symbol: String, label: String) -> some View {
        Label(label, systemImage: symbol)
            .font(Typography.body)
            .tag(dest)
            .accessibilityLabel(label)
    }

    private func folderRow(_ root: LibraryRoot) -> some View {
        Label {
            Text(URL(fileURLWithPath: root.path).lastPathComponent)
                .font(Typography.body)
                .lineLimit(1)
        } icon: {
            Image(systemName: "folder")
        }
        .help(root.path)
        .contextMenu {
            Button("Remove from Library", role: .destructive) {
                if let id = root.id {
                    Task { await self.vm.removeRoot(id: id) }
                }
            }
        }
    }
}
