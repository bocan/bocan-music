import Foundation

// MARK: - SmartPlaylistPreferences

/// User-facing preference keys and defaults for smart-playlist behavior.
public enum SmartPlaylistPreferences {
    /// Default `liveUpdate` value for newly created smart playlists.
    public static let defaultLiveUpdateKey = "smartPlaylists.defaultLiveUpdate"

    /// Debounce window for smart-playlist observation, in milliseconds.
    public static let observeDebounceMillisecondsKey = "smartPlaylists.observeDebounceMilliseconds"

    /// Whether random sort should use a per-launch seed component.
    public static let randomRerollOnLaunchKey = "smartPlaylists.randomRerollOnLaunch"

    public static let defaultObserveDebounceMilliseconds = 250

    public static func defaultLiveUpdate(userDefaults: UserDefaults = .standard) -> Bool {
        if userDefaults.object(forKey: self.defaultLiveUpdateKey) == nil {
            return true
        }
        return userDefaults.bool(forKey: self.defaultLiveUpdateKey)
    }

    public static func observeDebounceMilliseconds(userDefaults: UserDefaults = .standard) -> Int {
        if userDefaults.object(forKey: self.observeDebounceMillisecondsKey) == nil {
            return self.defaultObserveDebounceMilliseconds
        }
        let value = userDefaults.integer(forKey: Self.observeDebounceMillisecondsKey)
        return max(0, min(5000, value))
    }

    public static func randomRerollOnLaunch(userDefaults: UserDefaults = .standard) -> Bool {
        if userDefaults.object(forKey: self.randomRerollOnLaunchKey) == nil {
            return false
        }
        return userDefaults.bool(forKey: self.randomRerollOnLaunchKey)
    }
}
