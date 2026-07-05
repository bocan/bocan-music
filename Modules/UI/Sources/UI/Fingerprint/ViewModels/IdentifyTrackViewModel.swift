import Acoustics
import Library
import Observability
import Persistence
import SwiftUI

// MARK: - IdentifyTagField

/// One of the tag fields that an AcoustID candidate can offer to write.
///
/// Used to drive per-field opt-in selection in `CandidatePickerView`: the
/// confirmation sheet shows one row per field and the user ticks only the
/// values they want to accept. `allCases` order is the grid's display order.
public enum IdentifyTagField: String, CaseIterable, Hashable, Sendable {
    case title
    case artist
    case albumArtist
    case album
    case genre
    case trackNumber
    case discNumber
    case year
    case trackTotal
    case discTotal
    case isrc
    case mbRecordingID
    case mbReleaseID
    case mbReleaseGroupID
    case mbAlbumArtistID

    /// Which grid tier the field renders in: `.primary` is always visible,
    /// `.advanced` sits behind the "Show advanced fields" disclosure.
    public enum Tier: Sendable {
        case primary
        case advanced
    }

    public var tier: Tier {
        switch self {
        case .title, .artist, .albumArtist, .album, .genre, .trackNumber, .discNumber, .year:
            .primary

        case .trackTotal, .discTotal, .isrc, .mbRecordingID, .mbReleaseID,
             .mbReleaseGroupID, .mbAlbumArtistID:
            .advanced
        }
    }

    /// `true` for identifier-shaped values (UUIDs, ISRCs) that render in a
    /// monospaced middle-truncating style so their distinguishing tails survive.
    public var isIdentifierValue: Bool {
        switch self {
        case .isrc, .mbRecordingID, .mbReleaseID, .mbReleaseGroupID, .mbAlbumArtistID:
            true

        default:
            false
        }
    }

    public var displayName: String {
        switch self {
        case .title:
            L10n.string("Title")

        case .artist:
            L10n.string("Artist")

        case .albumArtist:
            L10n.string("Album Artist")

        case .album:
            L10n.string("Album")

        case .genre:
            L10n.string("Genre")

        case .trackNumber:
            L10n.string("Track No.")

        case .discNumber:
            L10n.string("Disc No.")

        case .year:
            L10n.string("Year")

        case .trackTotal:
            L10n.string("Track Total")

        case .discTotal:
            L10n.string("Disc Total")

        case .isrc:
            L10n.string("ISRC")

        case .mbRecordingID:
            L10n.string("Recording MBID")

        case .mbReleaseID:
            L10n.string("Release MBID")

        case .mbReleaseGroupID:
            L10n.string("Group MBID")

        case .mbAlbumArtistID:
            L10n.string("Artist MBID")
        }
    }
}

// MARK: - CurrentTagValues

/// Snapshot of a track's current human-readable tag values, used to render
/// the "current → proposed" diff in the identify sheet.
public struct CurrentTagValues: Sendable, Equatable {
    public var title: String?
    public var artist: String?
    public var albumArtist: String?
    public var album: String?
    public var genre: String?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var year: Int?
    public var trackTotal: Int?
    public var discTotal: Int?
    public var isrc: String?
    public var mbRecordingID: String?
    public var mbReleaseID: String?
    public var mbReleaseGroupID: String?
    public var mbAlbumArtistID: String?

    public init(
        title: String? = nil,
        artist: String? = nil,
        albumArtist: String? = nil,
        album: String? = nil,
        genre: String? = nil,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        year: Int? = nil,
        trackTotal: Int? = nil,
        discTotal: Int? = nil,
        isrc: String? = nil,
        mbRecordingID: String? = nil,
        mbReleaseID: String? = nil,
        mbReleaseGroupID: String? = nil,
        mbAlbumArtistID: String? = nil
    ) {
        self.title = title
        self.artist = artist
        self.albumArtist = albumArtist
        self.album = album
        self.genre = genre
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.year = year
        self.trackTotal = trackTotal
        self.discTotal = discTotal
        self.isrc = isrc
        self.mbRecordingID = mbRecordingID
        self.mbReleaseID = mbReleaseID
        self.mbReleaseGroupID = mbReleaseGroupID
        self.mbAlbumArtistID = mbAlbumArtistID
    }
}

// MARK: - IdentifyTrackViewModel

