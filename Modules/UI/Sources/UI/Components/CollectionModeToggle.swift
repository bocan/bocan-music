import SwiftUI

// MARK: - CollectionViewModeToggle

/// The List / Grid segmented toggle shared by the Artists, Genres, and Composers
/// toolbars (phase 23). One definition replaces a copy in each view: icons with
/// localized accessibility labels, a help tip, and hidden labels.
struct CollectionViewModeToggle: View {
    @Binding var mode: CollectionViewMode

    var body: some View {
        Picker(L10n.string("Choose how this view is displayed"), selection: self.$mode) {
            Image(systemName: "list.bullet")
                .accessibilityLabel(L10n.string("View as list"))
                .tag(CollectionViewMode.list)
            Image(systemName: "square.grid.2x2")
                .accessibilityLabel(L10n.string("View as grid"))
                .tag(CollectionViewMode.grid)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .help(L10n.string("Choose how this view is displayed"))
    }
}

// MARK: - CollectionDetailModeToggle

/// The Songs / Albums segmented toggle for the genre and composer destinations,
/// same conventions as ``CollectionViewModeToggle``.
struct CollectionDetailModeToggle: View {
    @Binding var mode: CollectionDetailMode

    var body: some View {
        Picker(L10n.string("Choose how this view is displayed"), selection: self.$mode) {
            Image(systemName: "music.note.list")
                .accessibilityLabel(L10n.string("Show songs"))
                .tag(CollectionDetailMode.songs)
            Image(systemName: "square.grid.2x2")
                .accessibilityLabel(L10n.string("Show albums"))
                .tag(CollectionDetailMode.albums)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .help(L10n.string("Choose how this view is displayed"))
    }
}
