import Foundation

// MARK: - Cover-art search seeding

extension TagEditorViewModel {
    /// Seeds the cover-art fetch sheet's search fields from the loaded tags so
    /// it opens ready to search instead of blank. Called by the "Fetch…" button
    /// before presenting the sheet.
    ///
    /// Anything the user already typed into the fields is never overwritten.
    /// Album artist is preferred over track artist: release-groups are credited
    /// to the album artist, so it matches compilations and split credits better.
    func prepareCoverArtSearch() {
        guard self.coverArtFetchVM.searchArtist.isEmpty,
              self.coverArtFetchVM.searchAlbum.isEmpty else { return }
        self.coverArtFetchVM.searchArtist = Self.displayValue(self.albumArtist)
            ?? Self.displayValue(self.artist) ?? ""
        self.coverArtFetchVM.searchAlbum = Self.displayValue(self.album) ?? ""
    }

    /// The single displayable value of a field, or nil when the selection has
    /// mixed values (`.various`) — a mixed field cannot seed a search.
    private static func displayValue(_ state: FieldState<String>) -> String? {
        switch state {
        case let .shared(value):
            value

        case let .edited(value):
            value

        case .various:
            nil
        }
    }
}
