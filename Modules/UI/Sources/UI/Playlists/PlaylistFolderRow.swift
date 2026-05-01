import Library
import SwiftUI

// MARK: - PlaylistFolderRow

/// A folder row in the sidebar with an expansion chevron.
public struct PlaylistFolderRow: View {
    public let node: PlaylistNode
    public let depth: Int
    @ObservedObject public var vm: PlaylistSidebarViewModel
    @State private var draftName = ""
    @FocusState private var isRenameFieldFocused: Bool

    /// `true` while a `PlaylistDragPayload` hovers over this row.
    @State private var isDropTargeted = false
    /// Cancellable task that spring-loads the folder open after a short hover.
    @State private var springLoadTask: Task<Void, Never>?

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
            .help(self.isExpanded ? "Collapse folder" : "Expand folder")
            .accessibilityLabel(self.isExpanded ? "Collapse folder" : "Expand folder")
            .accessibilityValue(self.isExpanded ? "Expanded" : "Collapsed")

            Image(systemName: self.isDropTargeted ? "folder.fill.badge.plus" : "folder")
                .foregroundStyle(self.isDropTargeted ? Color.accentColor : Color.textSecondary)
                .frame(width: 16)
                .animation(.easeInOut(duration: 0.15), value: self.isDropTargeted)

            self.nameView

            Spacer(minLength: 4)
        }
        .padding(.leading, CGFloat(self.depth) * 14)
        .padding(.vertical, 2)
        .focusable()
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(self.isDropTargeted ? Color.accentColor.opacity(0.15) : Color.clear)
                .padding(.horizontal, -4)
                .animation(.easeInOut(duration: 0.15), value: self.isDropTargeted)
        )
        .dropDestination(for: PlaylistDragPayload.self) { items, _ in
            guard let payload = items.first else { return false }
            // Skip if the playlist is already in this folder (no-op move).
            guard payload.sourceFolderID != self.node.id else { return false }
            Task { await self.vm.move(playlistID: payload.playlistID, toFolder: self.node.id) }
            return true
        } isTargeted: { targeted in
            self.isDropTargeted = targeted
            if targeted {
                // Spring-load: auto-expand the folder after a 700 ms hover.
                self.springLoadTask = Task {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    guard !Task.isCancelled else { return }
                    self.vm.expand(folderID: self.node.id)
                }
            } else {
                self.springLoadTask?.cancel()
                self.springLoadTask = nil
            }
        }
        .contextMenu { self.contextMenuContent }
        .help(self.node.name)
        .accessibilityLabel("Folder: \(self.node.name)")
        .accessibilityIdentifier(A11y.PlaylistSidebar.folderRow(self.node.id))
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

    private var isExpanded: Bool {
        self.vm.expandedFolders.contains(self.node.id)
    }

    private var isInlineRenaming: Bool {
        self.vm.renamingPlaylistID == self.node.id
    }

    @ViewBuilder
    private var nameView: some View {
        if self.isInlineRenaming {
            TextField("Folder Name", text: self.$draftName)
                .font(Typography.body)
                .textFieldStyle(.roundedBorder)
                .focused(self.$isRenameFieldFocused)
                .accessibilityLabel("Folder name")
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

    @ViewBuilder
    private var contextMenuContent: some View {
        Button("New Playlist in Folder") { self.vm.beginNewPlaylist(parent: self.node.id) }
        Button("New Subfolder") { self.vm.beginNewFolder(parent: self.node.id) }
        Divider()
        Button("Rename") { self.vm.renameTarget = self.node }
        self.moveToFolderMenu
        Divider()
        Button("Delete Folder (Keep Contents)") { self.vm.deleteTarget = self.node }
        Button("Delete Folder and Contents", role: .destructive) {
            self.vm.deleteRecursiveTarget = self.node
        }
    }

    @ViewBuilder
    private var moveToFolderMenu: some View {
        let folders = self.vm.allFolders().filter { $0.id != self.node.id }
        if !folders.isEmpty {
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
