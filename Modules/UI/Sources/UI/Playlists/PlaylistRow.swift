import Library
import SwiftUI

// MARK: - PlaylistRow

/// A leaf (manual or smart) playlist row in the sidebar.
public struct PlaylistRow: View {
    public let node: PlaylistNode
    public let depth: Int
    @ObservedObject public var vm: PlaylistSidebarViewModel

    public init(node: PlaylistNode, depth: Int, vm: PlaylistSidebarViewModel) {
        self.node = node
        self.depth = depth
        self.vm = vm
    }

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: self.node.kind == .smart ? "sparkles" : "music.note.list")
                .foregroundStyle(self.accentColour ?? Color.textSecondary)
                .frame(width: 16)

            Text(self.node.name)
                .font(Typography.body)
                .lineLimit(1)

            Spacer(minLength: 4)

            if self.node.trackCount > 0 {
                Text("\(self.node.trackCount)")
                    .font(Typography.footnote)
                    .foregroundStyle(Color.textTertiary)
            }
        }
        .padding(.leading, CGFloat(self.depth) * 14)
        .contextMenu { self.contextMenuContent }
        .accessibilityLabel("Playlist: \(self.node.name)")
        .accessibilityIdentifier(A11y.PlaylistSidebar.row(self.node.id))
    }

    private var accentColour: Color? {
        guard let hex = node.accentHex else { return nil }
        return Color(hex: hex)
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        Button("Rename") { self.vm.renameTarget = self.node }
        Button("Duplicate") { Task { _ = await self.vm.duplicate(self.node) } }
        Divider()
        Button("Delete", role: .destructive) { self.vm.deleteTarget = self.node }
    }
}
