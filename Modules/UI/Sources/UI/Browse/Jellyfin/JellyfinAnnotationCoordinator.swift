import Foundation
import Jellyfin
import Observability

// MARK: - JellyfinAnnotationFailure

/// A favourite that the server never accepted, after every retry.
public struct JellyfinAnnotationFailure: Sendable, Equatable {
    public let serverID: UUID
    public let itemID: String
    public let reason: String

    public init(serverID: UUID, itemID: String, reason: String) {
        self.serverID = serverID
        self.itemID = itemID
        self.reason = reason
    }
}

// MARK: - JellyfinAnnotationDelivering

/// What the coordinator needs from the favourites queue. `JellyfinAnnotations`
/// conforms below; tests pass a stub. It mirrors `SubsonicAnnotationDelivering`
/// without ratings (ADR-097, D3).
public protocol JellyfinAnnotationDelivering: Sendable {
    /// Sets or clears the favourite, with the queue's retry and collapse rules.
    func setFavorite(serverID: UUID, itemID: String, isFavorite: Bool) async
    /// The failures, one per action that ran out of retries. One consumer.
    func annotationFailures() async -> AsyncStream<JellyfinAnnotationFailure>
}

extension JellyfinAnnotations: JellyfinAnnotationDelivering {
    public func setFavorite(serverID: UUID, itemID: String, isFavorite: Bool) async {
        if isFavorite {
            await self.star(serverID: serverID, itemID: itemID)
        } else {
            await self.unstar(serverID: serverID, itemID: itemID)
        }
    }

    public func annotationFailures() async -> AsyncStream<JellyfinAnnotationFailure> {
        let events = self.events
        return AsyncStream { continuation in
            let task = Task {
                for await event in events {
                    if case let .annotationFailed(serverID, itemID, reason) = event {
                        continuation.yield(JellyfinAnnotationFailure(serverID: serverID, itemID: itemID, reason: reason))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - JellyfinAnnotationObserving

/// A view model that owns Jellyfin song rows and rebuilds them when a
/// favourite override moves. The coordinator calls it directly, as the
/// Subsonic one does (#475): nothing else would re-render the rows.
@MainActor
public protocol JellyfinAnnotationObserving: AnyObject {
    /// Called after any change to the favourite overrides.
    func annotationOverridesDidChange()
}

// MARK: - JellyfinAnnotationCoordinator

/// Owns the optimistic favourite state for Jellyfin songs (ADR-097 slice 6), the
/// twin of `SubsonicAnnotationCoordinator`. A click sets the override at once,
/// the write goes through the favourites queue, and an `annotationFailed`
/// event puts the old value back.
///
/// Overrides are keyed by server and item, so two servers that share an item
/// id never share a star.
@MainActor
public final class JellyfinAnnotationCoordinator {
    private struct Key: Hashable {
        let serverID: UUID
        let itemID: String
    }

    private struct WeakObserver {
        weak var value: (any JellyfinAnnotationObserving)?
    }

    private var overrides: [Key: Bool] = [:] {
        didSet { self.notifyObservers() }
    }

    /// The value before the latest click, for the rollback.
    private var previous: [Key: Bool] = [:]
    private var observers: [WeakObserver] = []
    private let delivery: any JellyfinAnnotationDelivering
    private let log = AppLogger.make(.ui)
    private var listener: Task<Void, Never>?

    /// Creates the coordinator and starts listening for failed writes.
    public init(delivery: any JellyfinAnnotationDelivering) {
        self.delivery = delivery
        self.listener = Task { [weak self, delivery] in
            for await failure in await delivery.annotationFailures() {
                self?.handleFailure(failure)
            }
        }
    }

    deinit {
        self.listener?.cancel()
    }

    // MARK: Observers

    /// Registers a row-owning view model. Registering the same object twice is a no-op.
    public func addObserver(_ observer: any JellyfinAnnotationObserving) {
        self.observers.removeAll { $0.value == nil || $0.value === observer }
        self.observers.append(WeakObserver(value: observer))
    }

    private func notifyObservers() {
        self.observers.removeAll { $0.value == nil }
        for box in self.observers {
            box.value?.annotationOverridesDidChange()
        }
    }

    // MARK: Query

    /// The favourite flag to show: the override when there is one, else the server's.
    public func isStarred(serverID: UUID, itemID: String, serverValue: Bool) -> Bool {
        self.overrides[Key(serverID: serverID, itemID: itemID)] ?? serverValue
    }

    /// `song` with its favourite flag as the user last set it.
    public func applying(to song: JellyfinSong, serverID: UUID) -> JellyfinSong {
        guard let override = self.overrides[Key(serverID: serverID, itemID: song.id)],
              override != song.isStarred else { return song }
        var copy = song
        copy.isStarred = override
        return copy
    }

    // MARK: Mutation

    /// Flips the favourite with an optimistic update and sends the write.
    public func toggleStar(serverID: UUID, itemID: String, currentlyStarred: Bool) {
        Haptics.stateChange()
        let key = Key(serverID: serverID, itemID: itemID)
        let newValue = !currentlyStarred
        self.previous[key] = currentlyStarred
        self.overrides[key] = newValue
        Task { [delivery] in
            await delivery.setFavorite(serverID: serverID, itemID: itemID, isFavorite: newValue)
        }
    }

    // MARK: Failure

    private func handleFailure(_ failure: JellyfinAnnotationFailure) {
        self.log.warning("jellyfin.annotation.rollback", [
            "server": failure.serverID.uuidString, "item": failure.itemID, "reason": failure.reason,
        ])
        let key = Key(serverID: failure.serverID, itemID: failure.itemID)
        if let old = self.previous.removeValue(forKey: key) {
            self.overrides[key] = old
        }
    }
}
