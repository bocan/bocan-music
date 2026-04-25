import Acoustics
import Library
import Observability
import Persistence
import SwiftUI

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

    // MARK: - Identifiable

    public let id: Int64

    // MARK: - Dependencies

    private let track: Track
    private let queue: FingerprintQueue
    private let editService: MetadataEditService
    private let log = AppLogger.make(.ui)

    // MARK: - In-flight task

    private var identifyTask: Task<Void, Never>?

    // MARK: - Init

    public init(track: Track, queue: FingerprintQueue, editService: MetadataEditService) {
        self.id = track.id ?? 0
        self.track = track
        self.queue = queue
        self.editService = editService
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

    /// Applies `candidate` to the track's file via `MetadataEditService`.
    public func apply(_ candidate: IdentificationCandidate) async {
        let patch = TrackTagPatch(
            title: .some(candidate.title),
            artist: .some(candidate.artist),
            albumArtist: candidate.albumArtist.map { .some($0) },
            album: candidate.album.map { .some($0) },
            genre: candidate.genre.map { .some($0) },
            trackNumber: candidate.trackNumber.map { .some($0) },
            discNumber: candidate.discNumber.map { .some($0) },
            year: candidate.year.map { .some($0) }
        )
        guard let trackID = self.track.id else { return }
        do {
            try await self.editService.edit(trackID: trackID, patch: patch)
            self.didApply = true
            self.log.info("identify.applied", ["trackID": trackID, "score": candidate.score])
        } catch {
            self.phase = .error("Could not write tags: \(error.localizedDescription)")
            self.log.error("identify.apply.failed", ["error": String(reflecting: error)])
        }
    }

    /// Retries the identification pipeline from the beginning.
    public func retry() {
        self.cancel()
        self.start()
    }
}
