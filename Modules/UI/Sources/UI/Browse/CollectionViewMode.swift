import Foundation

// MARK: - CollectionViewMode

/// How a collection listing (Artists, Genres, Composers) renders.
///
/// Persisted per section with `@AppStorage` (`artists.viewMode`,
/// `genres.viewMode`, `composers.viewMode`); the raw `String` representation
/// lets `@AppStorage` store it directly. `.list` is the default everywhere so
/// today's behaviour is preserved until the user opts into the grid.
public enum CollectionViewMode: String, CaseIterable, Sendable {
    case list
    case grid
}
