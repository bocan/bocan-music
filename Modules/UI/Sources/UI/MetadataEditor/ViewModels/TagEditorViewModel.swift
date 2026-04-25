import Foundation
import Library
import Metadata
import Observability
import Persistence
import SwiftUI

// MARK: - TagEditorViewModel

/// Drives the tag editor sheet (single or multi-track mode).
///
/// In single-track mode each field holds the current value.
/// In multi-track mode a field with multiple distinct values shows `.various`.
@MainActor
public final class TagEditorViewModel: ObservableObject {
    // MARK: - Field state

    /// A field that may be shared (single value), mixed (various), or edited.
    public enum FieldState<T: Equatable>: Equatable {
        case shared(T?) // all selected tracks have this value
        case various // selected tracks have distinct values
        case edited(T?) // user changed it; applies to all
    }

    // MARK: - Published fields

    @Published public var title: FieldState<String> = .shared(nil)
    @Published public var artist: FieldState<String> = .shared(nil)
    @Published public var albumArtist: FieldState<String> = .shared(nil)
    @Published public var album: FieldState<String> = .shared(nil)
    @Published public var genre: FieldState<String> = .shared(nil)
    @Published public var composer: FieldState<String> = .shared(nil)
    @Published public var comment: FieldState<String> = .shared(nil)
    @Published public var year: FieldState<Int> = .shared(nil)
    @Published public var trackNumber: FieldState<Int> = .shared(nil)
    @Published public var trackTotal: FieldState<Int> = .shared(nil)
    @Published public var discNumber: FieldState<Int> = .shared(nil)
    @Published public var discTotal: FieldState<Int> = .shared(nil)
    @Published public var bpm: FieldState<Double> = .shared(nil)
    @Published public var key: FieldState<String> = .shared(nil)
    @Published public var isrc: FieldState<String> = .shared(nil)
    @Published public var lyrics: FieldState<String> = .shared(nil)
    @Published public var sortArtist: FieldState<String> = .shared(nil)
    @Published public var sortAlbumArtist: FieldState<String> = .shared(nil)
    @Published public var sortAlbum: FieldState<String> = .shared(nil)
    @Published public var rating: FieldState<Int> = .shared(nil)
    @Published public var loved: FieldState<Bool> = .shared(nil)
    @Published public var excludedFromShuffle: FieldState<Bool> = .shared(nil)
    /// New art chosen by the user (file/paste/fetch/drop). Nil = no change.
    @Published public var pendingArtData: Data?
    /// Existing art loaded from the file at open time, shown when `pendingArtData` is nil.
    @Published public private(set) var existingArtData: Data?
    /// True when the user explicitly clicked Remove to delete existing art.
    public private(set) var artworkCleared = false

    // MARK: - Status

    @Published public private(set) var isSaving = false
    @Published public private(set) var isSingleTrack = false
    @Published public var lastError: String?
    @Published public var lastEditID: String?
    /// `true` once any save has successfully committed (never resets to false).
    public private(set) var didSave = false

    // MARK: - Dependencies

    private let service: MetadataEditService
    private let trackIDs: [Int64]
    private let log = AppLogger.make(.ui)

    // MARK: - Init

    public init(service: MetadataEditService, trackIDs: [Int64]) {
        self.service = service
        self.trackIDs = trackIDs
        self.isSingleTrack = trackIDs.count == 1
    }

    // MARK: - Load

    /// Loads tags for all selected tracks and populates fields.
    public func load() async {
        guard !self.trackIDs.isEmpty else { return }
        var allTags: [TrackTags] = []
        for id in self.trackIDs {
            if let tags = try? await self.service.readTags(trackID: id) {
                allTags.append(tags)
            }
        }
        guard !allTags.isEmpty else { return }
        self.populate(from: allTags)
        // Load first front-cover for display (picture type 3 = front cover).
        let art = allTags.first?.coverArt.first { $0.pictureType == 3 }
            ?? allTags.first?.coverArt.first
        self.existingArtData = art?.data
    }

    // MARK: - Save

    /// Builds a patch from edited fields and applies it.
    public func save() async {
        self.isSaving = true
        self.lastError = nil
        defer { self.isSaving = false }

        let patch = self.buildPatch()
        guard !patch.isEmpty else { return }

        do {
            let editID = try await self.service.edit(
                trackIDs: self.trackIDs,
                patch: patch
            )
            self.lastEditID = editID
            self.didSave = true
            self.log.debug("tag_editor.saved", ["count": self.trackIDs.count])
        } catch {
            self.lastError = error.localizedDescription
            self.log.error("tag_editor.save.failed", ["error": String(reflecting: error)])
        }
    }

