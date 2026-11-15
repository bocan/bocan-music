import SwiftUI

// MARK: - JellyfinSidebarRows

/// The Jellyfin servers inside the Sources section (ADR-097, slice 3).
///
/// Each server is one disclosure row with the same status dot, context menu and
/// shortcut as a Subsonic server, and expands into exactly nine rows. The view
/// holds the model with `@ObservedObject` and reads it directly: the model is
/// not forwarded through `LibraryViewModel`, so reading it from anywhere else
/// would leave the rows stale.
///
/// `SubsonicSidebarSection` hosts this view through its `extraServerRows`
/// parameter, so a Subsonic-only user sees no change.
struct JellyfinSidebarRows: View {
    @ObservedObject var model: JellyfinSourceModel
    @Binding var expandedServers: Set<UUID>
    /// Jellyfin shortcuts continue after the Subsonic ones: the first index is
    /// the number of Subsonic servers.
    let firstShortcutIndex: Int
    var onRefreshServer: ((UUID) -> Void)?
    var onTestServerConnection: ((UUID) -> Void)?
    var onEditServer: ((UUID) -> Void)?
    var onDisableServerInSidebar: ((UUID) -> Void)?
    var onRemoveServer: ((JellyfinSidebarServer) -> Void)?

    var body: some View {
        ForEach(Array(self.model.servers.enumerated()), id: \.element.id) { index, server in
            self.serverRows(for: server, shortcutIndex: self.firstShortcutIndex + index)
        }
    }

    // MARK: - Server

    @ViewBuilder
    private func serverRows(for server: JellyfinSidebarServer, shortcutIndex: Int) -> some View {
        let binding = Binding<Bool>(
            get: { self.expandedServers.contains(server.id) },
            set: { newValue in
                if newValue {
                    self.expandedServers.insert(server.id)
                } else {
                    self.expandedServers.remove(server.id)
                }
            }
        )
        let state = self.model.connectionStates[server.id] ?? .unknown

        self.disclosureButton(for: server, binding: binding, state: state, shortcutIndex: shortcutIndex)

        if binding.wrappedValue {
            ForEach(Self.rows(for: server.id), id: \.destination) { row in
                Label(row.label, systemImage: row.symbol)
                    .font(Typography.body)
                    .padding(.leading, 18)
                    .tag(row.destination)
                    .accessibilityLabel(row.label)
            }
        }
    }

    /// One row of a server's subtree.
    struct Row {
        let destination: SidebarDestination
        let symbol: String
        let label: String
    }

    /// The nine rows of a Jellyfin server, with the Subsonic icons. A Jellyfin
    /// server has no Internet Radio, Podcasts or Bookmarks row.
    static func rows(for id: UUID) -> [Row] {
        [
            Row(destination: .jellyfinSongs(id), symbol: "music.note", label: L10n.string("Songs")),
            Row(destination: .jellyfinAlbums(id), symbol: "square.grid.2x2", label: L10n.string("Albums")),
            Row(destination: .jellyfinArtists(id), symbol: "music.mic", label: L10n.string("Artists")),
            Row(destination: .jellyfinGenres(id), symbol: "tag", label: L10n.string("Genres")),
            Row(destination: .jellyfinPlaylists(id), symbol: "music.note.list", label: L10n.string("Playlists")),
            Row(destination: .jellyfinStarred(id), symbol: "star", label: L10n.string("Starred")),
            Row(destination: .jellyfinRandom(id), symbol: "shuffle", label: L10n.string("Random")),
            Row(
                destination: .jellyfinRecentlyAdded(id),
                symbol: "clock.badge.checkmark",
                label: L10n.string("Recently Added")
            ),
            Row(
                destination: .jellyfinMostPlayed(id),
                symbol: "chart.line.uptrend.xyaxis",
                label: L10n.string("Most Played")
            ),
        ]
    }

    private func disclosureButton(
        for server: JellyfinSidebarServer,
        binding: Binding<Bool>,
        state: SubsonicSidebarConnectionState,
        shortcutIndex: Int
    ) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { binding.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: binding.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.textTertiary)
                    .frame(width: 10)
                Image(systemName: "server.rack")
                    .frame(width: 16)
                Text(server.name)
                    .font(Typography.body)
                    .lineLimit(1)
                Spacer(minLength: 4)
                SubsonicStatusDot(state: state)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.string("\(server.name) (\(state.displayLabel))"))
        .accessibilityLabel(server.name)
        .accessibilityValue(L10n.string(
            "\(state.displayLabel). \(binding.wrappedValue ? L10n.string("Expanded") : L10n.string("Collapsed"))"
        ))
        .modifier(JellyfinServerShortcut(index: shortcutIndex))
        .contextMenu { self.serverContextMenu(for: server) }
    }

    @ViewBuilder
    private func serverContextMenu(for server: JellyfinSidebarServer) -> some View {
        if let onRefreshServer {
            Button(L10n.string("Refresh")) { onRefreshServer(server.id) }
        }
        if let onTestServerConnection {
            Button(L10n.string("Test Connection")) { onTestServerConnection(server.id) }
        }
        if let onEditServer {
            Button(L10n.string("Edit\u{2026}")) { onEditServer(server.id) }
        }
        if let onDisableServerInSidebar {
            Divider()
            Button(L10n.string("Disable in Sidebar")) { onDisableServerInSidebar(server.id) }
        }
        if let onRemoveServer {
            Divider()
            Button(L10n.string("Remove\u{2026}"), role: .destructive) { onRemoveServer(server) }
        }
    }
}

// MARK: - JellyfinHiddenServerMenuItems

/// "Show <server>" items for the Hidden Sources submenu, one per hidden Jellyfin server.
struct JellyfinHiddenServerMenuItems: View {
    @ObservedObject var model: JellyfinSourceModel
    let onEnable: (UUID) -> Void

    var body: some View {
        ForEach(self.model.hiddenServers, id: \.id) { server in
            Button(L10n.string("Show \"\(server.name)\"")) { self.onEnable(server.id) }
                .help(L10n.string("Puts this server back in the sidebar."))
        }
    }
}

// MARK: - JellyfinServerShortcut

/// Binds Command-Shift-1 to Command-Shift-9 to a server's disclosure row. The
/// index counts across both kinds of server, so Jellyfin servers take the keys
/// the Subsonic servers leave free. An index past eight has no shortcut.
private struct JellyfinServerShortcut: ViewModifier {
    let index: Int

    func body(content: Content) -> some View {
        if (0 ... 8).contains(self.index), let key = String(self.index + 1).first {
            content.keyboardShortcut(KeyEquivalent(key), modifiers: [.command, .shift])
        } else {
            content
        }
    }
}
