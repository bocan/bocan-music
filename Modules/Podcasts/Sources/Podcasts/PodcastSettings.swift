import Foundation
import os

/// The Settings > Podcasts choices this module acts on: how often feeds
/// refresh, whether a launch refreshes them, and which Apple Podcasts
/// storefront search uses (#605).
///
/// The Settings pane (in `UI`, which cannot import this module) writes the raw
/// values through `@AppStorage`; this type owns what they mean, so the mapping
/// is in one tested place and the App layer only passes it on.
public struct PodcastSettings: Sendable, Equatable {
    /// The `UserDefaults` keys the Settings pane writes.
    public enum Key {
        /// `Int` minutes; `0` is "Manual only".
        public static let refreshInterval = "podcasts.refreshInterval"
        /// `Bool`.
        public static let refreshOnLaunch = "podcasts.refreshOnLaunch"
        /// `String`, a lower-case ISO 3166-1 alpha-2 code such as `gb`.
        public static let storefront = "podcasts.storefront"
    }

    /// The pane's default interval, used when nothing is stored.
    public static let defaultRefreshMinutes = 30
    /// The storefront used when nothing usable is stored.
    public static let defaultStorefront = "US"

    /// Seconds between scheduled refresh passes; `nil` is "Manual only".
    public var refreshInterval: TimeInterval?
    /// Whether the scheduler refreshes once when it starts at launch.
    public var refreshOnLaunch: Bool
    /// The iTunes Search API `country` value, upper case.
    public var storefront: String

    /// Maps the stored raw values. A missing value takes the pane's default; a
    /// zero or negative interval is "Manual only"; a storefront that is not
    /// two ASCII letters falls back to the US store.
    public init(
        refreshIntervalMinutes: Int? = nil,
        refreshOnLaunch: Bool? = nil,
        storefront: String? = nil
    ) {
        let minutes = refreshIntervalMinutes ?? Self.defaultRefreshMinutes
        self.refreshInterval = minutes > 0 ? TimeInterval(minutes) * 60 : nil
        self.refreshOnLaunch = refreshOnLaunch ?? true
        self.storefront = Self.country(from: storefront)
    }

    /// Reads the current values from `defaults`.
    public init(defaults: UserDefaults) {
        self.init(
            refreshIntervalMinutes: defaults.object(forKey: Key.refreshInterval) as? Int,
            refreshOnLaunch: defaults.object(forKey: Key.refreshOnLaunch) as? Bool,
            storefront: defaults.string(forKey: Key.storefront)
        )
    }

    /// A scheduled pass skips a feed refreshed more recently than this.
    ///
    /// Half the interval: passes are one interval apart, so every feed the
    /// last pass touched is due again at the next one, while a relaunch or a
    /// restarted loop shortly after a pass does not fetch everything twice.
    /// "Manual only" has no interval, so its launch refresh checks every show.
    public var staleAge: TimeInterval {
        (self.refreshInterval ?? 0) / 2
    }

    private static func country(from raw: String?) -> String {
        guard let raw else { return self.defaultStorefront }
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let letters = code.unicodeScalars.allSatisfy { ("A" ... "Z").contains($0) }
        return code.count == 2 && letters ? code : self.defaultStorefront
    }
}

// MARK: - Change stream

public extension PodcastSettings {
    /// Emits the settings each time one of them changes in `defaults`, in the
    /// order the changes happened. Does not emit the current value on start.
    ///
    /// `UserDefaults.didChangeNotification` fires for every key in the domain,
    /// so the stream compares against the last value it saw and stays silent
    /// for unrelated writes. The observer is removed when the stream ends.
    static func changes(in defaults: UserDefaults = .standard) -> AsyncStream<PodcastSettings> {
        // UserDefaults is documented as thread-safe but is not marked Sendable.
        nonisolated(unsafe) let defaults = defaults
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let last = OSAllocatedUnfairLock(initialState: PodcastSettings(defaults: defaults))
            let token = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: defaults,
                queue: nil
            ) { _ in
                let current = PodcastSettings(defaults: defaults)
                let changed = last.withLock { seen in
                    guard seen != current else { return false }
                    seen = current
                    return true
                }
                if changed {
                    continuation.yield(current)
                }
            }
            // The token is only ever handed back to NotificationCenter, which
            // is thread-safe; it has no Sendable conformance of its own.
            nonisolated(unsafe) let observer = token
            continuation.onTermination = { _ in
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}
