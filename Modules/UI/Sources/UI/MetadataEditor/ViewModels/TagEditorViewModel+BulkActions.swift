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

    /// Applies `style` to the current shared value of `field`.
    /// No-op when the field is `.various` (values differ across tracks).
    func applyTextCase(_ style: TextCaseStyle, to field: StringField) {
        let (state, setter) = self.textFieldAccess(field)
        let current: String? = switch state {
        case let .shared(val), let .edited(val):
            val

        case .various:
            nil
        }
        guard let current else { return }
        setter(style.apply(to: current))
    }

    /// The current state of a string field and the setter that marks it edited.
    private func textFieldAccess(_ field: StringField) -> (FieldState<String>, @MainActor (String?) -> Void) {
        switch field {
        case .title:
            (self.title, self.setTitle)

        case .artist:
            (self.artist, self.setArtist)

        case .albumArtist:
            (self.albumArtist, self.setAlbumArtist)

        case .album:
            (self.album, self.setAlbum)

        case .genre:
            (self.genre, self.setGenre)

        case .composer:
            (self.composer, self.setComposer)

        case .comment:
            (self.comment, self.setComment)

        case .key:
            (self.key, self.setKey)

        case .isrc:
            (self.isrc, self.setISRC)

        case .sortArtist:
            (self.sortArtist, self.setSortArtist)

        case .sortAlbumArtist:
            (self.sortAlbumArtist, self.setSortAlbumArtist)

        case .sortAlbum:
            (self.sortAlbum, self.setSortAlbum)
        }
    }

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
