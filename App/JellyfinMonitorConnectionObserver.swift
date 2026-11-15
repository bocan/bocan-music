import Foundation
import Jellyfin
import UI

// MARK: - JellyfinMonitorConnectionObserver

/// App-layer adapter that bridges `JellyfinConnectionMonitor` to the UI module's
/// `JellyfinConnectionObserving`. It maps `JellyfinConnectionStatus` to the UI's
/// existing `SubsonicSidebarConnectionState` and forwards "Retry now" to the
/// monitor. It mirrors `SubsonicMonitorConnectionObserver`.
struct JellyfinMonitorConnectionObserver: JellyfinConnectionObserving {
    let monitor: JellyfinConnectionMonitor

    func currentStates() async -> [UUID: SubsonicSidebarConnectionState] {
        let raw = await self.monitor.currentStatuses()
        return raw.mapValues(Self.map)
    }

    func stateUpdates() -> AsyncStream<(UUID, SubsonicSidebarConnectionState)> {
        AsyncStream { continuation in
            let task = Task {
                for await update in await self.monitor.updates {
                    continuation.yield((update.serverID, Self.map(update.status)))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func retry(serverID: UUID) async {
        // Stopping and starting skips the back-off sleep for this one server. A
        // server stopped by a 401 starts again too, and its first ping decides
        // whether the token still fails.
        await self.monitor.stopMonitoring(serverID: serverID)
        await self.monitor.startMonitoring(serverID: serverID)
    }

    private static func map(_ status: JellyfinConnectionStatus) -> SubsonicSidebarConnectionState {
        switch status {
        case .unknown:
            .unknown

        case .connecting:
            .connecting

        case .online:
            .online

        case let .authFailed(message):
            .authFailed(message)

        case let .unreachable(message):
            .unreachable(message)

        case let .serverError(message):
            .serverError(message)
        }
    }
}
