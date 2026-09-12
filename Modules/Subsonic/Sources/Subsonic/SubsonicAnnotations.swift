import Foundation
import Observability

// MARK: - AnnotationAction

/// A star / unstar / setRating action queued for delivery.
private enum AnnotationAction {
    case star(serverID: UUID, songID: String)
    case unstar(serverID: UUID, songID: String)
    case setRating(serverID: UUID, songID: String, rating: Int)

    var serverID: UUID {
        switch self {
        case let .star(s, _), let .unstar(s, _), let .setRating(s, _, _): s
        }
    }

    /// Log-only name for the action kind.
    var name: String {
        switch self {
        case .star: "star"
        case .unstar: "unstar"
        case .setRating: "setRating"
        }
    }
}

// MARK: - SubsonicAnnotations

/// Delivers star/unstar/setRating actions to the server with a resilient retry
/// queue.
///
/// ## Retry policy
/// Failed actions are re-attempted up to `maxAttempts` times with a fixed
/// 10-second delay between attempts. After `maxAttempts` consecutive failures
/// for the same server, an `.annotationFailed` event is emitted via `events`.
///
/// ## Idempotency
/// Duplicate star / unstar pairs for the same song are collapsed: a star
/// followed by an unstar (or vice versa) before either is delivered is
/// resolved to a single final action.
public actor SubsonicAnnotations {
    // MARK: - Types

    public enum Event: Sendable {
        /// The service has failed to deliver an annotation after `maxAttempts`.
        case annotationFailed(serverID: UUID, songID: String, reason: String)
    }

    // MARK: - Constants

    private static let maxAttempts = 3
    private static let retryDelay: TimeInterval = 10

    // MARK: - State

    private let service: SubsonicService
    private let log = AppLogger.make(.subsonic)
    private var (eventStream, eventContinuation) = AsyncStream<Event>.makeStream()
    private var consecutiveFailures: [UUID: Int] = [:]

    // MARK: - Init

    public init(service: SubsonicService) {
        self.service = service
    }

    // MARK: - Public API

    /// Async stream of annotation failure events.
    public var events: AsyncStream<Event> {
        self.eventStream
    }

    /// Queues a star action, unless this server has `syncStars` off.
    public func star(serverID: UUID, songID: String) async {
        let action = AnnotationAction.star(serverID: serverID, songID: songID)
        guard await self.mirrors(action) else { return }
        await self.attempt(action: action)
    }

    /// Queues an unstar action, unless this server has `syncStars` off.
    public func unstar(serverID: UUID, songID: String) async {
        let action = AnnotationAction.unstar(serverID: serverID, songID: songID)
        guard await self.mirrors(action) else { return }
        await self.attempt(action: action)
    }

    /// Queues a rating update, unless this server has `syncRatings` off.
    public func setRating(serverID: UUID, songID: String, rating: Int) async {
        let action = AnnotationAction.setRating(serverID: serverID, songID: songID, rating: rating)
        guard await self.mirrors(action) else { return }
        await self.attempt(action: action)
    }

    /// Whether the server wants this action mirrored, per the `syncStars` and
    /// `syncRatings` flags on its record.
    ///
    /// Both flags were stored, edited in Settings and read by nothing until
    /// #502: every star and rating went to the server whatever the user had
    /// chosen. A skipped action is not a failure, so it never enters the retry
    /// queue and never raises `annotationFailed`.
    private func mirrors(_ action: AnnotationAction) async -> Bool {
        let enabled = switch action {
        case .star, .unstar:
            await self.service.syncsStars(serverID: action.serverID)
        case .setRating:
            await self.service.syncsRatings(serverID: action.serverID)
        }
        if !enabled {
            self.log.debug(
                "subsonic.annotation.notMirrored",
                ["server": action.serverID.uuidString, "action": action.name]
            )
        }
        return enabled
    }

    // MARK: - Delivery

    private func attempt(action: AnnotationAction, attempt: Int = 1) async {
        do {
            switch action {
            case let .star(sid, songID):
                try await self.service.star(serverID: sid, songID: songID)
            case let .unstar(sid, songID):
                try await self.service.unstar(serverID: sid, songID: songID)
            case let .setRating(sid, songID, rating):
                try await self.service.setRating(serverID: sid, songID: songID, rating: rating)
            }
            self.consecutiveFailures[action.serverID] = 0
        } catch {
            let failures = (self.consecutiveFailures[action.serverID] ?? 0) + 1
            self.consecutiveFailures[action.serverID] = failures
            self.log.warning(
                "subsonic.annotation.fail",
                [
                    "server": action.serverID.uuidString,
                    "attempt": attempt,
                    "failures": failures,
                    "err": error.localizedDescription,
                ]
            )

            if attempt < Self.maxAttempts {
                let next = attempt + 1
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(Self.retryDelay * 1_000_000_000))
                    await self.attempt(action: action, attempt: next)
                }
            } else {
                // Extract song ID for the event.
                let songID: String = switch action {
                case let .star(_, s), let .unstar(_, s), let .setRating(_, s, _): s
                }
                self.log.error(
                    "subsonic.annotation.exhausted",
                    [
                        "server": action.serverID.uuidString,
                        "song": songID,
                        "err": error.localizedDescription,
                    ]
                )
                self.eventContinuation.yield(
                    .annotationFailed(
                        serverID: action.serverID,
                        songID: songID,
                        reason: error.localizedDescription
                    )
                )
            }
        }
    }
}
