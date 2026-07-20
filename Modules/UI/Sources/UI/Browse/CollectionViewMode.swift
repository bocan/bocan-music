import SwiftUI

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

// MARK: - CollectionViewModeStorage

/// `@AppStorage`-backed persistence for a ``CollectionViewMode`` that survives
/// *cross-instance* updates.
///
/// SwiftUI's `@AppStorage` does not reliably invalidate a *different* instance
/// when a `RawRepresentable` value is written elsewhere: a write from the "View
/// as" menu in `BocanCommands` frequently fails to redraw the separate instance
/// the Artists/Genres/Composers toolbars observe on the same key, so the listing
/// only switches when some unrelated event happens to re-render it. The
/// primitive `String` overload *does* propagate reliably (the same reason the
/// menu's `Bool` pane-visibility mirrors work), so this wrapper stores the raw
/// value as a `String` and projects the enum, giving the menu and the toolbars a
/// single dependable source of truth. See `phase23-3-view-menu-destination-albums`.
@propertyWrapper
public struct CollectionViewModeStorage: DynamicProperty {
    @AppStorage private var rawValue: String

    public init(_ key: String) {
        self._rawValue = AppStorage(wrappedValue: CollectionViewMode.list.rawValue, key)
    }

    public var wrappedValue: CollectionViewMode {
        get { CollectionViewMode(rawValue: self.rawValue) ?? .list }
        nonmutating set { self.rawValue = newValue.rawValue }
    }

    public var projectedValue: Binding<CollectionViewMode> {
        Binding(
            get: { CollectionViewMode(rawValue: self.rawValue) ?? .list },
            set: { self.rawValue = $0.rawValue }
        )
    }
}
