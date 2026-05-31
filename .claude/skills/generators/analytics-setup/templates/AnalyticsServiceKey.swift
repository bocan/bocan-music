import SwiftUI

extension EnvironmentValues {
    @Entry var analytics: AnalyticsService = NoOpAnalytics()
}

// MARK: - Screen Tracking Modifier

/// View modifier for automatic screen tracking.
///
/// Usage:
/// ```swift
/// SettingsView()
///     .trackScreen("Settings")
/// ```
struct AnalyticsScreenModifier: ViewModifier {
    let screenName: String
    @Environment(\.analytics) private var analytics

    func body(content: Content) -> some View {
        content.onAppear {
            self.analytics.track(.screenViewed(name: self.screenName))
        }
    }
}

extension View {
    /// Track when this screen appears.
    func trackScreen(_ name: String) -> some View {
        modifier(AnalyticsScreenModifier(screenName: name))
    }
}