    /// Undoes the last edit.
    public func undo() async {
        guard let editID = self.lastEditID else { return }
        do {
            try await self.service.undo(editID: editID)
            self.lastEditID = nil
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    // MARK: - Field helpers

    /// Marks `title` as edited with `value`.
    public func setTitle(_ value: String?) {
        self.title = .edited(value?.nilIfEmpty)
    }

    public func setArtist(_ value: String?) {
        self.artist = .edited(value?.nilIfEmpty)
    }

    public func setAlbumArtist(_ value: String?) {
        self.albumArtist = .edited(value?.nilIfEmpty)
    }

    public func setAlbum(_ value: String?) {
        self.album = .edited(value?.nilIfEmpty)
    }

    public func setGenre(_ value: String?) {
        self.genre = .edited(value?.nilIfEmpty)
    }

    public func setComposer(_ value: String?) {
        self.composer = .edited(value?.nilIfEmpty)
    }

    public func setComment(_ value: String?) {
        self.comment = .edited(value?.nilIfEmpty)
    }

    public func setYear(_ value: Int?) {
        self.year = .edited(value)
    }

    public func setTrackNumber(_ value: Int?) {
        self.trackNumber = .edited(value)
    }

    public func setTrackTotal(_ value: Int?) {
        self.trackTotal = .edited(value)
    }

    public func setDiscNumber(_ value: Int?) {
        self.discNumber = .edited(value)
    }

    public func setDiscTotal(_ value: Int?) {
        self.discTotal = .edited(value)
    }

    public func setBPM(_ value: Double?) {
        self.bpm = .edited(value)
    }

    public func setKey(_ value: String?) {
        self.key = .edited(value?.nilIfEmpty)
    }

    public func setISRC(_ value: String?) {
        self.isrc = .edited(value?.nilIfEmpty)
    }

    public func setLyrics(_ value: String?) {
        self.lyrics = .edited(value?.nilIfEmpty)
    }

    public func setSortArtist(_ value: String?) {
        self.sortArtist = .edited(value?.nilIfEmpty)
    }

    public func setSortAlbumArtist(_ value: String?) {
        self.sortAlbumArtist = .edited(value?.nilIfEmpty)
    }

    public func setSortAlbum(_ value: String?) {
        self.sortAlbum = .edited(value?.nilIfEmpty)
    }

    public func setRating(_ value: Int?) {
        self.rating = .edited(value)
    }

    public func setLoved(_ value: Bool?) {
        self.loved = .edited(value)
    }

    public func setExcludedFromShuffle(_ value: Bool?) {
        self.excludedFromShuffle = .edited(value)
    }

    /// Removes the cover art: clears pending data and marks the art as deleted.
    public func clearArtwork() {
        self.pendingArtData = nil
        self.existingArtData = nil
        self.artworkCleared = true
    }

    // MARK: - Private helpers

    private func populate(from allTags: [TrackTags]) {
        self.title = Self.fieldState(allTags.map(\.title))
        self.artist = Self.fieldState(allTags.map(\.artist))
        self.albumArtist = Self.fieldState(allTags.map(\.albumArtist))
        self.album = Self.fieldState(allTags.map(\.album))
        self.genre = Self.fieldState(allTags.map(\.genre))
        self.composer = Self.fieldState(allTags.map(\.composer))
        self.comment = Self.fieldState(allTags.map(\.comment))
        self.year = Self.fieldState(allTags.map(\.year))
        self.trackNumber = Self.fieldState(allTags.map(\.trackNumber))
        self.trackTotal = Self.fieldState(allTags.map(\.trackTotal))
        self.discNumber = Self.fieldState(allTags.map(\.discNumber))
        self.discTotal = Self.fieldState(allTags.map(\.discTotal))
        self.bpm = Self.fieldState(allTags.map(\.bpm))
        self.key = Self.fieldState(allTags.map(\.key))
        self.isrc = Self.fieldState(allTags.map(\.isrc))
        self.lyrics = Self.fieldState(allTags.map(\.lyrics))
        self.sortArtist = Self.fieldState(allTags.map(\.sortArtist))
        self.sortAlbumArtist = Self.fieldState(allTags.map(\.sortAlbumArtist))
        self.sortAlbum = Self.fieldState(allTags.map(\.sortAlbum))
    }

    private static func fieldState<T: Equatable>(_ values: [T?]) -> FieldState<T> {
        guard !values.isEmpty else { return .shared(nil) }
        let first = values[0]
        let allSame = values.dropFirst().allSatisfy { $0 == first }
        return allSame ? .shared(first) : .various
    }

    private func buildPatch() -> TrackTagPatch {
        var patch = TrackTagPatch()
        patch.title = Self.patchValue(self.title)
        patch.artist = Self.patchValue(self.artist)
        patch.albumArtist = Self.patchValue(self.albumArtist)
        patch.album = Self.patchValue(self.album)
        patch.genre = Self.patchValue(self.genre)
        patch.composer = Self.patchValue(self.composer)
        patch.comment = Self.patchValue(self.comment)
        patch.year = Self.patchValue(self.year)
        // trackNumber intentionally skipped in multi-edit (disabled per spec)
        if self.isSingleTrack {
            patch.trackNumber = Self.patchValue(self.trackNumber)
            patch.trackTotal = Self.patchValue(self.trackTotal)
        }
        patch.discNumber = Self.patchValue(self.discNumber)
        patch.discTotal = Self.patchValue(self.discTotal)
        patch.bpm = Self.patchValue(self.bpm)
        patch.key = Self.patchValue(self.key)
        patch.isrc = Self.patchValue(self.isrc)
        patch.lyrics = Self.patchValue(self.lyrics)
        patch.sortArtist = Self.patchValue(self.sortArtist)
        patch.sortAlbumArtist = Self.patchValue(self.sortAlbumArtist)
        patch.sortAlbum = Self.patchValue(self.sortAlbum)
        patch.rating = Self.patchValue(self.rating)
        if let loved = self.loved.editedValue { patch.loved = loved }
        if let efs = self.excludedFromShuffle.editedValue { patch.excludedFromShuffle = efs }
        if self.artworkCleared {
            patch.coverArt = .some(nil) // signals "remove art"
        } else if let artData = self.pendingArtData {
            patch.coverArt = artData
        }
        return patch
    }

    /// Converts an `.edited` field state into a `TrackTagPatch` double-optional.
    private static func patchValue<T>(_ state: FieldState<T>) -> T?? {
        if case let .edited(val) = state { return val }
        return nil
    }
}

// MARK: - FieldState extension

private extension TagEditorViewModel.FieldState {
    /// Returns the value when the state is `.edited`, otherwise `nil`.
    var editedValue: T?? {
        if case let .edited(val) = self { return val }
        return nil
    }
}

// MARK: - String extension

private extension String {
    var nilIfEmpty: String? {
        self.isEmpty ? nil : self
    }
}
