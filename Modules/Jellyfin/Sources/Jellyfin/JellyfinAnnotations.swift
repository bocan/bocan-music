import Foundation
import Observability

// MARK: - JellyfinAnnotations

/// Delivers favourite and unfavourite actions to the server with a resilient
/// retry queue. It mirrors `SubsonicAnnotations`, without ratings (ADR-097, D3).
///
/// ## Retry policy
/// A failed action is tried again up to `maxAttempts` times with a fixed delay
/// between attempts (10 s). After the last failure an `.annotationFailed`
/// event is emitted on `events`.
///
/// ## Collapsing
/// Only the last action for an item counts. A favourite followed by an
/// unfavourite before either is delivered leaves one action, the last, and a
/// retry that has been overtaken by a newer action is dropped. The Subsonic
/// queue documents this but does not enforce it for a retry already waiting.
public actor JellyfinAnnotations {
    // MARK: - Types

    public enum Event: Sendable {
        /// The service failed to deliver an action after the last attempt.
        case annotationFailed(serverID: UUID, itemID: String, reason: String)
    }

    private struct Key: Hashable {
        let serverID: UUID
        let itemID: String
    }

    // MARK: - Constants

    static let maxAttempts = 3
    static let defaultRetryDelay: Duration = .seconds(10)

    // MARK: - State

    private let service: JellyfinService
    private let retryDelay: Duration
    private let log = AppLogger.make(.jellyfin)
    private var (eventStream, eventContinuation) = AsyncStream<Event>.makeStream()
    /// The state the user last asked for, per item. Absent once delivered or abandoned.
    private var wanted: [Key: Bool] = [:]
    private var consecutiveFailures: [UUID: Int] = [:]

    // MARK: - Init

    /// Creates a queue that delivers through `service`, which also supplies each
    /// server's `syncStars` flag.
    public init(service: JellyfinService) {
        self.init(service: service, retryDelay: Self.defaultRetryDelay)
    }

    init(service: JellyfinService, retryDelay: Duration) {
        self.service = service
        self.retryDelay = retryDelay
    }

    // MARK: - Public API

    /// Async stream of delivery failures.
    public var events: AsyncStream<Event> {
        self.eventStream
    }

    /// Marks the item a favourite, unless this server has `syncStars` off.
    public func star(serverID: UUID, itemID: String) async {
        await self.submit(serverID: serverID, itemID: itemID, isFavorite: true)
    }

    /// Removes the favourite mark, unless this server has `syncStars` off.
    public func unstar(serverID: UUID, itemID: String) async {
        await self.submit(serverID: serverID, itemID: itemID, isFavorite: false)
    }

    // MARK: - Delivery

    /// A skipped action is not a failure: it never enters the retry queue and
    /// never raises `annotationFailed`.
    private func submit(serverID: UUID, itemID: String, isFavorite: Bool) async {
        guard await self.service.syncsStars(serverID: serverID) else {
            self.log.debug(
                "jellyfin.annotation.notMirrored",
                ["server": serverID.uuidString, "action": isFavorite ? "star" : "unstar"]
            )
            return
        }
        let key = Key(serverID: serverID, itemID: itemID)
        self.wanted[key] = isFavorite
        await self.attempt(key: key, isFavorite: isFavorite, attempt: 1)
    }

    private func attempt(key: Key, isFavorite: Bool, attempt: Int) async {
        // A newer action for this item has replaced this one.
        guard self.wanted[key] == isFavorite else { return }
        do {
            try await self.service.setFavorite(serverID: key.serverID, itemID: key.itemID, isFavorite: isFavorite)
            self.consecutiveFailures[key.serverID] = 0
            if self.wanted[key] == isFavorite {
                self.wanted[key] = nil
            }
        } catch {
            let failures = (self.consecutiveFailures[key.serverID] ?? 0) + 1
            self.consecutiveFailures[key.serverID] = failures
            self.log.warning(
                "jellyfin.annotation.fail",
                [
                    "server": key.serverID.uuidString,
                    "attempt": attempt,
                    "failures": failures,
                    "err": error.localizedDescription,
                ]
            )
            if attempt < Self.maxAttempts {
                self.scheduleRetry(key: key, isFavorite: isFavorite, next: attempt + 1)
            } else {
                self.log.error(
                    "jellyfin.annotation.exhausted",
                    ["server": key.serverID.uuidString, "item": key.itemID, "err": error.localizedDescription]
                )
                if self.wanted[key] == isFavorite {
                    self.wanted[key] = nil
                }
                self.eventContinuation.yield(
                    .annotationFailed(serverID: key.serverID, itemID: key.itemID, reason: error.localizedDescription)
                )
            }
        }
    }

    private func scheduleRetry(key: Key, isFavorite: Bool, next: Int) {
        let delay = self.retryDelay
        Task {
            do {
                try await Task.sleep(for: delay)
            } catch {
                return // cancelled
            }
            await self.attempt(key: key, isFavorite: isFavorite, attempt: next)
        }
    }
}
