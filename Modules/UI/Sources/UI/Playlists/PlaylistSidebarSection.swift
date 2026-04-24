import Library
import Persistence
import SwiftUI

// MARK: - PlaylistSidebarSection

/// Renders the "Playlists" section in the sidebar.
///
/// Hierarchy is flattened manually (rather than using `OutlineGroup`) so the
/// enclosing `List` can still drive a `selection` on `SidebarDestination`.
public struct PlaylistSidebarSection: View {
    @ObservedObject public var vm: PlaylistSidebarViewModel
    public let smartPlaylistService: SmartPlaylistService

    public init(vm: PlaylistSidebarViewModel, smartPlaylistService: SmartPlaylistService) {
        self.vm = vm
        self.smartPlaylistService = smartPlaylistService
    }

    public var body: some View {
        Section {
            if self.vm.nodes.isEmpty {
                Text("No playlists yet")
                    .font(Typography.footnote)
                    .foregroundStyle(Color.textTertiary)
                    .padding(.vertical, 2)
            } else {
                ForEach(self.vm.flattened(), id: \.node.id) { entry in
                    self.row(for: entry.node, depth: entry.depth)
                }
            }
        } header: {
            HStack {
                Text("Playlists")
                Spacer()
                Menu {
                    Button("New Playlist") { self.vm.beginNewPlaylist() }
                    Button("New Smart Playlist") { self.vm.beginNewSmartPlaylist() }
                    Button("New Folder") { self.vm.beginNewFolder() }
                } label: {
                    Image(systemName: "plus")
                        .font(Typography.footnote)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("New Playlist or Folder")
                .accessibilityIdentifier(A11y.PlaylistSidebar.addButton)
            }
        }
        .task { await self.vm.reload() }
        .sheet(isPresented: Binding(
            get: { self.vm.isPresentingNewPlaylist },
            set: { self.vm.isPresentingNewPlaylist = $0 }
        )) {
            NewPlaylistSheet(
                kind: .playlist,
                isPresented: Binding(
                    get: { self.vm.isPresentingNewPlaylist },
                    set: { self.vm.isPresentingNewPlaylist = $0 }
                ),
                parentID: self.vm.newPlaylistParent
            ) { name in
                await self.vm.createPlaylist(name: name)
            }
        }
        .sheet(isPresented: Binding(
            get: { self.vm.isPresentingNewFolder },
            set: { self.vm.isPresentingNewFolder = $0 }
        )) {
            NewPlaylistSheet(
                kind: .folder,
                isPresented: Binding(
                    get: { self.vm.isPresentingNewFolder },
                    set: { self.vm.isPresentingNewFolder = $0 }
                ),
                parentID: self.vm.newPlaylistParent
            ) { name in
                await self.vm.createFolder(name: name)
            }
        }
        .sheet(isPresented: Binding(
            get: { self.vm.isPresentingNewSmartPlaylist },
            set: { self.vm.isPresentingNewSmartPlaylist = $0 }
        )) {
            NewSmartPlaylistSheet(
                service: self.smartPlaylistService
            ) { _ in
                await self.vm.reload()
                self.vm.isPresentingNewSmartPlaylist = false
            }
        }
        .sheet(item: Binding(
            get: { self.vm.renameTarget },
            set: { self.vm.renameTarget = $0 }
        )) { _ in
            RenamePlaylistSheet(target: Binding(
                get: { self.vm.renameTarget },
                set: { self.vm.renameTarget = $0 }
            )) { node, newName in
                await self.vm.rename(node, to: newName)
            }
        }
        .confirmationDialog(
            "Delete Playlist",
            isPresented: Binding(
                get: { self.vm.deleteTarget != nil },
                set: { newValue in if !newValue { self.vm.deleteTarget = nil } }
            ),
            presenting: self.vm.deleteTarget
        ) { target in
            Button("Delete", role: .destructive) {
                Task { await self.vm.delete(target) }
            }
            Button("Cancel", role: .cancel) {
                self.vm.deleteTarget = nil
            }
        } message: { target in
            Text("Delete \"\(target.name)\"? Tracks remain in your library.")
        }
        .confirmationDialog(
            "Delete Folder and Contents",
            isPresented: Binding(
                get: { self.vm.deleteRecursiveTarget != nil },
                set: { newValue in if !newValue { self.vm.deleteRecursiveTarget = nil } }
            ),
            presenting: self.vm.deleteRecursiveTarget
        ) { target in
            Button("Delete Folder and Contents", role: .destructive) {
                Task { await self.vm.delete(target, recursive: true) }
            }
            Button("Cancel", role: .cancel) {
                self.vm.deleteRecursiveTarget = nil
            }
        } message: { target in
            Text("Delete \"\(target.name)\" and all playlists inside it? This cannot be undone. Tracks remain in your library.")
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(for node: PlaylistNode, depth: Int) -> some View {
        if node.kind == .folder {
            PlaylistFolderRow(node: node, depth: depth, vm: self.vm)
                .tag(SidebarDestination.playlist(node.id))
        } else if node.kind == .smart {
            PlaylistRow(node: node, depth: depth, vm: self.vm)
                .tag(SidebarDestination.smartPlaylist(node.id))
        } else {
            PlaylistRow(node: node, depth: depth, vm: self.vm)
                .tag(SidebarDestination.playlist(node.id))
        }
    }
}
