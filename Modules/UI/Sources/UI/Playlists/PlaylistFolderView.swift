import Library
import Persistence
import SwiftUI

// MARK: - PlaylistFolderView

/// Content pane shown when a playlist folder is selected in the sidebar.
///
/// Displays the folder's name and a browsable list of its direct children.
/// Clicking a child navigates to that playlist or sub-folder.  The folder
/// itself is never playable (no Play/Shuffle buttons).
public struct PlaylistFolderView: View {
    /// The folder node to display.  Sourced from `PlaylistSidebarViewModel`
    /// by `ContentPane` immediately before instantiation.
    public let node: PlaylistNode
    @ObservedObject public var library: LibraryViewModel

    public init(node: PlaylistNode, library: LibraryViewModel) {
        self.node = node
        self.library = library
    }

    public var body: some View {
        VStack(spacing: 0) {
            self.header
            Divider()
            if self.node.children.isEmpty {
                EmptyState(
                    symbol: "folder",
                    title: "Empty Folder",
                    message: "Drag playlists here or use \"New Playlist in Folder\" from the sidebar."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                self.childList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier(A11y.PlaylistFolderDetail.view)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "folder.fill")
                .font(.system(size: 40))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(self.node.name)
                    .font(Typography.title)
                    .lineLimit(1)
                Text(self.childCountLabel)
                    .font(Typography.footnote)
                    .foregroundStyle(Color.textSecondary)
            }

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .accessibilityIdentifier(A11y.PlaylistFolderDetail.header)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Folder: \(self.node.name), \(self.childCountLabel)")
    }

    // MARK: - Child list

    private var childList: some View {
        List(self.node.children) { child in
            Button {
                self.library.selectedDestination = self.destination(for: child)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: self.icon(for: child))
                        .foregroundStyle(Color.textSecondary)
                        .frame(width: 18)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(child.name)
                            .font(Typography.body)
                            .lineLimit(1)
                        Text(self.subtitle(for: child))
                            .font(Typography.footnote)
                            .foregroundStyle(Color.textSecondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.textTertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(self.accessibilityLabel(for: child))
            .accessibilityIdentifier(A11y.PlaylistFolderDetail.childRow(child.id))
            .help("Open \"\(child.name)\"")
        }
        .listStyle(.plain)
    }

    // MARK: - Helpers

    private var childCountLabel: String {
        let n = self.node.children.count
        return n == 1 ? "1 item" : "\(n) items"
    }

    private func destination(for child: PlaylistNode) -> SidebarDestination {
        switch child.kind {
        case .folder:
            .folder(child.id)

        case .smart:
            .smartPlaylist(child.id)

        case .manual:
            .playlist(child.id)
        }
    }

    private func icon(for child: PlaylistNode) -> String {
        switch child.kind {
        case .folder:
            "folder"

        case .smart:
            "sparkles"

        case .manual:
            "music.note.list"
        }
    }

    private func subtitle(for child: PlaylistNode) -> String {
        if child.kind == .folder {
            let n = child.children.count
            return n == 1 ? "1 item" : "\(n) items"
        }
        let n = child.trackCount
        return n == 1 ? "1 song" : "\(n) songs"
    }

    private func accessibilityLabel(for child: PlaylistNode) -> String {
        switch child.kind {
        case .folder:
            "Folder: \(child.name), \(self.subtitle(for: child))"

        case .smart:
            "Smart Playlist: \(child.name), \(self.subtitle(for: child))"

        case .manual:
            "Playlist: \(child.name), \(self.subtitle(for: child))"
        }
    }
}
