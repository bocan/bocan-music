import Foundation

/// The Deep Dive switch (Settings > Library), off by default (#413).
///
/// Off means no MusicBrainz or Wikipedia request is ever made for a report
/// and the background artist lookup pass never starts; the Deep Dive tabs
/// stay visible with an explanation and a link to this control, so the
/// feature is discoverable without ever running unasked.
public enum DeepDiveSetting {
    /// The `UserDefaults` key behind the Settings toggle.
    public static let key = "deepDive.enabled"

    /// Whether the user has turned Deep Dive on.
    public static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: self.key)
    }
}
