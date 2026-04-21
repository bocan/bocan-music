import Library
import SwiftUI

// MARK: - AddToPlaylistMenu

/// A nested `Menu` listing the current playlist forest.  Each leaf, when
/// chosen, invokes `onAddToPlaylist` with the playlist's id.  Folders are
/// rendered as sub-menus containing their children.
public struct AddToPlaylistMenu: View {
    public let nodes: [PlaylistNode]
    public let onAddToPlaylist: (Int64) -> Void
    public let onNewPlaylistFromSelection: () -> Void

    public init(
        nodes: [PlaylistNode],
        onNewPlaylistFromSelection: @escaping () -> Void,
        onAddToPlaylist: @escaping (Int64) -> Void
    ) {
        self.nodes = nodes
        self.onNewPlaylistFromSelection = onNewPlaylistFromSelection
        self.onAddToPlaylist = onAddToPlaylist
    }

    public var body: some View {
        Menu("Add to Playlist") {
            Button("New Playlist from Selection…", action: self.onNewPlaylistFromSelection)
            if !self.nodes.isEmpty {
                Divider()
                ForEach(self.nodes, id: \.id) { node in
                    self.menuItem(for: node)
                }
            }
        }
    }

    @ViewBuilder
    private func menuItem(for node: PlaylistNode) -> some View {
        switch node.kind {
        case .folder:
            Menu(node.name) {
                ForEach(node.children, id: \.id) { child in
                    AnyView(self.menuItem(for: child))
                }
                if node.children.isEmpty {
                    Text("Empty folder")
                        .foregroundStyle(.secondary)
                }
            }

        case .smart:
            Button {
                // Smart playlists are not writable from Phase 6, but we render
                // them dimmed so the hierarchy reads correctly.
            } label: {
                Label(node.name, systemImage: "sparkles")
            }
            .disabled(true)

        case .manual:
            Button {
                self.onAddToPlaylist(node.id)
            } label: {
                Label(node.name, systemImage: "music.note.list")
            }
        }
    }
}
