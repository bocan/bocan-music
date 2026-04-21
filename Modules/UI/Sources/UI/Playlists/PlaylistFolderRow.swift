import Library
import SwiftUI

// MARK: - PlaylistFolderRow

/// A folder row in the sidebar with an expansion chevron.
public struct PlaylistFolderRow: View {
    public let node: PlaylistNode
    public let depth: Int
    @ObservedObject public var vm: PlaylistSidebarViewModel

    public init(node: PlaylistNode, depth: Int, vm: PlaylistSidebarViewModel) {
        self.node = node
        self.depth = depth
        self.vm = vm
    }

    public var body: some View {
        HStack(spacing: 4) {
            Button {
                self.vm.toggle(folderID: self.node.id)
            } label: {
                Image(systemName: self.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.textSecondary)
                    .frame(width: 12)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(self.isExpanded ? "Collapse folder" : "Expand folder")

            Image(systemName: "folder")
                .foregroundStyle(Color.textSecondary)
                .frame(width: 16)

            Text(self.node.name)
                .font(Typography.body)
                .lineLimit(1)

            Spacer(minLength: 4)
        }
        .padding(.leading, CGFloat(self.depth) * 14)
        .contextMenu { self.contextMenuContent }
        .accessibilityLabel("Folder: \(self.node.name)")
        .accessibilityIdentifier(A11y.PlaylistSidebar.folderRow(self.node.id))
    }

    private var isExpanded: Bool {
        self.vm.expandedFolders.contains(self.node.id)
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        Button("New Playlist in Folder") { self.vm.beginNewPlaylist(parent: self.node.id) }
        Button("New Subfolder") { self.vm.beginNewFolder(parent: self.node.id) }
        Divider()
        Button("Rename") { self.vm.renameTarget = self.node }
        Divider()
        Button("Delete Folder (Keep Contents)") { self.vm.deleteTarget = self.node }
        Button("Delete Folder and Contents", role: .destructive) {
            Task { await self.vm.delete(self.node, recursive: true) }
        }
    }
}
