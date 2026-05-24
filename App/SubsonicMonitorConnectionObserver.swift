import Foundation
import Subsonic
import UI

// MARK: - SubsonicMonitorConnectionObserver

/// Phase 19 step 17: App-layer adapter that bridges
/// `SubsonicConnectionMonitor` (Subsonic module) to the UI module's
/// `SubsonicConnectionObserving` protocol. Maps `SubsonicConnectionStatus`
/// → `SubsonicSidebarConnectionState` and forwards "Retry now" clicks to
/// the monitor's wake/restart entry-points.
struct SubsonicMonitorConnectionObserver: SubsonicConnectionObserving {
    let monitor: SubsonicConnectionMonitor

    func currentStates() async -> [UUID: SubsonicSidebarConnectionState] {
        let raw = await self.monitor.currentStatuses()
        var out: [UUID: SubsonicSidebarConnectionState] = [:]
        for (id, status) in raw {
            out[id] = Self.map(status)
        }
        return out
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
        // The monitor's `wakeAll` cancels the current backoff sleep and
        // re-starts the loop for every server; for a single-server retry we
        // stop + start to bypass the backoff for just this one.
        await self.monitor.stopMonitoring(serverID: serverID)
        await self.monitor.startMonitoring(serverID: serverID)
    }

    private static func map(_ status: SubsonicConnectionStatus) -> SubsonicSidebarConnectionState {
        switch status {
        case .unknown:
            .unknown

        case .connecting:
            .connecting

        case .online:
            .online

        case let .authFailed(msg):
            .authFailed(msg)

        case let .unreachable(msg):
            .unreachable(msg)

        case let .serverError(msg):
            .serverError(msg)
        }
    }
}
