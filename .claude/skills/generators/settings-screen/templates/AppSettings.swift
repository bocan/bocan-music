import Foundation
import SwiftUI

/// Centralized app settings using @AppStorage.
///
/// Usage:
/// ```swift
/// // Access settings
/// let settings = AppSettings.shared
/// settings.appearance = .dark
///
/// // In SwiftUI views
/// @Environment(AppSettings.self) var settings
/// ```
@Observable
final class AppSettings {
    // MARK: - Singleton

    static let shared = AppSettings()

    // MARK: - Appearance

    /// App color scheme preference.
    @ObservationIgnored
    @AppStorage("appearance") var appearance: Appearance = .system

    /// Whether to use reduced motion.
    @ObservationIgnored
    @AppStorage("reduceMotion") var reduceMotion = false

    // MARK: - Behavior

    /// Whether haptic feedback is enabled.
    @ObservationIgnored
    @AppStorage("hapticFeedback") var hapticFeedback = true

    /// Whether sound effects are enabled.
    @ObservationIgnored
    @AppStorage("soundEffects") var soundEffects = true

    // MARK: - Notifications

    /// Whether push notifications are enabled.
    @ObservationIgnored
    @AppStorage("notificationsEnabled") var notificationsEnabled = true

    /// Whether daily reminder notifications are enabled.
    @ObservationIgnored
    @AppStorage("dailyReminders") var dailyReminders = false

    // MARK: - Privacy

    /// Whether analytics collection is enabled.
    @ObservationIgnored
    @AppStorage("analyticsEnabled") var analyticsEnabled = true

    // MARK: - Initialization

    private init() {}
}

// MARK: - Appearance Enum

extension AppSettings {
    /// App appearance mode.
    enum Appearance: String, CaseIterable, Identifiable {
        case system
        case light
        case dark

        var id: String {
            rawValue
        }

        var displayName: String {
            switch self {
            case .system: "System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }

        var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }
    }
}

// MARK: - App Version

extension AppSettings {
    /// App version string (e.g., "1.0.0").
    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }

    /// App build number string.
    var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
    }

    /// Full version string (e.g., "1.0.0 (42)").
    var fullVersionString: String {
        "\(self.appVersion) (\(self.buildNumber))"
    }
}

// MARK: - Reset

extension AppSettings {
    /// Reset all settings to defaults.
    func resetToDefaults() {
        self.appearance = .system
        self.reduceMotion = false
        self.hapticFeedback = true
        self.soundEffects = true
        self.notificationsEnabled = true
        self.dailyReminders = false
        self.analyticsEnabled = true
    }
}

extension EnvironmentValues {
    @Entry var appSettings = AppSettings.shared
}
