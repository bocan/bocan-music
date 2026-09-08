import Foundation

// MARK: - TagEditorViewModel field setters

/// The per-field "mark as edited" entry points the editor's controls call.
/// Split from `TagEditorViewModel.swift` to keep that file inside the lint
/// length limit. In multi-track mode a setter also enables the field so the
/// batch save knows it was touched; single-track mode saves every field.
public extension TagEditorViewModel {
    /// Marks `title` as edited with `value`.
    func setTitle(_ value: String?) {
        self.title = .edited(value?.nilIfEmpty)
        if !self.isSingleTrack {
            self.enabledFields.insert(.title)
        }
    }

    /// Marks `artist` as edited with `value`.
    func setArtist(_ value: String?) {
        self.artist = .edited(value?.nilIfEmpty)
        if !self.isSingleTrack {
            self.enabledFields.insert(.artist)
        }
    }

    /// Marks `albumArtist` as edited with `value`.
    func setAlbumArtist(_ value: String?) {
        self.albumArtist = .edited(value?.nilIfEmpty)
        if !self.isSingleTrack {
            self.enabledFields.insert(.albumArtist)
        }
    }

    /// Marks `album` as edited with `value`.
    func setAlbum(_ value: String?) {
        self.album = .edited(value?.nilIfEmpty)
        if !self.isSingleTrack {
            self.enabledFields.insert(.album)
        }
    }

    /// Marks `genre` as edited with `value`.
    func setGenre(_ value: String?) {
        self.genre = .edited(value?.nilIfEmpty)
        if !self.isSingleTrack {
            self.enabledFields.insert(.genre)
        }
    }

    /// Marks `composer` as edited with `value`.
    func setComposer(_ value: String?) {
        self.composer = .edited(value?.nilIfEmpty)
        if !self.isSingleTrack {
            self.enabledFields.insert(.composer)
        }
    }

    /// Marks `comment` as edited with `value`.
    func setComment(_ value: String?) {
        self.comment = .edited(value?.nilIfEmpty)
        if !self.isSingleTrack {
            self.enabledFields.insert(.comment)
        }
    }

    /// Marks `year` as edited with `value`.
    func setYear(_ value: Int?) {
        self.year = .edited(value)
        if !self.isSingleTrack {
            self.enabledFields.insert(.year)
        }
    }

    /// Marks `trackNumber` as edited with `value`.
    func setTrackNumber(_ value: Int?) {
        self.trackNumber = .edited(value)
    }

    /// Marks `trackTotal` as edited with `value`.
    func setTrackTotal(_ value: Int?) {
        self.trackTotal = .edited(value)
    }

    /// Marks `discNumber` as edited with `value`.
    func setDiscNumber(_ value: Int?) {
        self.discNumber = .edited(value)
        if !self.isSingleTrack {
            self.enabledFields.insert(.discNumber)
        }
    }

    /// Marks `discTotal` as edited with `value`.
    func setDiscTotal(_ value: Int?) {
        self.discTotal = .edited(value)
        if !self.isSingleTrack {
            self.enabledFields.insert(.discTotal)
        }
    }

    /// Marks `bpm` as edited with `value`.
    func setBPM(_ value: Double?) {
        self.bpm = .edited(value)
        if !self.isSingleTrack {
            self.enabledFields.insert(.bpm)
        }
    }

    /// Marks `key` as edited with `value`.
    func setKey(_ value: String?) {
        self.key = .edited(value?.nilIfEmpty)
        if !self.isSingleTrack {
            self.enabledFields.insert(.musicalKey)
        }
    }

    /// Marks `isrc` as edited with `value`.
    func setISRC(_ value: String?) {
        self.isrc = .edited(value?.nilIfEmpty)
        if !self.isSingleTrack {
            self.enabledFields.insert(.isrc)
        }
    }

    /// Marks `lyrics` as edited with `value`.
    func setLyrics(_ value: String?) {
        self.lyrics = .edited(value?.nilIfEmpty)
        if !self.isSingleTrack {
            self.enabledFields.insert(.lyrics)
        }
    }

    /// Marks `sortArtist` as edited with `value`.
    func setSortArtist(_ value: String?) {
        self.sortArtist = .edited(value?.nilIfEmpty)
        if !self.isSingleTrack {
            self.enabledFields.insert(.sortArtist)
        }
    }

    /// Marks `sortAlbumArtist` as edited with `value`.
    func setSortAlbumArtist(_ value: String?) {
        self.sortAlbumArtist = .edited(value?.nilIfEmpty)
        if !self.isSingleTrack {
            self.enabledFields.insert(.sortAlbumArtist)
        }
    }

    /// Marks `sortAlbum` as edited with `value`.
    func setSortAlbum(_ value: String?) {
        self.sortAlbum = .edited(value?.nilIfEmpty)
        if !self.isSingleTrack {
            self.enabledFields.insert(.sortAlbum)
        }
    }

    /// Marks `rating` as edited with `value`.
    func setRating(_ value: Int?) {
        self.rating = .edited(value)
        if !self.isSingleTrack {
            self.enabledFields.insert(.rating)
        }
    }

    /// Marks `loved` as edited with `value`.
    func setLoved(_ value: Bool?) {
        self.loved = .edited(value)
        if !self.isSingleTrack {
            self.enabledFields.insert(.loved)
        }
    }

    /// Marks `excludedFromShuffle` as edited with `value`.
    func setExcludedFromShuffle(_ value: Bool?) {
        self.excludedFromShuffle = .edited(value)
        if !self.isSingleTrack {
            self.enabledFields.insert(.excludedFromShuffle)
        }
    }
}
