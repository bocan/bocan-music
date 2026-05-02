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

    /// Identifies a tag field for the per-field enable/disable mechanism in multi-track editing.
    ///
    /// In single-track mode `enabledFields` is ignored — all edited fields are always written.
    /// In multi-track mode a field is written on Save only when it is both `.edited` **and**
    /// present in `enabledFields` (which is auto-populated when the user types in a field).
    public enum FieldKey: String, CaseIterable, Hashable, Sendable {
        /// Text fields present in the Details tab.
        case title, artist, albumArtist, album, genre, composer, comment
        /// Numeric fields present in the Details tab.
        case year, discNumber, discTotal
        /// Extended fields in the Details tab.
        case bpm, musicalKey, isrc, lyrics
        /// Sorting fields.
        case sortArtist, sortAlbumArtist, sortAlbum
        /// DB-only fields.
        case rating, loved, excludedFromShuffle
    }

    /// A field that may be shared (single value), mixed (various), or edited.
    public enum FieldState<T: Equatable>: Equatable {
        case shared(T?) // all selected tracks have this value
        case various // selected tracks have distinct values
        case edited(T?) // user changed it; applies to all
    }

    /// One row in the conflict diff sheet comparing a stored DB value to the on-disk value.
    public struct ConflictDiffRow: Identifiable, Sendable {
        public let id: String
        public let label: String
        public let stored: String
        public let disk: String

        public init(label: String, stored: String, disk: String) {
            self.id = label
            self.label = label
            self.stored = stored
            self.disk = disk
        }
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
    /// Fields the user has opted in to applying in multi-track edit mode.
    ///
    /// Editing a field automatically inserts its key here.  Unchecking a checkbox
    /// removes the key so the field is omitted from the patch on Save.
    /// In single-track mode this set is not consulted — all edits are always applied.
    @Published public var enabledFields: Set<FieldKey> = []

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
    /// `true` while a bulk action is executing (renumber, copy artist, etc.).
    @Published public internal(set) var isApplyingBulkAction = false
    /// Track IDs that need conflict resolution (disk was changed after user edit).
    @Published public internal(set) var conflictTrackIDs: Set<Int64> = []
    /// `true` when at least one loaded track has an unresolved disk-change conflict.
    public var hasConflict: Bool {
        !self.conflictTrackIDs.isEmpty
    }

    // MARK: - Dependencies

    let service: MetadataEditService
    let trackIDs: [Int64]
    let log = AppLogger.make(.ui)

    /// Number of tracks being edited.  Used by the Bulk Actions UI.
    public var trackCount: Int {
        self.trackIDs.count
    }

    // MARK: - Per-track cached data (populated after load())

    /// Tags loaded from disk, keyed by track ID.  Used by bulk operations.
    var loadedTagsByID: [Int64: TrackTags] = [:]
    /// DB track rows, keyed by track ID.  Used by cross-album renumber check.
    var loadedTracksByID: [Int64: Track] = [:]
    /// The single `Track` row loaded from the DB.  `nil` in multi-track mode or before `load()`.
    @Published public private(set) var singleTrack: Track?

    // MARK: - Init

    public init(service: MetadataEditService, trackIDs: [Int64]) {
        self.service = service
        self.trackIDs = trackIDs
        self.isSingleTrack = trackIDs.count == 1
    }

    // MARK: - Multi-edit field selection

    /// Marks every field as enabled so all edits will be applied on Save.
    public func enableAllFields() {
        self.enabledFields = Set(FieldKey.allCases)
    }

    /// Clears all field-enable flags so no edits will be applied on Save.
    public func disableAllFields() {
        self.enabledFields = []
    }

    // MARK: - Load

    /// Loads tags for all selected tracks and populates fields.
    public func load() async {
        guard !self.trackIDs.isEmpty else { return }
        self.enabledFields = []
        var allTags: [TrackTags] = []
        var tagsByID: [Int64: TrackTags] = [:]
        for id in self.trackIDs {
            if let tags = try? await self.service.readTags(trackID: id) {
                allTags.append(tags)
                tagsByID[id] = tags
            }
        }
        guard !allTags.isEmpty else { return }
        self.loadedTagsByID = tagsByID
        self.populate(from: allTags)
        // Populate DB-only fields (rating, loved, excludedFromShuffle) which are
        // not stored in audio file tags and therefore absent from TrackTags.
        let tracks = await (try? self.service.readTracks(ids: self.trackIDs)) ?? []
        var tracksByID: [Int64: Track] = [:]
        for track in tracks {
            if let id = track.id { tracksByID[id] = track }
        }
        self.loadedTracksByID = tracksByID
        self.singleTrack = self.isSingleTrack ? tracksByID[self.trackIDs[0]] : nil
        self.populateDBFields(from: tracks)
        // Detect unresolved disk-change conflicts.
        let conflicting = tracks.compactMap { $0.needsConflictReview ? $0.id : nil }
        self.conflictTrackIDs = Set(conflicting)
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
        if !self.isSingleTrack { self.enabledFields.insert(.title) }
    }

    /// Marks `artist` as edited with `value`.
    public func setArtist(_ value: String?) {
        self.artist = .edited(value?.nilIfEmpty)
        if !self.isSingleTrack { self.enabledFields.insert(.artist) }
    }

    /// Marks `albumArtist` as edited with `value`.
    public func setAlbumArtist(_ value: String?) {
        self.albumArtist = .edited(value?.nilIfEmpty)
        if !self.isSingleTrack { self.enabledFields.insert(.albumArtist) }
    }

    /// Marks `album` as edited with `value`.
    public func setAlbum(_ value: String?) {
        self.album = .edited(value?.nilIfEmpty)
        if !self.isSingleTrack { self.enabledFields.insert(.album) }
    }

    /// Marks `genre` as edited with `value`.
    public func setGenre(_ value: String?) {
        self.genre = .edited(value?.nilIfEmpty)
        if !self.isSingleTrack { self.enabledFields.insert(.genre) }
    }

    /// Marks `composer` as edited with `value`.
    public func setComposer(_ value: String?) {
        self.composer = .edited(value?.nilIfEmpty)
        if !self.isSingleTrack { self.enabledFields.insert(.composer) }
    }

    /// Marks `comment` as edited with `value`.
    public func setComment(_ value: String?) {
        self.comment = .edited(value?.nilIfEmpty)
        if !self.isSingleTrack { self.enabledFields.insert(.comment) }
    }

    /// Marks `year` as edited with `value`.
    public func setYear(_ value: Int?) {
        self.year = .edited(value)
        if !self.isSingleTrack { self.enabledFields.insert(.year) }
    }

    /// Marks `trackNumber` as edited with `value`.
    public func setTrackNumber(_ value: Int?) {
        self.trackNumber = .edited(value)
    }

    /// Marks `trackTotal` as edited with `value`.
    public func setTrackTotal(_ value: Int?) {
        self.trackTotal = .edited(value)
    }

    /// Marks `discNumber` as edited with `value`.
    public func setDiscNumber(_ value: Int?) {
        self.discNumber = .edited(value)
        if !self.isSingleTrack { self.enabledFields.insert(.discNumber) }
    }

    /// Marks `discTotal` as edited with `value`.
    public func setDiscTotal(_ value: Int?) {
        self.discTotal = .edited(value)
        if !self.isSingleTrack { self.enabledFields.insert(.discTotal) }
    }

    /// Marks `bpm` as edited with `value`.
    public func setBPM(_ value: Double?) {
        self.bpm = .edited(value)
        if !self.isSingleTrack { self.enabledFields.insert(.bpm) }
    }

    /// Marks `key` as edited with `value`.
    public func setKey(_ value: String?) {
        self.key = .edited(value?.nilIfEmpty)
        if !self.isSingleTrack { self.enabledFields.insert(.musicalKey) }
    }

    /// Marks `isrc` as edited with `value`.
    public func setISRC(_ value: String?) {
        self.isrc = .edited(value?.nilIfEmpty)
        if !self.isSingleTrack { self.enabledFields.insert(.isrc) }
    }

    /// Marks `lyrics` as edited with `value`.
    public func setLyrics(_ value: String?) {
        self.lyrics = .edited(value?.nilIfEmpty)
        if !self.isSingleTrack { self.enabledFields.insert(.lyrics) }
    }

    /// Marks `sortArtist` as edited with `value`.
    public func setSortArtist(_ value: String?) {
        self.sortArtist = .edited(value?.nilIfEmpty)
        if !self.isSingleTrack { self.enabledFields.insert(.sortArtist) }
    }

    /// Marks `sortAlbumArtist` as edited with `value`.
    public func setSortAlbumArtist(_ value: String?) {
        self.sortAlbumArtist = .edited(value?.nilIfEmpty)
        if !self.isSingleTrack { self.enabledFields.insert(.sortAlbumArtist) }
    }

    /// Marks `sortAlbum` as edited with `value`.
    public func setSortAlbum(_ value: String?) {
        self.sortAlbum = .edited(value?.nilIfEmpty)
        if !self.isSingleTrack { self.enabledFields.insert(.sortAlbum) }
    }

    /// Marks `rating` as edited with `value`.
    public func setRating(_ value: Int?) {
        self.rating = .edited(value)
        if !self.isSingleTrack { self.enabledFields.insert(.rating) }
    }

    /// Marks `loved` as edited with `value`.
    public func setLoved(_ value: Bool?) {
        self.loved = .edited(value)
        if !self.isSingleTrack { self.enabledFields.insert(.loved) }
    }

    /// Marks `excludedFromShuffle` as edited with `value`.
    public func setExcludedFromShuffle(_ value: Bool?) {
        self.excludedFromShuffle = .edited(value)
        if !self.isSingleTrack { self.enabledFields.insert(.excludedFromShuffle) }
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

    private func populateDBFields(from tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        self.rating = Self.fieldState(tracks.map { $0.rating == 0 ? nil : $0.rating })
        self.loved = Self.fieldState(tracks.map(\.loved))
        self.excludedFromShuffle = Self.fieldState(tracks.map(\.excludedFromShuffle))
    }

    private static func fieldState<T: Equatable>(_ values: [T?]) -> FieldState<T> {
        guard !values.isEmpty else { return .shared(nil) }
        let first = values[0]
        let allSame = values.dropFirst().allSatisfy { $0 == first }
        return allSame ? .shared(first) : .various
    }

    private func buildPatch() -> TrackTagPatch {
        var patch = TrackTagPatch()
        patch.title = self.patchValue(self.title, key: .title)
        patch.artist = self.patchValue(self.artist, key: .artist)
        patch.albumArtist = self.patchValue(self.albumArtist, key: .albumArtist)
        patch.album = self.patchValue(self.album, key: .album)
        patch.genre = self.patchValue(self.genre, key: .genre)
        patch.composer = self.patchValue(self.composer, key: .composer)
        patch.comment = self.patchValue(self.comment, key: .comment)
        patch.year = self.patchValue(self.year, key: .year)
        // trackNumber / trackTotal: single-track only (no FieldKey needed)
        if self.isSingleTrack {
            if case let .edited(val) = self.trackNumber { patch.trackNumber = val }
            if case let .edited(val) = self.trackTotal { patch.trackTotal = val }
        }
        patch.discNumber = self.patchValue(self.discNumber, key: .discNumber)
        patch.discTotal = self.patchValue(self.discTotal, key: .discTotal)
        patch.bpm = self.patchValue(self.bpm, key: .bpm)
        patch.key = self.patchValue(self.key, key: .musicalKey)
        patch.isrc = self.patchValue(self.isrc, key: .isrc)
        patch.lyrics = self.patchValue(self.lyrics, key: .lyrics)
        patch.sortArtist = self.patchValue(self.sortArtist, key: .sortArtist)
        patch.sortAlbumArtist = self.patchValue(self.sortAlbumArtist, key: .sortAlbumArtist)
        patch.sortAlbum = self.patchValue(self.sortAlbum, key: .sortAlbum)
        patch.rating = self.patchValue(self.rating, key: .rating)
        if case let .edited(val) = self.loved,
           self.isSingleTrack || self.enabledFields.contains(.loved) { patch.loved = val }
        if case let .edited(val) = self.excludedFromShuffle,
           self.isSingleTrack || self.enabledFields.contains(.excludedFromShuffle) {
            patch.excludedFromShuffle = val
        }
        if self.artworkCleared {
            patch.coverArt = .some(nil) // signals "remove art"
        } else if let artData = self.pendingArtData {
            patch.coverArt = artData
        }
        return patch
    }

    /// Converts an `.edited` field state into a `TrackTagPatch` double-optional.
    ///
    /// In multi-track mode the field must also be present in `enabledFields`;
    /// in single-track mode the check is skipped.
    private func patchValue<T>(_ state: FieldState<T>, key: FieldKey) -> T?? {
        guard self.isSingleTrack || self.enabledFields.contains(key) else { return nil }
        if case let .edited(val) = state { return val }
        return nil
    }
}

// MARK: - String extension

private extension String {
    var nilIfEmpty: String? {
        self.isEmpty ? nil : self
    }
}
