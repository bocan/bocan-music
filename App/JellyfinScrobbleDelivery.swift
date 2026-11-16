import Foundation
import Jellyfin
import Observability
import Scrobble

/// Bridges `Scrobble.JellyfinScrobbleDelivering` to the `Jellyfin` module, so
/// the `Scrobble` package stays independent of it (ADR-097 slice 6). It mirrors
/// `SubsonicScrobbleDelivery`.
///
/// A refused token turns into `ScrobbleError.invalidCredentials`, and the
/// monitor pings that server again at once. The monitor's own authenticated
/// ping decides whether the status dot goes to "Sign in again"; one refused
/// report is not proof the token was revoked (docs/GOTCHAS.md, "Jellyfin").
struct JellyfinScrobbleDelivery: JellyfinScrobbleDelivering {
    let service: JellyfinService
    let store: JellyfinServerStore
    let monitor: JellyfinConnectionMonitor
    private var log: AppLogger {
        AppLogger.make(.jellyfin)
    }

    func reportingServerIDs() async -> Set<UUID> {
        do {
            return try await Set(self.store.fetchAll().filter(\.scrobble).map(\.id))
        } catch {
            // No server reports this time; the next play reads the list again.
            self.log.warning("jellyfin.scrobble.serversReadFailed", ["error": String(reflecting: error)])
            return []
        }
    }

    func reportStarted(serverID: UUID, itemID: String) async throws {
        try await self.translatingRefusal(serverID: serverID) {
            try await self.service.reportPlaybackStarted(serverID: serverID, itemID: itemID)
        }
    }

    func reportStopped(serverID: UUID, itemID: String, positionTicks: Int64) async throws {
        try await self.translatingRefusal(serverID: serverID) {
            try await self.service.reportPlaybackStopped(serverID: serverID, itemID: itemID, positionTicks: positionTicks)
        }
    }

    private func translatingRefusal(serverID: UUID, _ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch let error as JellyfinError where error.isAuthenticationFailure {
            await self.monitor.recheck(serverID: serverID)
            throw ScrobbleError.invalidCredentials(provider: "jellyfin")
        }
    }
}
