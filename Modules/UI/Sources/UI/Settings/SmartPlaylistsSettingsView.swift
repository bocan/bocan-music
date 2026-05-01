import Library
import SwiftUI

// MARK: - SmartPlaylistsSettingsView

/// Settings tab for smart-playlist behavior defaults.
public struct SmartPlaylistsSettingsView: View {
    @AppStorage(SmartPlaylistPreferences.defaultLiveUpdateKey)
    private var defaultLiveUpdate = true

    @AppStorage(SmartPlaylistPreferences.observeDebounceMillisecondsKey)
    private var observeDebounceMilliseconds = SmartPlaylistPreferences.defaultObserveDebounceMilliseconds

    @AppStorage(SmartPlaylistPreferences.randomRerollOnLaunchKey)
    private var randomRerollOnLaunch = false

    public init() {}

    public var body: some View {
        Form {
            Section("Defaults") {
                Toggle("New smart playlists use live update", isOn: self.$defaultLiveUpdate)
                    .help("If off, new smart playlists start in snapshot mode and only change on Refresh now")
            }

            Section("Live Observation") {
                Stepper(value: self.$observeDebounceMilliseconds, in: 0 ... 5000, step: 25) {
                    Text("Debounce window: \(self.observeDebounceMilliseconds) ms")
                }
                .help("Minimum delay before publishing live smart-playlist updates")
            }

            Section("Random Sort") {
                Toggle("Re-roll random order on app launch", isOn: self.$randomRerollOnLaunch)
                    .help("When enabled, smart playlists sorted by Random use a per-launch seed")
            }

            Section("Not Exposed Yet") {
                Text(
                    "Mass auto-refresh interval for snapshot playlists is intentionally " +
                        "not user-configurable yet. Snapshot mode remains on-demand " +
                        "(Refresh now) until a dedicated scheduler design lands."
                )
                .font(Typography.caption)
                .foregroundStyle(Color.textSecondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 440, minHeight: 320)
    }
}
