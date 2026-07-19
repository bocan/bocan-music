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

// MARK: - CollectionDetailMode

/// How a genre or composer *destination* renders its contents: a flat track list
/// (the historical behaviour) or a grid of that collection's albums.
///
/// Persisted per section with `@AppStorage` (`genres.detailMode`,
/// `composers.detailMode`), default `.songs` so today's behaviour is unchanged.
public enum CollectionDetailMode: String, CaseIterable, Sendable {
    case songs
    case albums
}
