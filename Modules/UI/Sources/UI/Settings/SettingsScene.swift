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

    public init(
        backupViewModel: BackupSettingsViewModel,
        scrobbleViewModel: ScrobbleSettingsViewModel? = nil
    ) {
        self.scrobbleViewModel = scrobbleViewModel
        self.backupViewModel = backupViewModel
    }

    public var body: some View {
        TabView(selection: self.$selectedTab) {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gear") }
                .tag(SettingsTab.general)

            LibrarySettingsView()
                .tabItem { Label("Library", systemImage: "music.note.list") }
                .tag(SettingsTab.library)

            PlaybackSettingsView()
                .tabItem { Label("Playback", systemImage: "play.circle") }
                .tag(SettingsTab.playback)

            DSPSettingsView()
                .tabItem { Label("DSP & EQ", systemImage: "slider.horizontal.3") }
                .tag(SettingsTab.dsp)

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
        .frame(minWidth: 520, minHeight: 360)
    }
}

// MARK: - SettingsTab

private enum SettingsTab: String {
    case general, library, playback, dsp, appearance, advanced, lyrics, visualizer, smartPlaylists, scrobble, diagnostics
}
