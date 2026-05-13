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
    /// Sentinel that gives the settings window initial keyboard focus on first appear.
    /// Without this, the window opens but no control has focus and Tab does nothing.
    @FocusState private var tabViewFocused: Bool
    private let scrobbleViewModel: ScrobbleSettingsViewModel?
    private let backupViewModel: BackupSettingsViewModel

    public init(
        backupViewModel: BackupSettingsViewModel,
        scrobbleViewModel: ScrobbleSettingsViewModel? = nil
    ) {
        self.scrobbleViewModel = scrobbleViewModel
        self.backupViewModel = backupViewModel
    }

    /// Ordered list of tabs that are actually visible (scrobble tab is conditional).
    private var visibleTabs: [SettingsTab] {
        var tabs: [SettingsTab] = [
            .general, .library, .playback, .equaliser, .effects, .replayGain,
            .appearance, .advanced, .lyrics, .visualizer, .smartPlaylists,
        ]
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
        // Make the tab view itself focusable so it enters the keyboard focus chain.
        // defaultFocus establishes initial first-responder when the window opens.
        .focusable()
        .focused(self.$tabViewFocused)
        .defaultFocus(self.$tabViewFocused, true)
        // Left / right arrows switch between tabs when the tab view has focus.
        // When a control inside a tab (e.g. Slider) has focus it handles its own
        // arrow keys first and the event never reaches this handler.
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            self.shiftTab(by: press.key == .leftArrow ? -1 : 1)
            return .handled
        }
        .frame(minWidth: 520, minHeight: 360)
    }

    private func shiftTab(by delta: Int) {
        let tabs = self.visibleTabs
        guard let idx = tabs.firstIndex(of: self.selectedTab) else { return }
        let newIdx = (idx + delta + tabs.count) % tabs.count
        self.selectedTab = tabs[newIdx]
    }
}

// MARK: - SettingsTab

private enum SettingsTab: String, CaseIterable {
    case general, library, playback, equaliser, effects, replayGain
    case appearance, advanced, lyrics, visualizer, smartPlaylists, scrobble, diagnostics
}
