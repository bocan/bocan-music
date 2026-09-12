import Foundation
import Observability
import SwiftSonic
import SwiftUI

// MARK: - SubsonicAnnotationObserving

/// A view model that owns a stored `SubsonicSongTableRow` array derived from
/// the coordinator's overrides, and rebuilds it when one of them moves.
///
/// The coordinator reaches its observers directly because nothing else would:
/// it is handed to the browse views through the SwiftUI environment, which
/// does not subscribe to `objectWillChange`, so a star or rating change on its
/// own re-renders no view (#475).
@MainActor
public protocol SubsonicAnnotationObserving: AnyObject {
    /// Called after any write to the star or rating overrides.
    func annotationOverridesDidChange()
}

// MARK: - SubsonicAnnotationCoordinator

/// Owns the optimistic UI state for star and rating actions on Subsonic
/// songs. Updates `@Published` overrides synchronously when the user taps,
/// dispatches the write through `SubsonicAnnotationDelivering`, and rolls
/// back the override if the retry queue surfaces an `annotationFailed`
/// event for the same song.
@MainActor
public final class SubsonicAnnotationCoordinator: ObservableObject {
    // MARK: - Published state

    /// Per-song optimistic starred override. `true` ⇒ starred,
    /// `false` ⇒ unstarred. Absence means "fall back to server value".
    @Published public private(set) var starOverrides: [String: Bool] = [:] {
        didSet { self.notifyObservers() }
    }

    /// Per-song optimistic rating override (0–5). Absence means
    /// "fall back to server value".
    @Published public private(set) var ratingOverrides: [String: Int] = [:] {
        didSet { self.notifyObservers() }
    }

    // MARK: - Row observers

    /// Weakly-held box, so a destination's view model deregisters itself by
    /// going away with its view and no teardown call is needed.
    private struct WeakObserver {
        weak var value: (any SubsonicAnnotationObserving)?
    }

    private var observers: [WeakObserver] = []

    /// Registers a row-owning view model for override changes (#475).
    /// Registering the same object twice is a no-op.
    public func addObserver(_ observer: any SubsonicAnnotationObserving) {
        self.observers.removeAll { $0.value == nil || $0.value === observer }
        self.observers.append(WeakObserver(value: observer))
    }

    private func notifyObservers() {
        self.observers.removeAll { $0.value == nil }
        for box in self.observers {
            box.value?.annotationOverridesDidChange()
        }
    }

    // MARK: - Internals

    private let delivery: any SubsonicAnnotationDelivering
    private let log = AppLogger.make(.ui)
    /// Snapshot of the value before the most recent optimistic change, used
    /// for rollback when the delivery actor reports failure.
    private var previousStar: [String: Bool] = [:]
    private var previousRating: [String: Int?] = [:]
    private var listener: Task<Void, Never>?

    // MARK: - Init

    public init(delivery: any SubsonicAnnotationDelivering) {
        self.delivery = delivery
        self.listener = Task { [weak self] in
            guard let stream = self?.delivery.annotationFailures() else { return }
            for await failure in stream {
                self?.handleFailure(failure)
            }
        }
    }

    deinit {
        self.listener?.cancel()
    }

    // MARK: - Query

    /// Effective starred state for a song — optimistic override if present,
    /// otherwise the server-provided `starred` timestamp.
    public func isStarred(songID: String, serverStarred: Date?) -> Bool {
        if let override = self.starOverrides[songID] {
            return override
        }
        return serverStarred != nil
    }

    /// Effective rating for a song (0–5) — optimistic override if present,
    /// otherwise the server-provided rating.
    public func rating(songID: String, serverRating: Int?) -> Int {
        if let override = self.ratingOverrides[songID] {
            return override
        }
        return serverRating ?? 0
    }

    // MARK: - Mutation

    /// Toggles the star state for a song with optimistic update.
    public func toggleStar(songID: String, serverID: UUID, currentlyStarred: Bool) {
        Haptics.stateChange()
        let newValue = !currentlyStarred
        self.previousStar[songID] = currentlyStarred
        self.starOverrides[songID] = newValue
        Task { [delivery] in
            if newValue {
                await delivery.star(serverID: serverID, songID: songID)
            } else {
                await delivery.unstar(serverID: serverID, songID: songID)
            }
        }
    }

    /// Sets a rating (0–5) with optimistic update.
    public func setRating(
        songID: String,
        serverID: UUID,
        newRating: Int,
        previousRating: Int?
    ) {
        Haptics.stateChange()
        let clamped = max(0, min(5, newRating))
        self.previousRating[songID] = previousRating
        self.ratingOverrides[songID] = clamped
        Task { [delivery] in
            await delivery.setRating(serverID: serverID, songID: songID, rating: clamped)
        }
    }

    /// Drops any pending optimistic state for a song, e.g. after a reload.
    public func reset(songID: String) {
        self.starOverrides.removeValue(forKey: songID)
        self.ratingOverrides.removeValue(forKey: songID)
        self.previousStar.removeValue(forKey: songID)
        self.previousRating.removeValue(forKey: songID)
    }

    // MARK: - Failure handling

    private func handleFailure(_ failure: SubsonicAnnotationFailure) {
        self.log.warning(
            "subsonic.annotation.rollback",
            ["server": failure.serverID.uuidString, "song": failure.songID, "reason": failure.reason]
        )
        if let prev = self.previousStar.removeValue(forKey: failure.songID) {
            self.starOverrides[failure.songID] = prev
        }
        if let prev = self.previousRating.removeValue(forKey: failure.songID) {
            if let r = prev {
                self.ratingOverrides[failure.songID] = r
            } else {
                self.ratingOverrides.removeValue(forKey: failure.songID)
            }
        }
    }
}

/// SwiftUI environment plumbing for `SubsonicAnnotationCoordinator`.
public extension EnvironmentValues {
    /// Coordinator that owns optimistic star / rating updates for the
    /// currently visible Subsonic browse screen, if any.
    @Entry var subsonicAnnotationCoordinator: SubsonicAnnotationCoordinator?
}
