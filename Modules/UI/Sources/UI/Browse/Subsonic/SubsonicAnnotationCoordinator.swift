import Foundation
import Observability
import SwiftSonic
import SwiftUI

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
    @Published public private(set) var starOverrides: [String: Bool] = [:]

    /// Per-song optimistic rating override (0–5). Absence means
    /// "fall back to server value".
    @Published public private(set) var ratingOverrides: [String: Int] = [:]

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
                await self?.handleFailure(failure)
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
        if let override = self.starOverrides[songID] { return override }
        return serverStarred != nil
    }

    /// Effective rating for a song (0–5) — optimistic override if present,
    /// otherwise the server-provided rating.
    public func rating(songID: String, serverRating: Int?) -> Int {
        if let override = self.ratingOverrides[songID] { return override }
        return serverRating ?? 0
    }

    // MARK: - Mutation

    /// Toggles the star state for a song with optimistic update.
    public func toggleStar(songID: String, serverID: UUID, currentlyStarred: Bool) {
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

public extension EnvironmentValues {
    @Entry var subsonicAnnotationCoordinator: SubsonicAnnotationCoordinator?
}
