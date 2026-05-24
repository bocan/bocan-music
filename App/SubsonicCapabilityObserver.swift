import Foundation
import Subsonic
import UI

// MARK: - SubsonicCapabilityObserver

/// App-layer adapter bridging `SubsonicService.capabilityUpdates` to the UI
/// module's `SubsonicCapabilityChangeObserving` protocol (Phase 19 step 16).
///
/// The Subsonic module isn't a dependency of UI, so this thin adapter is the
/// glue point: it exposes the actor-owned `AsyncStream<UUID>` to consumers
/// that only know the UI-level protocol.
struct SubsonicCapabilityObserver: SubsonicCapabilityChangeObserving {
    let service: SubsonicService

    func capabilityChanges() -> AsyncStream<UUID> {
        AsyncStream { continuation in
            let task = Task {
                for await id in await self.service.capabilityUpdates {
                    continuation.yield(id)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