/// View-model for `IdentifyTrackSheet`.
///
/// Drives the identification pipeline state machine:
/// idle → fingerprinting → lookingUp → results | noMatch | error
@MainActor
public final class IdentifyTrackViewModel: ObservableObject, Identifiable {
    // MARK: - State

    public enum Phase {
        case fingerprinting
        case lookingUp
        case results([IdentificationCandidate])
        case noMatch
        case error(String)
    }

    @Published public private(set) var phase: Phase = .fingerprinting
    @Published public private(set) var didApply = false
    /// Set to `true` when the user taps "Edit Tags" from the no-match state.
    /// `RootView` observes this on `.onDisappear` and opens the tag editor.
    @Published public private(set) var openTagEditorAfterDismiss = false
    @Published public private(set) var currentValues = CurrentTagValues()

    // MARK: - Identifiable

    public let id: Int64

    // MARK: - Dependencies

    private let track: Track
    private let queue: FingerprintQueue
    private let editService: MetadataEditService
    private let artistRepo: ArtistRepository?
    private let albumRepo: AlbumRepository?
    private let log = AppLogger.make(.ui)

    // MARK: - In-flight task

    private var identifyTask: Task<Void, Never>?

    // MARK: - Init

    public init(
        track: Track,
        queue: FingerprintQueue,
        editService: MetadataEditService,
        artistRepo: ArtistRepository? = nil,
        albumRepo: AlbumRepository? = nil
    ) {
        self.id = track.id ?? 0
        self.track = track
        self.queue = queue
        self.editService = editService
        self.artistRepo = artistRepo
        self.albumRepo = albumRepo
    }

    // MARK: - Public API

    /// Starts the fingerprinting + lookup pipeline. Cancellable via `cancel()`.
    public func start() {
        self.identifyTask = Task {
            self.phase = .fingerprinting
            do {
                // Short yield so the UI renders the fingerprinting state first.
                try await Task.sleep(for: .milliseconds(50))
                try Task.checkCancellation()

                await self.loadCurrentValues()

                self.phase = .lookingUp
                let candidates = try await self.queue.identify(track: self.track)

                if candidates.isEmpty {
                    self.phase = .noMatch
                } else {
                    self.phase = .results(candidates)
                }
            } catch is CancellationError {
                // Sheet dismissed — silently stop.
            } catch let error as AcousticsError {
                self.phase = .error(error.localizedDescription)
                self.log.error("identify.failed", ["error": String(reflecting: error)])
            } catch {
                self.phase = .error(error.localizedDescription)
                self.log.error("identify.failed", ["error": String(reflecting: error)])
            }
        }
    }

    /// Cancels any in-flight identify task.
    public func cancel() {
        self.identifyTask?.cancel()
        self.identifyTask = nil
    }

    /// Called by the "Edit Tags" button in the no-match view.
    /// Signals `RootView` to open the tag editor once this sheet dismisses.
    public func requestTagEditor() {
        self.openTagEditorAfterDismiss = true
        self.cancel()
    }

    /// Applies the user-selected `fields` of `candidate` to the track's file
    /// via `MetadataEditService`. Fields not present in `fields` are left
    /// untouched on disk and in the database.
    ///
    /// Release-scoped values (album, year, track/disc numbers, totals, release
    /// and release-group MBIDs) come from `release` — the option chosen in the
    /// picker — falling back to the candidate's top-level fields (which mirror
    /// the best-ranked release) when `release` is nil.
    public func apply(
        _ candidate: IdentificationCandidate,
        fields: Set<IdentifyTagField>,
        release: ReleaseOption? = nil
    ) async {
        guard !fields.isEmpty else { return }

        let patch = Self.buildPatch(candidate: candidate, release: release, fields: fields)
        guard !patch.isEmpty, let trackID = self.track.id else { return }
        do {
            try await self.editService.edit(trackID: trackID, patch: patch)
            self.didApply = true
            self.log.info(
                "identify.applied",
                ["trackID": trackID, "score": candidate.score, "fields": fields.count]
            )
        } catch {
            self.phase = .error("Could not write tags: \(error.localizedDescription)")
            self.log.error("identify.apply.failed", ["error": String(reflecting: error)])
        }
    }

