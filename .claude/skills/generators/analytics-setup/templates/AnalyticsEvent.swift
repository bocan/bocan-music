import Foundation

/// App analytics events.
///
/// Add your app-specific events here. Use past tense for completed actions.
///
/// Example usage:
/// ```swift
/// analytics.track(.screenViewed(name: "Settings"))
/// analytics.track(.buttonTapped("subscribe"))
/// analytics.track(.featureUsed("dark_mode"))
/// ```
enum AnalyticsEvent {
    // MARK: - App Lifecycle

    /// App launched (cold start)
    case appLaunched

    /// App moved to background
    case appBackgrounded

    /// App returned to foreground
    case appForegrounded

    // MARK: - Navigation

    /// Screen was viewed
    case screenViewed(name: String)

    // MARK: - User Actions

    /// Button was tapped
    case buttonTapped(name: String)

    /// Feature was used/enabled
    case featureUsed(name: String)

    /// Search performed
    case searchPerformed(query: String)

    // MARK: - Errors

    /// Error occurred
    case errorOccurred(domain: String, code: Int)

    // MARK: - Custom Events

    /// Custom event with properties
    case custom(name: String, properties: [String: String])

    // MARK: - Add Your Events Below

    // Example:
    // case itemCreated(type: String)
    // case itemDeleted(type: String)
    // case subscriptionStarted(plan: String)
    // case settingsChanged(setting: String, value: String)
}

// MARK: - Event Names

extension AnalyticsEvent {
    /// The event name string used for tracking.
    var name: String {
        switch self {
        case .appLaunched:
            "app_launched"
        case .appBackgrounded:
            "app_backgrounded"
        case .appForegrounded:
            "app_foregrounded"
        case let .screenViewed(name):
            "screen_viewed_\(name.lowercased().replacingOccurrences(of: " ", with: "_"))"
        case let .buttonTapped(name):
            "button_tapped_\(name.lowercased())"
        case let .featureUsed(name):
            "feature_used_\(name.lowercased())"
        case .searchPerformed:
            "search_performed"
        case let .errorOccurred(domain, code):
            "error_\(domain.lowercased())_\(code)"
        case let .custom(name, _):
            name
        }
    }

    /// Additional properties for the event.
    var properties: [String: String] {
        switch self {
        case let .screenViewed(name):
            ["screen_name": name]
        case let .buttonTapped(name):
            ["button_name": name]
        case let .featureUsed(name):
            ["feature_name": name]
        case let .searchPerformed(query):
            // Don't track exact query for privacy - just that search was used
            ["query_length": String(query.count)]
        case let .errorOccurred(domain, code):
            ["error_domain": domain, "error_code": String(code)]
        case let .custom(_, properties):
            properties
        default:
            [:]
        }
    }
}
