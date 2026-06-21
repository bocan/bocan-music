import SwiftUI

// MARK: - PodcastSettingsView

/// Settings pane for podcast-specific preferences: refresh schedule,
/// playback skip intervals, default speed, and search storefront.
public struct PodcastSettingsView: View {
    @AppStorage("podcasts.refreshInterval") private var refreshIntervalMinutes = 30
    @AppStorage("podcasts.refreshOnLaunch") private var refreshOnLaunch = true
    @AppStorage("podcasts.autoDownloadCount") private var autoDownloadCount = 3
    @AppStorage("podcasts.skipBackInterval") private var skipBackInterval = 15.0
    @AppStorage("podcasts.skipForwardInterval") private var skipForwardInterval = 30.0
    @AppStorage("podcast.playback.rate") private var defaultSpeed = 1.0
    @AppStorage("podcasts.storefront") private var storefront = "us"
    @State private var podcastIndexConfigured = false

    public init() {}

    public var body: some View {
        Form {
            Section(L10n.string("Refresh")) {
                Picker(L10n.string("Refresh interval"), selection: self.$refreshIntervalMinutes) {
                    Text(localized: "15 minutes").tag(15)
                    Text(localized: "30 minutes").tag(30)
                    Text(localized: "60 minutes").tag(60)
                    Text(localized: "Manual only").tag(0)
                }
                Toggle(L10n.string("Refresh on launch"), isOn: self.$refreshOnLaunch)
            }
            Section {
                Picker(L10n.string("Auto-download"), selection: self.$autoDownloadCount) {
                    Text(localized: "1 newest episode").tag(1)
                    Text(localized: "3 newest episodes").tag(3)
                    Text(localized: "5 newest episodes").tag(5)
                    Text(localized: "10 newest episodes").tag(10)
                }
            } footer: {
                Text(localized: "How many new episodes to download for shows with auto-download enabled.")
            }
            Section(L10n.string("Playback")) {
                Picker(L10n.string("Skip back"), selection: self.$skipBackInterval) {
                    Text(localized: "10 seconds").tag(10.0)
                    Text(localized: "15 seconds").tag(15.0)
                    Text(localized: "30 seconds").tag(30.0)
                }
                Picker(L10n.string("Skip forward"), selection: self.$skipForwardInterval) {
                    Text(localized: "15 seconds").tag(15.0)
                    Text(localized: "30 seconds").tag(30.0)
                    Text(localized: "45 seconds").tag(45.0)
                }
                HStack {
                    Text(localized: "Default speed")
                    Spacer()
                    Picker("", selection: self.$defaultSpeed) {
                        ForEach([0.8, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { speed in
                            Text(String(format: "%.2g\u{00D7}", speed)).tag(speed)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 80)
                }
            }
            Section(L10n.string("Search")) {
                Picker(L10n.string("Storefront country"), selection: self.$storefront) {
                    Text(localized: "United States").tag("us")
                    Text(localized: "United Kingdom").tag("gb")
                    Text(localized: "Canada").tag("ca")
                    Text(localized: "Australia").tag("au")
                    Text(localized: "Germany").tag("de")
                    Text(localized: "France").tag("fr")
                    Text(localized: "Japan").tag("jp")
                }
                HStack {
                    Text(localized: "Podcast Index API")
                    Spacer()
                    Text(self.podcastIndexConfigured
                        ? L10n.string("Configured")
                        : L10n.string("Not configured"))
                        .foregroundStyle(self.podcastIndexConfigured ? Color.accentColor : Color.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L10n.string("Podcasts"))
        .onAppear {
            self.podcastIndexConfigured =
                !(Bundle.main.infoDictionary?["PODCAST_INDEX_API_KEY"] as? String ?? "").isEmpty
        }
    }
}
