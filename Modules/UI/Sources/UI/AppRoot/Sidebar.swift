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
            }

            Section {
                if self.vm.libraryRoots.isEmpty {
                    Text("No folders added")
                        .font(Typography.footnote)
                        .foregroundStyle(Color.textTertiary)
                        .padding(.vertical, 2)
                } else {
                    ForEach(self.vm.libraryRoots, id: \.id) { root in
                        self.folderRow(root)
                    }
                }
            } header: {
                HStack {
                    Text("Folders")
                    Spacer()
                    Button {
                        Task { await self.vm.addFolderByPicker() }
                    } label: {
                        Image(systemName: "plus")
                            .font(Typography.footnote)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Add music folder")
                }
            }

            PlaylistSidebarSection(vm: self.vm.playlistSidebar)
        }
        .listStyle(.sidebar)
        .frame(minWidth: Theme.sidebarMinWidth)
        .accessibilityIdentifier(A11y.Sidebar.list)
        .sheet(isPresented: self.newPlaylistBinding) {
            NewPlaylistSheet(
                kind: .playlist,
                isPresented: self.newPlaylistBinding,
                parentID: self.vm.playlistSidebar.newPlaylistParent
            ) { name in
                await self.vm.playlistSidebar.createPlaylist(name: name)
            }
        }
        .sheet(isPresented: self.newFolderBinding) {
            NewPlaylistSheet(
                kind: .folder,
                isPresented: self.newFolderBinding,
                parentID: self.vm.playlistSidebar.newPlaylistParent
            ) { name in
                await self.vm.playlistSidebar.createFolder(name: name)
            }
        }
        .sheet(item: self.renameTargetBinding) { _ in
            RenamePlaylistSheet(target: self.renameTargetBinding) { node, newName in
                await self.vm.playlistSidebar.rename(node, to: newName)
            }
        }
        .confirmationDialog(
            "Delete Playlist",
            isPresented: self.deleteConfirmBinding,
            presenting: self.vm.playlistSidebar.deleteTarget
        ) { target in
            Button("Delete", role: .destructive) {
                Task { await self.vm.playlistSidebar.delete(target) }
            }
            Button("Cancel", role: .cancel) {
                self.vm.playlistSidebar.deleteTarget = nil
            }
        } message: { target in
            Text("Delete \"\(target.name)\"? Tracks remain in your library.")
        }
    }

    private var newPlaylistBinding: Binding<Bool> {
        Binding(
            get: { self.vm.playlistSidebar.isPresentingNewPlaylist },
            set: { self.vm.playlistSidebar.isPresentingNewPlaylist = $0 }
        )
    }

    private var newFolderBinding: Binding<Bool> {
        Binding(
            get: { self.vm.playlistSidebar.isPresentingNewFolder },
            set: { self.vm.playlistSidebar.isPresentingNewFolder = $0 }
        )
    }

    private var renameTargetBinding: Binding<PlaylistNode?> {
        Binding(
            get: { self.vm.playlistSidebar.renameTarget },
            set: { self.vm.playlistSidebar.renameTarget = $0 }
        )
    }

    private var deleteConfirmBinding: Binding<Bool> {
        Binding(
            get: { self.vm.playlistSidebar.deleteTarget != nil },
            set: { newValue in
                if !newValue { self.vm.playlistSidebar.deleteTarget = nil }
            }
        )
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
