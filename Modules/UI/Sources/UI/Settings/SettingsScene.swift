import SwiftUI

// MARK: - SettingsScene

/// Top-level `Settings` scene content.
///
/// Tabbed sidebar navigation (macOS 14+ preferred style).
/// Usage in `BocanApp`:
/// ```swift
/// Settings { SettingsScene() }
/// ```
public struct SettingsScene: View {
    @State private var selectedTab: SettingsTab = .general

    public init() {}

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

            AdvancedSettingsView()
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
                .tag(SettingsTab.advanced)

            LyricsSettingsView()
                .tabItem { Label("Lyrics", systemImage: "text.quote") }
                .tag(SettingsTab.lyrics)

            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        .frame(minWidth: 520, minHeight: 360)
    }
}

// MARK: - SettingsTab

private enum SettingsTab: String {
    case general, library, playback, dsp, appearance, advanced, lyrics, about
}
