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

    public init(vm: PlaylistSidebarViewModel) {
        self.vm = vm
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
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(for node: PlaylistNode, depth: Int) -> some View {
        if node.kind == .folder {
            PlaylistFolderRow(node: node, depth: depth, vm: self.vm)
                .tag(SidebarDestination.playlist(node.id))
        } else {
            PlaylistRow(node: node, depth: depth, vm: self.vm)
                .tag(SidebarDestination.playlist(node.id))
        }
    }
}
