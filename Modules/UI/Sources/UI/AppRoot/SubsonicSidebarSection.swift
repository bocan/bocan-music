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
    public let connectionStates: [UUID: SubsonicSidebarConnectionState]
    public var onAddSource: (() -> Void)?

    public init(
        sectionExpanded: Binding<Bool>,
        expandedServers: Binding<Set<UUID>>,
        servers: [SubsonicSidebarServer],
        connectionStates: [UUID: SubsonicSidebarConnectionState] = [:],
        onAddSource: (() -> Void)? = nil
    ) {
        self._sectionExpanded = sectionExpanded
        self._expandedServers = expandedServers
        self.servers = servers
        self.connectionStates = connectionStates
        self.onAddSource = onAddSource
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
                    ForEach(Array(self.servers.enumerated()), id: \.element.id) { index, server in
                        self.serverRows(for: server, shortcutIndex: index)
                    }
                }
            }
        } header: {
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { self.sectionExpanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text("Sources")
                        Image(systemName: self.sectionExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.textTertiary)
                    }
                }
                .buttonStyle(.plain)
                .help(self.sectionExpanded ? "Collapse Sources" : "Expand Sources")
                .accessibilityLabel(self.sectionExpanded ? "Collapse Sources" : "Expand Sources")
                .accessibilityValue(self.sectionExpanded ? "Expanded" : "Collapsed")

                Spacer()

                if let onAddSource {
                    Button { onAddSource() } label: {
                        Image(systemName: "plus")
                            .font(Typography.footnote)
                    }
                    .buttonStyle(.borderless)
                    .fixedSize()
                    .help("Add a new source server")
                    .accessibilityLabel("Add Source")
                    .accessibilityIdentifier(A11y.SourcesSidebar.addButton)
                }
            }
        }
    }

    @ViewBuilder
    private func serverRows(for server: SubsonicSidebarServer, shortcutIndex: Int) -> some View {
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
        let state = self.connectionStates[server.id] ?? .unknown

        self.disclosureButton(for: server, binding: binding, state: state, shortcutIndex: shortcutIndex)

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

    private func disclosureButton(
        for server: SubsonicSidebarServer,
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
        .help("\(server.name) — \(state.displayLabel)")
        .accessibilityLabel(server.name)
        .accessibilityValue("\(state.displayLabel). \(binding.wrappedValue ? "Expanded" : "Collapsed")")
        .modifier(SourceServerShortcut(index: shortcutIndex))
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

// MARK: - SubsonicStatusDot

/// Compact connection-status indicator rendered next to each source-server
/// row in the sidebar. The dot itself is `accessibilityHidden(true)`; the
/// enclosing row carries the spoken label and value (Phase 19 step 17).
struct SubsonicStatusDot: View {
    let state: SubsonicSidebarConnectionState

    var body: some View {
        Group {
            if case .connecting = self.state {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.6)
                    .frame(width: 8, height: 8)
            } else {
                Circle()
                    .fill(self.color)
                    .frame(width: 8, height: 8)
            }
        }
        .accessibilityHidden(true)
    }

    private var color: Color {
        switch self.state {
        case .online:
            .green

        case .connecting:
            .yellow

        case .authFailed:
            .orange

        case .unreachable, .serverError:
            .red

        case .unknown:
            .secondary
        }
    }
}

// MARK: - SourceServerShortcut

/// Binds `\u{2318}\u{21E7}1`–`\u{2318}\u{21E7}9` to the first nine source-server
/// disclosure rows so keyboard users can jump straight to a server. Indices
/// beyond 8 are silently skipped (the spec only reserves nine slots).
private struct SourceServerShortcut: ViewModifier {
    let index: Int

    func body(content: Content) -> some View {
        if let key = Self.key(for: self.index) {
            content.keyboardShortcut(key, modifiers: [.command, .shift])
        } else {
            content
        }
    }

    private static func key(for index: Int) -> KeyEquivalent? {
        switch index {
        case 0:
            "1"

        case 1:
            "2"

        case 2:
            "3"

        case 3:
            "4"

        case 4:
            "5"

        case 5:
            "6"

        case 6:
            "7"

        case 7:
            "8"

        case 8:
            "9"

        default:
            nil
        }
    }
}
