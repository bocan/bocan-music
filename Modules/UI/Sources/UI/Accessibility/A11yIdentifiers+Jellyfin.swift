import Foundation

/// Accessibility identifiers for the Jellyfin source (ADR-097). They live in
/// their own file because `A11yIdentifiers.swift` is at its line limit.
public extension A11y {
    /// Identifiers in the Jellyfin browse views.
    enum Jellyfin {
        /// The Jellyfin browse song table (an `NSTableView`).
        public static let songTable = "jellyfinSongsTable"
    }
}
