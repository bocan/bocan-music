import Persistence
import SwiftUI

// MARK: - CollectionDetailView

/// A genre or composer destination that renders its contents either as the flat
/// track list (Songs, the historical default) or a grid of that collection's
/// albums (phase 23-3). The Songs / Albums choice is a persisted binding owned
/// by the caller (`genres.detailMode` / `composers.detailMode`).
///
/// Songs mode is byte-identical to the previous behaviour: the shared
/// `library.tracks` view model, already loaded with the genre/composer filter by
/// navigation. Albums mode uses a locally-owned `AlbumsViewModel` so a filtered
/// load never leaks into the shared full-library Albums grid.
struct CollectionDetailView: View {
    enum Kind {
        case genre
        case composer
    }

    let name: String
    let kind: Kind
    @Binding var mode: CollectionDetailMode
    var library: LibraryViewModel

    @StateObject private var albumsVM: AlbumsViewModel

    init(name: String, kind: Kind, mode: Binding<CollectionDetailMode>, library: LibraryViewModel) {
        self.name = name
        self.kind = kind
        self._mode = mode
        self.library = library
        self._albumsVM = StateObject(wrappedValue: AlbumsViewModel(repository: library.albumRepo))
    }

    var body: some View {
        Group {
            if self.mode == .albums {
                AlbumsGridView(vm: self.albumsVM, library: self.library, title: self.name)
                    // Loads on appear and whenever the collection changes; only
                    // fires while Albums mode is on, so Songs mode never fetches.
                    .task(id: self.name) { await self.loadAlbums() }
            } else {
                TracksView(vm: self.library.tracks, library: self.library, title: self.name)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                CollectionDetailModeToggle(mode: self.$mode)
            }
        }
    }

    private func loadAlbums() async {
        switch self.kind {
        case .genre:
            await self.albumsVM.load(genre: self.name)

        case .composer:
            await self.albumsVM.load(composer: self.name)
        }
    }
}
