import SwiftUI

// MARK: - SettingsScene

/// Top-level `Settings` scene content.
///
/// Sidebar-style navigation (à la macOS System Settings). About is intentionally
/// absent — it is accessible via the standard macOS "Bòcan → About Bòcan" app menu
/// item.
///
/// Usage in `BocanApp`:
/// ```swift
/// Settings { SettingsScene() }
/// ```
public struct SettingsScene: View {
    @State private var selection: SettingsTab = .general
    private let scrobbleViewModel: ScrobbleSettingsViewModel?
    private let backupViewModel: BackupSettingsViewModel
    private let subsonicViewModel: SubsonicSettingsViewModel?

    public init(
        backupViewModel: BackupSettingsViewModel,
        scrobbleViewModel: ScrobbleSettingsViewModel? = nil,
        subsonicViewModel: SubsonicSettingsViewModel? = nil
    ) {
        self.scrobbleViewModel = scrobbleViewModel
        self.backupViewModel = backupViewModel
        self.subsonicViewModel = subsonicViewModel
    }

    /// Ordered list of sections that are actually visible (scrobble + sources are conditional).
    private var visibleTabs: [SettingsTab] {
        var tabs: [SettingsTab] = [.general, .library]
        if self.subsonicViewModel != nil { tabs.append(.sources) }
        tabs.append(contentsOf: [
            .playback, .equaliser, .effects, .replayGain,
            .appearance, .advanced, .lyrics, .visualizer, .smartPlaylists,
        ])
        if self.scrobbleViewModel != nil { tabs.append(.scrobble) }
        tabs.append(.diagnostics)
        return tabs
    }

    public var body: some View {
        NavigationSplitView {
            List(self.visibleTabs, id: \.self, selection: self.$selection) { tab in
                Label(tab.title, systemImage: tab.systemImage)
                    .tag(tab)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            self.detail(for: self.selection)
                .navigationTitle(self.selection.title)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, minHeight: 460)
        .onReceive(NotificationCenter.default.publisher(for: .openSourcesSettingsTab)) { _ in
            self.selection = .sources
        }
    }

    @ViewBuilder
    private func detail(for tab: SettingsTab) -> some View {
        switch tab {
        case .general:
            GeneralSettingsView()

        case .library:
            LibrarySettingsView()

        case .sources:
            if let subsonicViewModel = self.subsonicViewModel {
                SubsonicSettingsView(viewModel: subsonicViewModel)
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

// MARK: - Notification

/// Bòcan-specific `Notification.Name` constants.
public extension Notification.Name {
    /// Post this notification (followed by `openSettings()`) to open
    /// Settings and navigate directly to the Sources tab.
    static let openSourcesSettingsTab = Notification.Name("bocan.settings.openSourcesTab")
}

// MARK: - SettingsTab

private enum SettingsTab: String, CaseIterable, Hashable {
    case general, library, sources, playback, equaliser, effects, replayGain
    case appearance, advanced, lyrics, visualizer, smartPlaylists, scrobble, diagnostics

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
