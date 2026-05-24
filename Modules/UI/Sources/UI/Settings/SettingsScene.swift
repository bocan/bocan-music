import SwiftUI

// MARK: - SettingsScene

/// Top-level `Settings` scene content.
///
/// Tabbed toolbar navigation. About is intentionally absent — it is accessible
/// via the standard macOS "Bòcan → About Bòcan" app menu item, and including it
/// in the tab bar caused overflow + broken tab behaviour on macOS 26.
/// Usage in `BocanApp`:
/// ```swift
/// Settings { SettingsScene() }
/// ```
public struct SettingsScene: View {
    @State private var selectedTab: SettingsTab = .general
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

    /// Ordered list of tabs that are actually visible (scrobble tab is conditional).
    private var visibleTabs: [SettingsTab] {
        var tabs: [SettingsTab] = [
            .general, .library,
        ]
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
        TabView(selection: self.$selectedTab) {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gear") }
                .tag(SettingsTab.general)

            LibrarySettingsView()
                .tabItem { Label("Library", systemImage: "music.note.list") }
                .tag(SettingsTab.library)

            if let subsonicViewModel = self.subsonicViewModel {
                SubsonicSettingsView(viewModel: subsonicViewModel)
                    .tabItem { Label("Sources", systemImage: "server.rack") }
                    .tag(SettingsTab.sources)
            }

            PlaybackSettingsView()
                .tabItem { Label("Playback", systemImage: "play.circle") }
                .tag(SettingsTab.playback)

            EQSettingsView()
                .tabItem { Label("Equaliser", systemImage: "slider.vertical.3") }
                .tag(SettingsTab.equaliser)

            EffectsSettingsView()
                .tabItem { Label("Effects", systemImage: "waveform.badge.magnifyingglass") }
                .tag(SettingsTab.effects)

            ReplayGainSettingsTabView()
                .tabItem { Label("ReplayGain", systemImage: "chart.bar.fill") }
                .tag(SettingsTab.replayGain)

            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
                .tag(SettingsTab.appearance)

            AdvancedSettingsView(backupVM: self.backupViewModel)
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
                .tag(SettingsTab.advanced)

            LyricsSettingsView()
                .tabItem { Label("Lyrics", systemImage: "text.quote") }
                .tag(SettingsTab.lyrics)

            VisualizerSettingsView()
                .tabItem { Label("Visualizer", systemImage: "waveform") }
                .tag(SettingsTab.visualizer)

            SmartPlaylistsSettingsView()
                .tabItem { Label("Smart Playlists", systemImage: "sparkles") }
                .tag(SettingsTab.smartPlaylists)

            if let scrobbleViewModel = self.scrobbleViewModel {
                ScrobbleSettingsView(viewModel: scrobbleViewModel)
                    .tabItem { Label("Scrobbling", systemImage: "dot.radiowaves.left.and.right") }
                    .tag(SettingsTab.scrobble)
            }

            DiagnosticsSettingsView()
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
                .tag(SettingsTab.diagnostics)
        }
        .frame(minWidth: 520, minHeight: 415)
    }
}

// MARK: - SettingsTab

private enum SettingsTab: String, CaseIterable {
    case general, library, sources, playback, equaliser, effects, replayGain
    case appearance, advanced, lyrics, visualizer, smartPlaylists, scrobble, diagnostics
}
