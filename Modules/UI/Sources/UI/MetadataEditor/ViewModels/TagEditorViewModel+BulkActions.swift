import Library
import Observability
import SwiftUI

// MARK: - Bulk-action types

/// Bulk-action types for the multi-track metadata editor.
public extension TagEditorViewModel {
    /// Text-field case-transformation styles available in the Bulk Actions section.
    enum TextCaseStyle {
        /// Capitalise the first letter of each word.
        case titleCase
        /// Convert all characters to uppercase.
        case upper
        /// Convert all characters to lowercase.
        case lower

        func apply(to string: String) -> String {
            switch self {
            case .titleCase:
                string.capitalized

            case .upper:
                string.uppercased()

            case .lower:
                string.lowercased()
            }
        }
    }

    /// Text fields that support bulk case transformation.
    enum StringField: CaseIterable {
        case title, artist, albumArtist, album, genre, composer, comment, key, isrc
        case sortArtist, sortAlbumArtist, sortAlbum

        public var label: LocalizedStringKey {
            switch self {
            case .title:
                "Title"

            case .artist:
                "Artist"

            case .albumArtist:
                "Album Artist"

            case .album:
                "Album"

            case .genre:
                "Genre"

            case .composer:
                "Composer"

            case .comment:
                "Comment"

            case .key:
                "Key"

            case .isrc:
                "ISRC"

            case .sortArtist:
                "Sort Artist"

            case .sortAlbumArtist:
                "Sort Album Artist"

            case .sortAlbum:
                "Sort Album"
            }
        }
    }
}

// MARK: - Bulk-action methods

/// Bulk-action methods for the multi-track metadata editor.
public extension TagEditorViewModel {
    /// `true` when the selected tracks belong to more than one album.
    /// Used to warn before renumbering across albums.
    var tracksSpanMultipleAlbums: Bool {
        let albumIDs = Set(self.trackIDs.compactMap { self.loadedTracksByID[$0]?.albumID })
        return albumIDs.count > 1
    }

    // swiftlint:disable cyclomatic_complexity
    /// Applies `style` to the current shared value of `field`.
    /// No-op when the field is `.various` (values differ across tracks).
    func applyTextCase(_ style: TextCaseStyle, to field: StringField) {
        func transformed(_ state: FieldState<String>) -> String? {
            switch state {
            case let .shared(val):
                val.map { style.apply(to: $0) }

            case let .edited(val):
                val.map { style.apply(to: $0) }

            case .various:
                nil
            }
        }
        switch field {
        case .title:
            if let val = transformed(self.title) { self.setTitle(val) }

        case .artist:
            if let val = transformed(self.artist) { self.setArtist(val) }

        case .albumArtist:
            if let val = transformed(self.albumArtist) { self.setAlbumArtist(val) }

        case .album:
            if let val = transformed(self.album) { self.setAlbum(val) }

        case .genre:
            if let val = transformed(self.genre) { self.setGenre(val) }

        case .composer:
            if let val = transformed(self.composer) { self.setComposer(val) }

        case .comment:
            if let val = transformed(self.comment) { self.setComment(val) }

        case .key:
            if let val = transformed(self.key) { self.setKey(val) }

        case .isrc:
            if let val = transformed(self.isrc) { self.setISRC(val) }

        case .sortArtist:
            if let val = transformed(self.sortArtist) { self.setSortArtist(val) }

        case .sortAlbumArtist:
            if let val = transformed(self.sortAlbumArtist) { self.setSortAlbumArtist(val) }

        case .sortAlbum:
            if let val = transformed(self.sortAlbum) { self.setSortAlbum(val) }
        }
    }

    // swiftlint:enable cyclomatic_complexity

    /// Assigns sequential track numbers (1…N) to the selected tracks in the
    /// order they were passed to the view model (caller's sort order).
    ///
    /// Saves immediately per-track; afterwards reloads field state.
    /// Undo is not supported for this operation.
    func renumberTracks() async {
        self.isApplyingBulkAction = true
        self.lastEditID = nil
        defer { self.isApplyingBulkAction = false }
        self.log.debug("bulk.renumber.start", ["count": self.trackIDs.count])
        let start = Date()
        for (index, id) in self.trackIDs.enumerated() {
            var patch = TrackTagPatch()
            patch.trackNumber = index + 1
            do {
                try await self.service.edit(trackID: id, patch: patch)
            } catch {
                self.lastError = error.localizedDescription
                self.log.error("bulk.renumber.failed", ["trackID": id, "error": String(reflecting: error)])
                return
            }
        }
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        self.log.debug("bulk.renumber.end", ["count": self.trackIDs.count, "ms": ms])
        await self.load()
    }

    /// Copies each track's artist value into its albumArtist field.
    ///
    /// Saves immediately per-track; afterwards reloads field state.
    /// Undo is not supported for this operation.
    func copyArtistToAlbumArtist() async {
        self.isApplyingBulkAction = true
        self.lastEditID = nil
        defer { self.isApplyingBulkAction = false }
        self.log.debug("bulk.copy_artist.start", ["count": self.trackIDs.count])
        let start = Date()
        for id in self.trackIDs {
            guard let artist = self.loadedTagsByID[id]?.artist else { continue }
            var patch = TrackTagPatch()
            patch.albumArtist = artist
            do {
                try await self.service.edit(trackID: id, patch: patch)
            } catch {
                self.lastError = error.localizedDescription
                self.log.error("bulk.copy_artist.failed", ["trackID": id, "error": String(reflecting: error)])
                return
            }
        }
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        self.log.debug("bulk.copy_artist.end", ["count": self.trackIDs.count, "ms": ms])
        await self.load()
    }
}