    static func buildPatch(
        candidate: IdentificationCandidate,
        release: ReleaseOption?,
        fields: Set<IdentifyTagField>
    ) -> TrackTagPatch {
        var patch = TrackTagPatch()
        Self.applyPrimaryFields(&patch, candidate: candidate, release: release, fields: fields)
        Self.applyIdentifierFields(&patch, candidate: candidate, release: release, fields: fields)
        return patch
    }

    private static func applyPrimaryFields(
        _ patch: inout TrackTagPatch,
        candidate: IdentificationCandidate,
        release: ReleaseOption?,
        fields: Set<IdentifyTagField>
    ) {
        // Fall back to the candidate's top-level fields when no release is
        // chosen; when one is, every release-scoped value follows it.
        let album = release?.title ?? candidate.album
        let albumArtist = release?.albumArtist ?? candidate.albumArtist
        let trackNumber = release == nil ? candidate.trackNumber : release?.trackNumber
        let discNumber = release == nil ? candidate.discNumber : release?.discNumber
        let year = release == nil ? candidate.year : release?.year

        if fields.contains(.title) { patch.title = .some(candidate.title) }
        if fields.contains(.artist) { patch.artist = .some(candidate.artist) }
        if fields.contains(.albumArtist), let value = albumArtist {
            patch.albumArtist = .some(value)
        }
        if fields.contains(.album), let value = album { patch.album = .some(value) }
        if fields.contains(.genre), let value = candidate.genre { patch.genre = .some(value) }
        if fields.contains(.trackNumber), let value = trackNumber {
            patch.trackNumber = .some(value)
        }
        if fields.contains(.discNumber), let value = discNumber {
            patch.discNumber = .some(value)
        }
        if fields.contains(.year), let value = year { patch.year = .some(value) }
    }

    private static func applyIdentifierFields(
        _ patch: inout TrackTagPatch,
        candidate: IdentificationCandidate,
        release: ReleaseOption?,
        fields: Set<IdentifyTagField>
    ) {
        if fields.contains(.trackTotal), let value = release?.trackTotal {
            patch.trackTotal = .some(value)
        }
        if fields.contains(.discTotal), let value = release?.discTotal {
            patch.discTotal = .some(value)
        }
        if fields.contains(.isrc), let value = candidate.isrcs.first {
            patch.isrc = .some(value)
        }
        if fields.contains(.mbRecordingID), let value = candidate.mbRecordingID {
            patch.musicbrainzRecordingID = .some(value)
        }
        if fields.contains(.mbReleaseID), let value = release?.id {
            patch.musicbrainzReleaseID = .some(value)
        }
        if fields.contains(.mbReleaseGroupID), let value = release?.releaseGroupID {
            patch.musicbrainzReleaseGroupID = .some(value)
        }
        if fields.contains(.mbAlbumArtistID), let value = release?.albumArtistMBID {
            patch.musicbrainzAlbumArtistID = .some(value)
        }
    }

    /// Retries the identification pipeline from the beginning.
    public func retry() {
        self.cancel()
        self.start()
    }

    // MARK: - Private

    private func loadCurrentValues() async {
        var snapshot = CurrentTagValues(
            title: self.track.title,
            genre: self.track.genre,
            trackNumber: self.track.trackNumber,
            discNumber: self.track.discNumber,
            year: self.track.year,
            trackTotal: self.track.trackTotal,
            discTotal: self.track.discTotal,
            isrc: self.track.isrc,
            mbRecordingID: self.track.musicbrainzRecordingID,
            mbReleaseID: self.track.musicbrainzReleaseID,
            mbReleaseGroupID: self.track.musicbrainzReleaseGroupID,
            mbAlbumArtistID: self.track.musicbrainzAlbumArtistID
        )

        if let artistRepo = self.artistRepo {
            if let artistID = self.track.artistID {
                snapshot.artist = try? await artistRepo.fetch(id: artistID).name
            }
            if let albumArtistID = self.track.albumArtistID {
                snapshot.albumArtist = try? await artistRepo.fetch(id: albumArtistID).name
            }
        }
        if let albumRepo = self.albumRepo, let albumID = self.track.albumID {
            snapshot.album = try? await albumRepo.fetch(id: albumID).title
        }

        self.currentValues = snapshot
    }

    // MARK: - Testing support

    /// Bypasses the async pipeline to set the display phase directly.
    /// Only intended for snapshot and unit tests; not part of the public API.
    func overridePhase(_ newPhase: Phase) {
        self.phase = newPhase
    }
}
