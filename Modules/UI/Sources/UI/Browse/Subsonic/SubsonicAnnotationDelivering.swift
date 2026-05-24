import Foundation
import Subsonic

// MARK: - SubsonicAnnotationFailure

/// A normalized failure event suitable for UI rollback.
public struct SubsonicAnnotationFailure: Sendable, Equatable {
    public let serverID: UUID
    public let songID: String
    public let reason: String

    public init(serverID: UUID, songID: String, reason: String) {
        self.serverID = serverID
        self.songID = songID
        self.reason = reason
    }
}

// MARK: - SubsonicAnnotationDelivering

/// Narrow protocol the Phase 19 step 14 annotation coordinator depends on.
/// Lets tests substitute a deterministic in-memory stub for the real
/// `SubsonicAnnotations` actor.
public protocol SubsonicAnnotationDelivering: Sendable {
    func star(serverID: UUID, songID: String) async
    func unstar(serverID: UUID, songID: String) async
    func setRating(serverID: UUID, songID: String, rating: Int) async
    func annotationFailures() -> AsyncStream<SubsonicAnnotationFailure>
}

// MARK: - SubsonicAnnotations conformance

extension SubsonicAnnotations: SubsonicAnnotationDelivering {
    public nonisolated func annotationFailures() -> AsyncStream<SubsonicAnnotationFailure> {
        AsyncStream { continuation in
            let task = Task {
                for await event in await self.events {
                    switch event {
                    case let .annotationFailed(serverID, songID, reason):
                        continuation.yield(
                            SubsonicAnnotationFailure(
                                serverID: serverID,
                                songID: songID,
                                reason: reason
                            )
                        )
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
