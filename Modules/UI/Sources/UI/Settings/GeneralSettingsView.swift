import SwiftUI
import UserNotifications

// MARK: - GeneralSettingsView

public struct GeneralSettingsView: View {
    @AppStorage("general.launchAtLogin") private var launchAtLogin = false
    @AppStorage("general.showNotifications") private var showNotifications = false
    @AppStorage("ui.windowMode.restoresLastMode") private var restoresLastMode = true
    @Environment(\.menuBarExtraEnabled) private var showMenuBarExtra

    public init() {}

    public var body: some View {
        Form {
            Section("Startup") {
                Toggle("Restore last window mode on launch", isOn: self.$restoresLastMode)
            }

            Section("Menu Bar") {
                Toggle("Show Bòcan in menu bar", isOn: self.showMenuBarExtra)
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
