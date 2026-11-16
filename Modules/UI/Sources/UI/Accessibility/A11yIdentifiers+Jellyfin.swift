import Foundation

/// Accessibility identifiers for the Jellyfin source (ADR-097). They live in
/// their own file because `A11yIdentifiers.swift` is at its line limit.
public extension A11y {
    /// Identifiers in the Jellyfin browse views.
    enum Jellyfin {
        /// The Jellyfin browse song table (an `NSTableView`).
        public static let songTable = "jellyfinSongsTable"
        /// A Jellyfin server's disclosure row in the sidebar (slice 9). The
        /// same for every server: the E2E journey adds only one.
        public static let sidebarServer = "sidebar.jellyfin.server"

        /// One of the nine rows under a Jellyfin server, by its key
        /// (`songs`, `albums`, ...). Without an identifier a tag-selected
        /// List row is not in the accessibility tree at all (ADR-081).
        public static func sidebarRow(_ key: String) -> String {
            "sidebar.jellyfin.\(key)"
        }
    }

    /// Identifiers in Settings, Sources (ADR-097 slice 7). The identifier audit
    /// walks the Sources page, and the slice 9 journey adds a server through it.
    enum JellyfinSettings {
        /// The Subsonic / Jellyfin switch at the top of the Sources page.
        public static let kindPicker = "settings.sources.kind"
        /// "Add Server" under the server list.
        public static let addServer = "settings.jellyfin.addServer"
        /// "Add Server" in the empty state.
        public static let addServerEmpty = "settings.jellyfin.addServer.empty"
        /// "Test All" under the server list.
        public static let testAll = "settings.jellyfin.testAll"
        /// The editor's display name field.
        public static let displayName = "settings.jellyfin.name"
        /// The editor's server address field.
        public static let serverURL = "settings.jellyfin.url"
        /// "Test Server".
        public static let testServer = "settings.jellyfin.testServer"
        /// The self-signed certificate toggle.
        public static let allowSelfSigned = "settings.jellyfin.allowSelfSigned"
        /// The sign-in user name field.
        public static let username = "settings.jellyfin.username"
        /// The sign-in password field.
        public static let password = "settings.jellyfin.password"
        /// "Sign In".
        public static let signIn = "settings.jellyfin.signIn"
        /// "Use Quick Connect".
        public static let quickConnect = "settings.jellyfin.quickConnect"
        /// "Cancel" while a Quick Connect code waits for approval.
        public static let quickConnectCancel = "settings.jellyfin.quickConnect.cancel"
        /// The preferred format menu.
        public static let preferredFormat = "settings.jellyfin.format"
        /// The bitrate limit switch (no limit or a cap).
        public static let bitrateKind = "settings.jellyfin.bitrateKind"
        /// The bitrate cap menu.
        public static let bitrate = "settings.jellyfin.bitrate"
        /// The pre-cache toggle.
        public static let precacheNext = "settings.jellyfin.precache"
        /// The global search toggle.
        public static let includeInSearch = "settings.jellyfin.includeInSearch"
        /// The sidebar visibility toggle.
        public static let showInSidebar = "settings.jellyfin.showInSidebar"
        /// The play report toggle.
        public static let scrobble = "settings.jellyfin.scrobble"
        /// The favourites toggle.
        public static let syncStars = "settings.jellyfin.syncStars"
        /// "Remove" in the editor.
        public static let remove = "settings.jellyfin.remove"
        /// "Save" in the editor.
        public static let save = "settings.jellyfin.save"
    }
}
