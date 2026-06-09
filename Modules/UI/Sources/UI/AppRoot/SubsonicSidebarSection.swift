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
    public let hiddenServers: [SubsonicSidebarServer]
    public let connectionStates: [UUID: SubsonicSidebarConnectionState]
    public var onAddSource: (() -> Void)?
    public var onManageSources: (() -> Void)?
    public var onRefreshServer: ((UUID) -> Void)?
    public var onTestServerConnection: ((UUID) -> Void)?
    public var onEditServer: ((UUID) -> Void)?
    public var onDisableServerInSidebar: ((UUID) -> Void)?
    public var onEnableServerInSidebar: ((UUID) -> Void)?
    public var onRemoveServer: ((SubsonicSidebarServer) -> Void)?

    public init(
        sectionExpanded: Binding<Bool>,
        expandedServers: Binding<Set<UUID>>,
        servers: [SubsonicSidebarServer],
        hiddenServers: [SubsonicSidebarServer] = [],
        connectionStates: [UUID: SubsonicSidebarConnectionState] = [:],
        onAddSource: (() -> Void)? = nil,
        onManageSources: (() -> Void)? = nil,
        onRefreshServer: ((UUID) -> Void)? = nil,
        onTestServerConnection: ((UUID) -> Void)? = nil,
        onEditServer: ((UUID) -> Void)? = nil,
        onDisableServerInSidebar: ((UUID) -> Void)? = nil,
        onEnableServerInSidebar: ((UUID) -> Void)? = nil,
        onRemoveServer: ((SubsonicSidebarServer) -> Void)? = nil
    ) {
        self._sectionExpanded = sectionExpanded
        self._expandedServers = expandedServers
        self.servers = servers
        self.hiddenServers = hiddenServers
        self.connectionStates = connectionStates
        self.onAddSource = onAddSource
        self.onManageSources = onManageSources
        self.onRefreshServer = onRefreshServer
        self.onTestServerConnection = onTestServerConnection
        self.onEditServer = onEditServer
        self.onDisableServerInSidebar = onDisableServerInSidebar
        self.onEnableServerInSidebar = onEnableServerInSidebar
        self.onRemoveServer = onRemoveServer
    }

    public var body: some View {
        Section {
            if self.sectionExpanded {
                if self.servers.isEmpty {
                    // Tappable empty-state CTA so a first-time user can find server
                    // setup without discovering the header "+" (#309). Falls back to
                    // a plain label only if no add handler was injected.
                    if let onAddSource {
                        Button { onAddSource() } label: {
                            Label(L10n.string("Add a Server\u{2026}"), systemImage: "plus.circle")
                                .font(Typography.body)
                        }
                        .buttonStyle(.plain)
                        .help(L10n.string("Connect a Subsonic-compatible music server"))
                        .accessibilityIdentifier(A11y.SourcesSidebar.emptyStateAddButton)
                    } else {
                        Text(localized: "No sources yet")
                            .font(Typography.footnote)
                            .foregroundStyle(Color.textTertiary)
                            .padding(.vertical, 2)
                            .accessibilityLabel(L10n.string("No Subsonic sources configured"))
                    }
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
                        Text(localized: "Sources")
                        Image(systemName: self.sectionExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.textTertiary)
                    }
                }
                .buttonStyle(.plain)
                .help(self.sectionExpanded ? L10n.string("Collapse Sources") : L10n.string("Expand Sources"))
                .accessibilityLabel(self.sectionExpanded ? L10n.string("Collapse Sources") : L10n.string("Expand Sources"))
                .accessibilityValue(self.sectionExpanded ? L10n.string("Expanded") : L10n.string("Collapsed"))

                Spacer()

                if let onAddSource {
                    Button { onAddSource() } label: {
                        Image(systemName: "plus")
                            .font(Typography.footnote)
                    }
                    .buttonStyle(.borderless)
                    .fixedSize()
                    .help(L10n.string("Add a new source server"))
                    .accessibilityLabel(L10n.string("Add Source"))
                    .accessibilityIdentifier(A11y.SourcesSidebar.addButton)
                }
            }
            .contentShape(Rectangle())
            .contextMenu {
                if let onAddSource {
                    Button(L10n.string("Add Server")) { onAddSource() }
                }
                if let onManageSources {
                    Button(L10n.string("Manage Sources")) { onManageSources() }
                }
                if !self.hiddenServers.isEmpty, let onEnableServerInSidebar {
                    Divider()
                    Menu(L10n.string("Hidden Sources")) {
                        ForEach(self.hiddenServers, id: \.id) { server in
                            Button(L10n.string("Show \"\(server.name)\"")) {
                                onEnableServerInSidebar(server.id)
                            }
                        }
                    }
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
            self.row(.subsonicSongs(server.id), symbol: "music.note", label: L10n.string("Songs"))
            self.row(.subsonicAlbums(server.id), symbol: "square.grid.2x2", label: L10n.string("Albums"))
            self.row(.subsonicArtists(server.id), symbol: "music.mic", label: L10n.string("Artists"))
            self.row(.subsonicGenres(server.id), symbol: "tag", label: L10n.string("Genres"))
            self.row(.subsonicPlaylists(server.id), symbol: "music.note.list", label: L10n.string("Playlists"))
            self.row(.subsonicStarred(server.id), symbol: "star", label: L10n.string("Starred"))
            self.row(.subsonicRandom(server.id), symbol: "shuffle", label: L10n.string("Random"))
            self.row(.subsonicRecentlyAdded(server.id), symbol: "clock.badge.checkmark", label: L10n.string("Recently Added"))
            self.row(.subsonicMostPlayed(server.id), symbol: "chart.line.uptrend.xyaxis", label: L10n.string("Most Played"))
            if server.supportsInternetRadio {
                self.row(.subsonicInternetRadio(server.id), symbol: "dot.radiowaves.left.and.right", label: L10n.string("Internet Radio"))
            }
            if server.supportsPodcasts {
                self.row(.subsonicPodcasts(server.id), symbol: "antenna.radiowaves.left.and.right", label: L10n.string("Podcasts"))
            }
            if server.supportsBookmarks {
                self.row(.subsonicBookmarks(server.id), symbol: "bookmark", label: L10n.string("Bookmarks"))
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
        .help(L10n.string("\(server.name) — \(state.displayLabel)"))
        .accessibilityLabel(server.name)
        .accessibilityValue(L10n.string(
            "\(state.displayLabel). \(binding.wrappedValue ? L10n.string("Expanded") : L10n.string("Collapsed"))"
        ))
        .modifier(SourceServerShortcut(index: shortcutIndex))
        .contextMenu { self.serverContextMenu(for: server) }
    }

    @ViewBuilder
    private func serverContextMenu(for server: SubsonicSidebarServer) -> some View {
        if let onRefreshServer {
            Button(L10n.string("Refresh")) { onRefreshServer(server.id) }
        }
        if let onTestServerConnection {
            Button(L10n.string("Test Connection")) { onTestServerConnection(server.id) }
        }
        if let onEditServer {
            Button(L10n.string("Edit…")) { onEditServer(server.id) }
        }
        if let onDisableServerInSidebar {
            Divider()
            Button(L10n.string("Disable in Sidebar")) { onDisableServerInSidebar(server.id) }
        }
        if let onRemoveServer {
            Divider()
            // Opens a confirm-delete dialog (the "…" + destructive role are now
            // honest: this really removes the server, not just navigates) (#306).
            Button(L10n.string("Remove…"), role: .destructive) { onRemoveServer(server) }
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
/// the existing Playlists header (chevron + label).
///
/// Pass an `action` to surface a trailing "+" affordance and a matching
/// context-menu item (e.g. the Local Library header's persistent "Add Folder",
/// mirroring the Sources header's "Add Source") (#308).
struct SidebarSectionHeader: View {
    let title: String
    @Binding var isExpanded: Bool
    /// Optional trailing-action affordance.
    var action: Action?

    /// A trailing "+" button plus its labels, shown when supplied.
    struct Action {
        let title: String
        let identifier: String?
        let perform: () -> Void
    }

    init(title: String, isExpanded: Binding<Bool>, action: Action? = nil) {
        self.title = title
        self._isExpanded = isExpanded
        self.action = action
    }

    var body: some View {
        let header = HStack {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { self.isExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text(self.title)
                    Image(systemName: self.isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.textTertiary)
                }
            }
            .buttonStyle(.plain)
            .help(self.isExpanded ? L10n.string("Collapse \(self.title)") : L10n.string("Expand \(self.title)"))
            .accessibilityLabel(self.isExpanded ? L10n.string("Collapse \(self.title)") : L10n.string("Expand \(self.title)"))
            .accessibilityValue(self.isExpanded ? L10n.string("Expanded") : L10n.string("Collapsed"))

            Spacer()

            if let action {
                Button { action.perform() } label: {
                    Image(systemName: "plus")
                        .font(Typography.footnote)
                }
                .buttonStyle(.borderless)
                .fixedSize()
                .help(action.title)
                .accessibilityLabel(action.title)
                .accessibilityIdentifier(action.identifier ?? "")
            }
        }
        .contentShape(Rectangle())

        // Only attach the context menu when there's an action, so the
        // action-less headers (Recents, Queue) don't get an empty right-click menu.
        if let action {
            header.contextMenu {
                Button(L10n.string("\(action.title)\u{2026}")) { action.perform() }
            }
        } else {
            header
        }
    }
}

// MARK: - SubsonicStatusDot

/// Compact connection-status indicator rendered next to each source-server
/// row in the sidebar. The dot itself is `accessibilityHidden(true)`; the
/// enclosing row carries the spoken label and value (Phase 19 step 17).
struct SubsonicStatusDot: View {
    let state: SubsonicSidebarConnectionState
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    var body: some View {
        Group {
            if case .connecting = self.state {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.6)
                    .frame(width: 8, height: 8)
            } else if self.differentiateWithoutColor {
                // Per-status glyph so colourblind users can tell states apart by
                // shape rather than the green/orange/red hue alone (WCAG 1.4.1).
                Image(systemName: Self.glyph(for: self.state))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(self.color)
                    .frame(width: 10, height: 10)
            } else {
                Circle()
                    .fill(self.color)
                    .frame(width: 8, height: 8)
            }
        }
        .accessibilityHidden(true)
    }

    /// SF Symbol shown in place of the plain dot when "Differentiate Without
    /// Color" is enabled. `.connecting` is handled separately by the spinner.
    /// Each state maps to a distinct shape so the status is conveyed without
    /// relying on hue.
    static func glyph(for state: SubsonicSidebarConnectionState) -> String {
        switch state {
        case .online:
            "checkmark.circle.fill"

        case .connecting:
            "circle.dotted"

        case .authFailed:
            "lock.fill"

        case .unreachable, .serverError:
            "exclamationmark.triangle.fill"

        case .unknown:
            "questionmark"
        }
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
