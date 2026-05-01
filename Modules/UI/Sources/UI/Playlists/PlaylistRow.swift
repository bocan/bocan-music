import Library
import SwiftUI

// MARK: - PlaylistRow

/// A leaf (manual or smart) playlist row in the sidebar.
public struct PlaylistRow: View {
    public let node: PlaylistNode
    public let depth: Int
    @ObservedObject public var vm: PlaylistSidebarViewModel
    @State private var draftName = ""
    @FocusState private var isRenameFieldFocused: Bool

    public init(node: PlaylistNode, depth: Int, vm: PlaylistSidebarViewModel) {
        self.node = node
        self.depth = depth
        self.vm = vm
    }

    public var body: some View {
        HStack(spacing: 6) {
            self.rowIcon

            self.nameView

            Spacer(minLength: 4)

            if self.node.trackCount > 0, !self.isInlineRenaming {
                Text("\(self.node.trackCount)")
                    .font(Typography.footnote)
                    .foregroundStyle(Color.textTertiary)
            }
        }
        .padding(.leading, CGFloat(self.depth) * 14)
        .focusable()
        .draggable(PlaylistDragPayload(
            playlistID: self.node.id,
            sourceFolderID: self.node.parentID
        ))
        .contextMenu { self.contextMenuContent }
        .overlay(
            TrackDropTarget(isActive: self.node.kind == .manual) { ids in
                Task { await self.vm.addTracks(ids, to: self.node.id) }
            }
        )
        .help(self.node.name)
        .accessibilityLabel("Playlist: \(self.node.name)")
        .accessibilityIdentifier(A11y.PlaylistSidebar.row(self.node.id))
        .onAppear { self.syncDraftName() }
        .onChange(of: self.vm.renamingPlaylistID) { _, newValue in
            if newValue == self.node.id {
                self.draftName = self.node.name
                self.isRenameFieldFocused = true
            } else if self.isRenameFieldFocused {
                self.isRenameFieldFocused = false
            }
        }
        .onKeyPress(.return) {
            guard !self.isInlineRenaming else { return .ignored }
            self.vm.beginInlineRename(self.node)
            self.draftName = self.node.name
            self.isRenameFieldFocused = true
            return .handled
        }
    }

    private var isInlineRenaming: Bool {
        self.vm.renamingPlaylistID == self.node.id
    }

    @ViewBuilder
    private var nameView: some View {
        if self.isInlineRenaming {
            TextField("Playlist Name", text: self.$draftName)
                .font(Typography.body)
                .textFieldStyle(.roundedBorder)
                .focused(self.$isRenameFieldFocused)
                .accessibilityLabel("Playlist name")
                .accessibilityIdentifier(A11y.PlaylistSidebar.newNameField)
                .onAppear {
                    self.draftName = self.node.name
                    self.isRenameFieldFocused = true
                }
                .onSubmit {
                    Task { await self.vm.commitInlineRename(self.node, proposedName: self.draftName) }
                }
                .onKeyPress(.escape) {
                    self.draftName = self.node.name
                    self.vm.cancelInlineRename()
                    return .handled
                }
        } else {
            Text(self.node.name)
                .font(Typography.body)
                .lineLimit(1)
        }
    }

    private func syncDraftName() {
        guard !self.isInlineRenaming else { return }
        self.draftName = self.node.name
    }

    private var accentColour: Color? {
        guard let hex = node.accentHex else { return nil }
        return Color(hex: hex)
    }

    /// Small thumbnail shown in the sidebar row: user cover art when set,
    /// otherwise the appropriate SF Symbol tinted with the accent colour.
    @ViewBuilder
    private var rowIcon: some View {
        if let path = node.coverArtPath {
            Artwork(artPath: path, seed: Int(self.node.id), size: 20)
                .frame(width: 20, height: 20)
        } else {
            Image(systemName: self.node.kind == .smart ? "sparkles" : "music.note.list")
                .foregroundStyle(self.accentColour ?? Color.textSecondary)
                .frame(width: 16)
        }
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        Button("Rename") { self.vm.renameTarget = self.node }
        Button("Duplicate") { Task { _ = await self.vm.duplicate(self.node) } }
        if self.node.kind == .manual {
            Button("Export…") {
                self.vm.onRequestExport?(self.node.id, self.node.name)
            }
            Menu("Sort Contents") {
                Button("By Title") {
                    Task { await self.vm.sortContents(self.node, by: .title) }
                }
                Button("By Artist") {
                    Task { await self.vm.sortContents(self.node, by: .artist) }
                }
                Button("By Date Added") {
                    Task { await self.vm.sortContents(self.node, by: .dateAdded) }
                }
            }
        }
        self.moveToFolderMenu
        Divider()
        Button("Set Cover Art…") {
            Task { await self.vm.setCoverArt(for: self.node) }
        }
        .help("Choose an image file to use as the cover art for this playlist")
        Button("Set Accent Colour…") {
            self.vm.accentColorTarget = self.node
        }
        .help("Set a custom accent colour for this playlist")
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
