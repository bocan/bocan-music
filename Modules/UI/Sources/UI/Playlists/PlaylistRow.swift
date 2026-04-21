import AppKit
import Library
import SwiftUI
import UniformTypeIdentifiers

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
        .onDrop(of: [.plainText], isTargeted: nil) { providers in
            guard self.node.kind == .manual else { return false }
            for provider in providers {
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                    guard let data = item as? Data,
                          let string = String(data: data, encoding: .utf8) else { return }
                    let ids = string.split(separator: ",").compactMap { Int64($0) }
                    guard !ids.isEmpty else { return }
                    Task { @MainActor in await self.vm.addTracks(ids, to: self.node.id) }
                }
            }
            return true
        }
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
        self.moveToFolderMenu
        Divider()
        Button("Delete", role: .destructive) { self.vm.deleteTarget = self.node }
    }

    @ViewBuilder
    private var moveToFolderMenu: some View {
        let folders = self.vm.allFolders()
        if !folders.isEmpty {
            Divider()
            Menu("Move to Folder") {
                Button("Top Level") {
                    Task { await self.vm.move(self.node, toParent: nil) }
                }
                Divider()
                ForEach(folders, id: \.id) { folder in
                    Button(folder.name) {
                        Task { await self.vm.move(self.node, toParent: folder.id) }
                    }
                }
            }
        }
    }
}
