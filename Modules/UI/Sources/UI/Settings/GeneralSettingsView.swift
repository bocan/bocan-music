import SwiftUI
import UserNotifications

// MARK: - GeneralSettingsView

public struct GeneralSettingsView: View {
    @AppStorage("general.launchAtLogin") private var launchAtLogin = false
    @AppStorage("general.showNotifications") private var showNotifications = false
    @AppStorage("ui.windowMode.restoresLastMode") private var restoresLastMode = true
    @AppStorage("general.showAlbumArtInDock") private var showAlbumArtInDock = true
    @AppStorage("general.showPlaybackBadge") private var showPlaybackBadge = true
    @AppStorage("general.showDockProgress") private var showDockProgress = true
    @Environment(\.menuBarExtraEnabled) private var showMenuBarExtra

    public init() {}

    public var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch Bòcan at login", isOn: self.$launchAtLogin)
                    .help("Register Bòcan as a macOS login item.")
                Toggle("Restore last window mode on launch", isOn: self.$restoresLastMode)
            }

            Section("Menu Bar") {
                Toggle("Show Bòcan in menu bar", isOn: self.showMenuBarExtra)
            }

            Section("Dock") {
                Toggle("Show album art as Dock icon while playing", isOn: self.$showAlbumArtInDock)
                    .help("Replaces the Dock icon with the current track's cover art while something is playing.")
                Toggle("Show playback state badge on Dock icon", isOn: self.$showPlaybackBadge)
                    .help("Displays a small play ▶ or pause ‖ badge on the Dock icon so you can see playback state at a glance.")
                Toggle("Show progress bar on Dock icon", isOn: self.$showDockProgress)
                    .help("Shows a thin progress bar along the bottom of the Dock icon while a track is playing.")
            }

            Section("Notifications") {
                Toggle("Show track-change notifications", isOn: self.$showNotifications)
                    .onChange(of: self.showNotifications) { _, enabled in
                        if enabled { self.requestNotificationAuth() }
                    }
                Text("Notifications only appear when Bòcan is not in the foreground.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }

    private func requestNotificationAuth() {
        Task {
            _ = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        }
    }
}
