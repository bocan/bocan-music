// MARK: - GenreSortOrder

/// Sort order for the Genres list.
enum GenreSortOrder: String, CaseIterable, SortMenuOption {
    /// Song count, most first, then genre name (the historical default).
    case songCount
    /// Genre name, A->Z.
    case genreName

    /// Localized label shown in the list's sort menu.
    var displayName: String {
        switch self {
        case .songCount:
            L10n.string("Song Count")

        case .genreName:
            L10n.string("Genre Name")
        }
    }
}

// MARK: - ComposerSortOrder

/// Sort order for the Composers list.
enum ComposerSortOrder: String, CaseIterable, SortMenuOption {
    /// Composer name, A->Z (the default).
    case composerName
    /// Song count, most first, then composer name.
    case songCount

    /// Localized label shown in the list's sort menu.
    var displayName: String {
        switch self {
        case .composerName:
            L10n.string("Composer Name")

        case .songCount:
            L10n.string("Song Count")
        }
    }
}
