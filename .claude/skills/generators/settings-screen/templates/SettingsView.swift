import SwiftUI

/// Main settings view container.
///
/// Usage:
/// ```swift
/// // iOS - NavigationLink
/// NavigationLink("Settings") {
///     SettingsView()
/// }
///
/// // iOS - Sheet
/// .sheet(isPresented: $showSettings) {
///     NavigationStack {
///         SettingsView()
///     }
/// }
///
/// // macOS - Settings scene
/// Settings {
///     SettingsView()
/// }
/// ```
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings = AppSettings.shared

    // MARK: - Alert State

    @State private var showResetConfirmation = false

    var body: some View {
        #if os(iOS)
            self.iOSSettings
        #else
            self.macOSSettings
        #endif
    }

    // MARK: - iOS Layout

    #if os(iOS)
        private var iOSSettings: some View {
            Form {
                self.appearanceSection
                self.notificationsSection
                self.privacySection
                self.aboutSection
                self.legalSection

                #if DEBUG
                    self.debugSection
                #endif
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
        }
    #endif

    // MARK: - macOS Layout

    #if os(macOS)
        private var macOSSettings: some View {
            TabView {
                Form {
                    self.appearanceSection
                    self.notificationsSection
                }
                .formStyle(.grouped)
                .tabItem {
                    Label("General", systemImage: "gear")
                }

                Form {
                    self.privacySection
                }
                .formStyle(.grouped)
                .tabItem {
                    Label("Privacy", systemImage: "hand.raised.fill")
                }

                Form {
                    self.aboutSection
                    self.legalSection
                }
                .formStyle(.grouped)
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }

                #if DEBUG
                    Form {
                        self.debugSection
                    }
                    .formStyle(.grouped)
                    .tabItem {
                        Label("Debug", systemImage: "ant.fill")
                    }
                #endif
            }
            .frame(width: 450, height: 300)
        }
    #endif

    // MARK: - Sections

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Theme", selection: self.$settings.appearance) {
                ForEach(AppSettings.Appearance.allCases) { appearance in
                    Text(appearance.displayName).tag(appearance)
                }
            }

            SettingsToggleRow(
                icon: "figure.walk",
                iconColor: .blue,
                title: "Reduce Motion",
                isOn: self.$settings.reduceMotion
            )

            SettingsToggleRow(
                icon: "hand.tap.fill",
                iconColor: .orange,
                title: "Haptic Feedback",
                isOn: self.$settings.hapticFeedback
            )

            SettingsToggleRow(
                icon: "speaker.wave.2.fill",
                iconColor: .pink,
                title: "Sound Effects",
                isOn: self.$settings.soundEffects
            )
        }
    }

    private var notificationsSection: some View {
        Section("Notifications") {
            SettingsToggleRow(
                icon: "bell.fill",
                iconColor: .red,
                title: "Notifications",
                isOn: self.$settings.notificationsEnabled
            )

            if self.settings.notificationsEnabled {
                SettingsToggleRow(
                    icon: "calendar",
                    iconColor: .green,
                    title: "Daily Reminders",
                    isOn: self.$settings.dailyReminders
                )
            }

            #if os(iOS)
                Button {
                    self.openNotificationSettings()
                } label: {
                    SettingsRow(
                        icon: "gear",
                        iconColor: .gray,
                        title: "Notification Settings"
                    ) {
                        Image(systemName: "arrow.up.forward")
                            .font(.caption)
                    }
                }
                .buttonStyle(.plain)
            #endif
        }
    }

    private var privacySection: some View {
        Section("Privacy") {
            SettingsToggleRow(
                icon: "chart.bar.fill",
                iconColor: .purple,
                title: "Analytics",
                isOn: self.$settings.analyticsEnabled
            )
        }
    }

    private var aboutSection: some View {
        Section("About") {
            SettingsRow(
                icon: "info.circle.fill",
                iconColor: .blue,
                title: "Version",
                value: self.settings.fullVersionString
            )

            Link(destination: self.appStoreURL) {
                SettingsRow(
                    icon: "star.fill",
                    iconColor: .yellow,
                    title: "Rate on App Store"
                ) {
                    Image(systemName: "arrow.up.forward")
                        .font(.caption)
                }
            }
            .buttonStyle(.plain)

            Link(destination: self.supportURL) {
                SettingsRow(
                    icon: "envelope.fill",
                    iconColor: .green,
                    title: "Contact Support"
                ) {
                    Image(systemName: "arrow.up.forward")
                        .font(.caption)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var legalSection: some View {
        Section("Legal") {
            Link(destination: self.privacyURL) {
                SettingsRow(
                    icon: "hand.raised.fill",
                    iconColor: .blue,
                    title: "Privacy Policy"
                ) {
                    Image(systemName: "arrow.up.forward")
                        .font(.caption)
                }
            }
            .buttonStyle(.plain)

            Link(destination: self.termsURL) {
                SettingsRow(
                    icon: "doc.text.fill",
                    iconColor: .gray,
                    title: "Terms of Service"
                ) {
                    Image(systemName: "arrow.up.forward")
                        .font(.caption)
                }
            }
            .buttonStyle(.plain)
        }
    }

    #if DEBUG
        private var debugSection: some View {
            Section("Debug") {
                Button("Reset All Settings") {
                    self.showResetConfirmation = true
                }
                .foregroundStyle(.red)

                Button("Reset Onboarding") {
                    UserDefaults.standard.removeObject(forKey: "hasCompletedOnboarding")
                }
            }
            .confirmationDialog("Reset Settings", isPresented: self.$showResetConfirmation) {
                Button("Reset All Settings", role: .destructive) {
                    self.settings.resetToDefaults()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will reset all settings to their default values.")
            }
        }
    #endif

    // MARK: - Actions

    #if os(iOS)
        private func openNotificationSettings() {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        }
    #endif

    // MARK: - URLs

    // TODO: Update these URLs for your app
    private var appStoreURL: URL {
        URL(string: "https://apps.apple.com/app/idYOUR_APP_ID")!
    }

    private var supportURL: URL {
        URL(string: "mailto:support@yourapp.com")!
    }

    private var privacyURL: URL {
        URL(string: "https://yourapp.com/privacy")!
    }

    private var termsURL: URL {
        URL(string: "https://yourapp.com/terms")!
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        SettingsView()
    }
}
