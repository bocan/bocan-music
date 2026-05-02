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
/// values they want to accept.
public enum IdentifyTagField: String, CaseIterable, Hashable, Sendable {
    case title
    case artist
    case albumArtist
    case album
    case genre
    case trackNumber
    case discNumber
    case year

    public var displayName: String {
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

        case .trackNumber:
            "Track No."

        case .discNumber:
            "Disc No."

        case .year:
            "Year"
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

    public init(
        title: String? = nil,
        artist: String? = nil,
        albumArtist: String? = nil,
        album: String? = nil,
        genre: String? = nil,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        year: Int? = nil
    ) {
        self.title = title
        self.artist = artist
        self.albumArtist = albumArtist
        self.album = album
        self.genre = genre
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.year = year
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
    public func apply(_ candidate: IdentificationCandidate, fields: Set<IdentifyTagField>) async {
        guard !fields.isEmpty else { return }

        let patch = Self.buildPatch(candidate: candidate, fields: fields)
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

    private static func buildPatch(
        candidate: IdentificationCandidate,
        fields: Set<IdentifyTagField>
    ) -> TrackTagPatch {
        var patch = TrackTagPatch()
        if fields.contains(.title) { patch.title = .some(candidate.title) }
        if fields.contains(.artist) { patch.artist = .some(candidate.artist) }
        if fields.contains(.albumArtist), let value = candidate.albumArtist {
            patch.albumArtist = .some(value)
        }
        if fields.contains(.album), let value = candidate.album { patch.album = .some(value) }
        if fields.contains(.genre), let value = candidate.genre { patch.genre = .some(value) }
        if fields.contains(.trackNumber), let value = candidate.trackNumber {
            patch.trackNumber = .some(value)
        }
        if fields.contains(.discNumber), let value = candidate.discNumber {
            patch.discNumber = .some(value)
        }
        if fields.contains(.year), let value = candidate.year { patch.year = .some(value) }
        return patch
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
            year: self.track.year
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
