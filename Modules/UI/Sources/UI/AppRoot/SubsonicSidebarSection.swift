import SwiftUI

// MARK: - SubsonicSidebarSection

/// Renders the "Sources" sidebar section: one collapsible top-level
/// disclosure containing one further disclosure per Subsonic server. Each
/// server expands into the standard Songs / Albums / Artists / Genres rows.
///
/// The actual destination views land in Phase 19 step 10; step 9 only wires
/// the structure, selection tagging, and persisted expand/collapse.
public struct SubsonicSidebarSection: View {
    @Binding public var sectionExpanded: Bool
    @Binding public var expandedServers: Set<UUID>
    public let servers: [SubsonicSidebarServer]

    public init(
        sectionExpanded: Binding<Bool>,
        expandedServers: Binding<Set<UUID>>,
        servers: [SubsonicSidebarServer]
    ) {
        self._sectionExpanded = sectionExpanded
        self._expandedServers = expandedServers
        self.servers = servers
    }

    public var body: some View {
        Section {
            if self.sectionExpanded {
                if self.servers.isEmpty {
                    Text("No sources yet")
                        .font(Typography.footnote)
                        .foregroundStyle(Color.textTertiary)
                        .padding(.vertical, 2)
                        .accessibilityLabel("No Subsonic sources configured")
                } else {
                    ForEach(self.servers) { server in
                        self.serverRows(for: server)
                    }
                }
            }
        } header: {
            SidebarSectionHeader(
                title: "Sources",
                isExpanded: self.$sectionExpanded
            )
        }
    }

    @ViewBuilder
    private func serverRows(for server: SubsonicSidebarServer) -> some View {
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
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(server.name)
        .accessibilityValue(binding.wrappedValue ? "Expanded" : "Collapsed")

        if binding.wrappedValue {
            self.row(.subsonicSongs(server.id), symbol: "music.note", label: "Songs")
            self.row(.subsonicAlbums(server.id), symbol: "square.grid.2x2", label: "Albums")
            self.row(.subsonicArtists(server.id), symbol: "music.mic", label: "Artists")
            self.row(.subsonicGenres(server.id), symbol: "tag", label: "Genres")
            self.row(.subsonicPlaylists(server.id), symbol: "music.note.list", label: "Playlists")
            self.row(.subsonicStarred(server.id), symbol: "star", label: "Starred")
            self.row(.subsonicRandom(server.id), symbol: "shuffle", label: "Random")
            self.row(.subsonicRecentlyAdded(server.id), symbol: "clock.badge.checkmark", label: "Recently Added")
            self.row(.subsonicMostPlayed(server.id), symbol: "chart.line.uptrend.xyaxis", label: "Most Played")
            if server.supportsInternetRadio {
                self.row(.subsonicInternetRadio(server.id), symbol: "dot.radiowaves.left.and.right", label: "Internet Radio")
            }
            if server.supportsPodcasts {
                self.row(.subsonicPodcasts(server.id), symbol: "antenna.radiowaves.left.and.right", label: "Podcasts")
            }
            if server.supportsBookmarks {
                self.row(.subsonicBookmarks(server.id), symbol: "bookmark", label: "Bookmarks")
            }
        }
    }

    private func row(_ dest: SidebarDestination, symbol: String, label: String) -> some View {
        Label(label, systemImage: symbol)
            .font(Typography.body)
            .padding(.leading, 18)
            .tag(dest)
            .accessibilityLabel(label)
    }
}

// MARK: - SidebarSectionHeader

/// Click-to-collapse header used by every top-level sidebar section that
/// participates in `SidebarSectionExpansion`. Matches the visual idiom of
/// the existing Playlists header (chevron + label, no in-row controls).
struct SidebarSectionHeader: View {
    let title: String
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { self.isExpanded.toggle() }
        } label: {
            HStack(spacing: 4) {
                Text(self.title)
                Image(systemName: self.isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.textTertiary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(self.isExpanded ? "Collapse \(self.title)" : "Expand \(self.title)")
        .accessibilityLabel(self.isExpanded ? "Collapse \(self.title)" : "Expand \(self.title)")
        .accessibilityValue(self.isExpanded ? "Expanded" : "Collapsed")
    }
}
