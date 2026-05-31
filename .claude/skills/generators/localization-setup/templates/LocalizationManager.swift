import Foundation
import SwiftUI

/// Manages app localization and language preferences.
///
/// Usage:
/// ```swift
/// // Access current language
/// let manager = LocalizationManager.shared
/// print(manager.currentLanguageCode)  // "en"
///
/// // Change language (requires app restart for full effect)
/// manager.setLanguage("es")
///
/// // Get display name
/// manager.displayName(for: "ja")  // "Japanese"
/// ```
@MainActor
@Observable
final class LocalizationManager {
    // MARK: - Singleton

    static let shared = LocalizationManager()

    // MARK: - Properties

    /// Current language code (e.g., "en", "es", "ja")
    private(set) var currentLanguageCode: String

    /// Current locale based on selected language
    var currentLocale: Locale {
        Locale(identifier: self.currentLanguageCode)
    }

    /// Languages supported by the app (from bundle localizations)
    var supportedLanguages: [String] {
        Bundle.main.localizations
            .filter { $0 != "Base" }
            .sorted()
    }

    /// Language codes with their display names
    var languageOptions: [(code: String, name: String)] {
        self.supportedLanguages.map { code in
            (code: code, name: self.displayName(for: code))
        }
    }

    // MARK: - Initialization

    private init() {
        // Get preferred language or default to English
        self.currentLanguageCode = Locale.preferredLanguages.first?.components(separatedBy: "-").first ?? "en"
    }

    // MARK: - Language Management

    /// Set the app language.
    ///
    /// - Parameter code: Language code (e.g., "en", "es", "ja")
    /// - Note: Full language change requires app restart.
    ///         For SwiftUI views, use `.environment(\.locale, locale)` modifier.
    func setLanguage(_ code: String) {
        guard self.supportedLanguages.contains(code) else {
            print("⚠️ Language '\(code)' not supported. Available: \(self.supportedLanguages)")
            return
        }

        self.currentLanguageCode = code

        // Update system preference (takes effect on next launch)
        UserDefaults.standard.set([code], forKey: "AppleLanguages")
        UserDefaults.standard.synchronize()
    }

    /// Get localized display name for a language code.
    ///
    /// - Parameter code: Language code (e.g., "en", "es")
    /// - Returns: Display name in current locale (e.g., "English", "Spanish")
    func displayName(for code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    /// Get native display name for a language code.
    ///
    /// - Parameter code: Language code (e.g., "en", "es")
    /// - Returns: Display name in that language (e.g., "English", "Español")
    func nativeDisplayName(for code: String) -> String {
        Locale(identifier: code).localizedString(forLanguageCode: code) ?? code
    }

    /// Check if current language is RTL (right-to-left).
    var isRightToLeft: Bool {
        Locale.characterDirection(forLanguage: self.currentLanguageCode) == .rightToLeft
    }

    /// Get the layout direction for current language.
    var layoutDirection: LayoutDirection {
        self.isRightToLeft ? .rightToLeft : .leftToRight
    }
}

extension EnvironmentValues {
    @Entry var localizationManager = LocalizationManager.shared
}

// MARK: - Language Picker View

/// A picker for selecting the app language.
///
/// Usage:
/// ```swift
/// LanguagePickerView()
/// ```
struct LanguagePickerView: View {
    @Environment(\.localizationManager) private var manager

    @State private var selectedLanguage = ""

    var body: some View {
        Picker("Language", selection: self.$selectedLanguage) {
            ForEach(self.manager.languageOptions, id: \.code) { option in
                HStack {
                    Text(option.name)
                    if option.code != self.manager.currentLanguageCode {
                        Text("(\(self.manager.nativeDisplayName(for: option.code)))")
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(option.code)
            }
        }
        .onAppear {
            self.selectedLanguage = self.manager.currentLanguageCode
        }
        .onChange(of: self.selectedLanguage) { _, newValue in
            if newValue != self.manager.currentLanguageCode {
                self.manager.setLanguage(newValue)
                self.showRestartAlert()
            }
        }
    }

    private func showRestartAlert() {
        // Note: In production, show an alert explaining restart is needed
        print("Language changed. Restart app to apply changes.")
    }
}

// MARK: - Locale Environment Modifier

extension View {
    /// Apply localization manager's locale to the view hierarchy.
    func withLocalization() -> some View {
        self.environment(\.locale, LocalizationManager.shared.currentLocale)
            .environment(\.layoutDirection, LocalizationManager.shared.layoutDirection)
    }
}

// MARK: - Preview Helpers

#if DEBUG
    extension View {
        /// Preview this view in multiple locales.
        func previewInLocales(_ locales: [String] = ["en", "es", "ja", "ar"]) -> some View {
            ForEach(locales, id: \.self) { locale in
                self
                    .environment(\.locale, Locale(identifier: locale))
                    .environment(
                        \.layoutDirection,
                        Locale.characterDirection(forLanguage: locale) == .rightToLeft
                            ? .rightToLeft : .leftToRight
                    )
                    .previewDisplayName(Locale.current.localizedString(forIdentifier: locale) ?? locale)
            }
        }
    }
#endif
