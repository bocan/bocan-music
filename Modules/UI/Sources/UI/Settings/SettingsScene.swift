import SwiftUI

// MARK: - SettingsScene

/// Top-level `Settings` scene content.
///
/// Sidebar-style navigation (à la macOS System Settings), grouped into sections
/// so related panes — notably the audio panes (Equaliser / Effects / ReplayGain)
/// under "Playback" — read as a set rather than 14 flat tabs (#305). About is
/// intentionally absent — it is reached via the standard "Bòcan → About" menu.
///
/// Deep-links from elsewhere (sidebar buttons, menu items) navigate via the
/// injected ``SettingsRouter``, whose pending request survives until this scene
/// appears — so opening Settings directly to a page is reliable on first open.
public struct SettingsScene: View {
    @State private var selection: SettingsPage = .general
    private let router: SettingsRouter
    private let scrobbleViewModel: ScrobbleSettingsViewModel?
    private let backupViewModel: BackupSettingsViewModel
    private let subsonicViewModel: SubsonicSettingsViewModel?

    public init(
        router: SettingsRouter,
        backupViewModel: BackupSettingsViewModel,
        scrobbleViewModel: ScrobbleSettingsViewModel? = nil,
        subsonicViewModel: SubsonicSettingsViewModel? = nil
    ) {
        self.router = router
        self.scrobbleViewModel = scrobbleViewModel
        self.backupViewModel = backupViewModel
        self.subsonicViewModel = subsonicViewModel
    }

    private var sections: [SettingsSection] {
        SettingsSection.sidebar(includeScrobble: self.scrobbleViewModel != nil)
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: self.$selection) {
                ForEach(self.sections) { section in
                    Section {
                        ForEach(section.pages, id: \.self) { page in
                            Label(page.title, systemImage: page.systemImage)
                                .tag(page)
                        }
                    } header: {
                        if let title = section.title { Text(title) }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 215, max: 260)
        } detail: {
            self.detail(for: self.selection)
                .navigationTitle(self.selection.title)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, minHeight: 460)
        .onAppear { self.consumePendingNavigation() }
        .onChange(of: self.router.pendingPage) { _, _ in self.consumePendingNavigation() }
    }

    /// Navigate to any page the router has queued, then clear the request so it
    /// doesn't re-fire. Runs on appear (first open) and on change (already open).
    private func consumePendingNavigation() {
        guard let page = self.router.pendingPage else { return }
        self.selection = page
        if page == .sources, let id = self.router.pendingServerID, let vm = self.subsonicViewModel {
            Task { await vm.selectServer(id) }
        }
        self.router.pendingPage = nil
        self.router.pendingServerID = nil
    }

    @ViewBuilder
    private func detail(for tab: SettingsPage) -> some View {
        switch tab {
        case .general:
            GeneralSettingsView()

        case .library:
            LibrarySettingsView()

        case .sources:
            if let subsonicViewModel = self.subsonicViewModel {
                SubsonicSettingsView(viewModel: subsonicViewModel)
            } else {
                ContentUnavailableView(
                    "Sources Unavailable",
                    systemImage: "server.rack",
                    description: Text("Music server sources can't be configured right now.")
                )
            }

        case .playback:
            PlaybackSettingsView()

        case .equaliser:
            EQSettingsView()

        case .effects:
            EffectsSettingsView()

        case .replayGain:
            ReplayGainSettingsTabView()

        case .appearance:
            AppearanceSettingsView()

        case .advanced:
            AdvancedSettingsView(backupVM: self.backupViewModel)

        case .lyrics:
            LyricsSettingsView()

        case .visualizer:
            VisualizerSettingsView()

        case .smartPlaylists:
            SmartPlaylistsSettingsView()

        case .scrobble:
            if let scrobbleViewModel = self.scrobbleViewModel {
                ScrobbleSettingsView(viewModel: scrobbleViewModel)
            }

        case .diagnostics:
            DiagnosticsSettingsView()
        }
    }
}

// MARK: - SettingsSection

/// A labelled group of pages in the Settings sidebar. A `nil` title renders an
/// unlabelled top section (matching macOS System Settings).
struct SettingsSection: Identifiable {
    let title: String?
    let pages: [SettingsPage]
    var id: String {
        self.title ?? "_top"
    }

    /// The ordered sidebar sections. Sources is always present so a first-timer
    /// can find server setup; Scrobbling appears only when its provider exists.
    /// The audio panes (Equaliser/Effects/ReplayGain) are grouped under Playback
    /// rather than left as loose top-level tabs (#305).
    static func sidebar(includeScrobble: Bool) -> [Self] {
        var advanced: [SettingsPage] = []
        if includeScrobble { advanced.append(.scrobble) }
        advanced.append(contentsOf: [.advanced, .diagnostics])
        return [
            Self(title: nil, pages: [.general, .appearance]),
            Self(title: "Library", pages: [.library, .sources, .smartPlaylists]),
            Self(title: "Playback", pages: [.playback, .equaliser, .effects, .replayGain]),
            Self(title: "Now Playing", pages: [.lyrics, .visualizer]),
            Self(title: "Advanced", pages: advanced),
        ]
    }
}

// MARK: - SettingsPage presentation

extension SettingsPage {
    var title: String {
        switch self {
        case .general:
            "General"

        case .library:
            "Library"

        case .sources:
            "Sources"

        case .playback:
            "Playback"

        case .equaliser:
            "Equaliser"

        case .effects:
            "Effects"

        case .replayGain:
            "ReplayGain"

        case .appearance:
            "Appearance"

        case .advanced:
            "Advanced"

        case .lyrics:
            "Lyrics"

        case .visualizer:
            "Visualizer"

        case .smartPlaylists:
            "Smart Playlists"

        case .scrobble:
            "Scrobbling"

        case .diagnostics:
            "Diagnostics"
        }
    }

    var systemImage: String {
        switch self {
        case .general:
            "gear"

        case .library:
            "music.note.list"

        case .sources:
            "server.rack"

        case .playback:
            "play.circle"

        case .equaliser:
            "slider.vertical.3"

        case .effects:
            "waveform.badge.magnifyingglass"

        case .replayGain:
            "chart.bar.fill"

        case .appearance:
            "paintpalette"

        case .advanced:
            "wrench.and.screwdriver"

        case .lyrics:
            "text.quote"

        case .visualizer:
            "waveform"

        case .smartPlaylists:
            "sparkles"

        case .scrobble:
            "dot.radiowaves.left.and.right"

        case .diagnostics:
            "stethoscope"
        }
    }
}
