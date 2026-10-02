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

    /// Debounce window used when the user has set none, in milliseconds.
    public static let defaultObserveDebounceMilliseconds = 250

    /// The stored `liveUpdate` default for new smart playlists; `true` when
    /// the key was never set.
    public static func defaultLiveUpdate(userDefaults: UserDefaults = .standard) -> Bool {
        if userDefaults.object(forKey: self.defaultLiveUpdateKey) == nil {
            return true
        }
        return userDefaults.bool(forKey: self.defaultLiveUpdateKey)
    }

    /// The stored debounce window in milliseconds, clamped to 0...5000;
    /// `defaultObserveDebounceMilliseconds` when the key was never set.
    public static func observeDebounceMilliseconds(userDefaults: UserDefaults = .standard) -> Int {
        if userDefaults.object(forKey: self.observeDebounceMillisecondsKey) == nil {
            return self.defaultObserveDebounceMilliseconds
        }
        let value = userDefaults.integer(forKey: Self.observeDebounceMillisecondsKey)
        return max(0, min(5000, value))
    }

    /// The stored random-reroll setting; `false` when the key was never set.
    public static func randomRerollOnLaunch(userDefaults: UserDefaults = .standard) -> Bool {
        if userDefaults.object(forKey: self.randomRerollOnLaunchKey) == nil {
            return false
        }
        return userDefaults.bool(forKey: self.randomRerollOnLaunchKey)
    }
}
