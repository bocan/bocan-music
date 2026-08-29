import SwiftUI

// MARK: - ArtistContextMenu

/// Get Info (#413) and Remove, shared by the artist page header and the list rows.
struct ArtistContextMenu: View {
    let id: Int64
    let name: String
    let library: LibraryViewModel

    var body: some View {
        Button(L10n.string("Get Info")) { self.library.showArtistInfo(id: self.id) }
        Divider()
        Button(L10n.string("Remove Artist from Library"), role: .destructive) {
            Task { await RemoveFromLibraryConfirm.artist(id: self.id, name: self.name, library: self.library) }
        }
    }
}
