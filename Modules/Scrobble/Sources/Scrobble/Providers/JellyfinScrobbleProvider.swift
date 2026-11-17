import Foundation
import Observability

// MARK: - JellyfinScrobbleDelivering

/// Narrow adapter the provider talks to, so `Scrobble` never depends on
/// `Jellyfin` (ADR-097). The App implements it over `JellyfinService` and the
/// per-server `scrobble` flag. It mirrors `SubsonicScrobbleDelivering`.
public protocol JellyfinScrobbleDelivering: Sendable {
    /// Servers for which the user has switched play reports on.
    func reportingServerIDs() async -> Set<UUID>

    /// Tells the server the item has started ("now playing").
    func reportStarted(serverID: UUID, itemID: String) async throws

    /// Tells the server the item has stopped at `positionTicks` (100 ns ticks).
    /// Throws `ScrobbleError.invalidCredentials` when the server refuses the
    /// token, so the provider can tell it apart from any other failure.
    func reportStopped(serverID: UUID, itemID: String, positionTicks: Int64) async throws
}

// MARK: - JellyfinScrobbleProvider

/// Reports plays back to Jellyfin servers (ADR-097, D5).
///
/// "Now playing" sends "playback started". A counted play sends "playback
/// stopped" with the position at the item's full run time, so the server counts
/// it whatever its resume percentages say. It never also marks the item played,
/// which would count the play twice.
///
/// Only events with a Jellyfin pair are handled. Every other play is reported
/// `.ignored`, so the worker drains it from this provider's queue at once, as
/// the Subsonic provider does with non-Subsonic plays.
public actor JellyfinScrobbleProvider: ScrobbleProvider {
    public nonisolated let id = "jellyfin"
    public nonisolated let displayName = "Jellyfin"

    private let delivery: any JellyfinScrobbleDelivering
    private let log = AppLogger.make(.scrobble)

    public init(delivery: any JellyfinScrobbleDelivering) {
        self.delivery = delivery
    }

    public func nowPlaying(_ play: PlayEvent) async throws {
        guard let serverID = play.jellyfinServerID, let itemID = play.jellyfinItemID else { return }
        guard await self.delivery.reportingServerIDs().contains(serverID) else { return }
        do {
            try await self.delivery.reportStarted(serverID: serverID, itemID: itemID)
        } catch {
            // Now-playing is best-effort; never throw out of the dispatch path.
            self.log.warning("jellyfin.scrobble.nowplaying.fail", [
                "server": serverID.uuidString, "item": itemID, "err": String(reflecting: error),
            ])
        }
    }

    public func submit(_ plays: [PlayEvent]) async throws -> [SubmissionResult] {
        let reporting = await self.delivery.reportingServerIDs()
        var results: [SubmissionResult] = []
        results.reserveCapacity(plays.count)
        for play in plays {
            await results.append(SubmissionResult(queueID: play.queueID, outcome: self.outcome(for: play, reporting: reporting)))
        }
        return results
    }

    private func outcome(for play: PlayEvent, reporting: Set<UUID>) async -> SubmissionResult.Outcome {
        guard let serverID = play.jellyfinServerID, let itemID = play.jellyfinItemID else {
            return .ignored(reason: "not-jellyfin")
        }
        guard reporting.contains(serverID) else {
            return .ignored(reason: "server-scrobble-disabled")
        }
        do {
            try await self.delivery.reportStopped(
                serverID: serverID,
                itemID: itemID,
                positionTicks: Self.positionTicks(seconds: play.duration)
            )
            return .success
        } catch ScrobbleError.invalidCredentials {
            self.log.warning("jellyfin.scrobble.submit.authFailed", ["server": serverID.uuidString, "item": itemID])
            return .ignored(reason: "auth-failed")
        } catch {
            // As for Subsonic: no retry, so a lost answer can never count a play twice.
            self.log.warning("jellyfin.scrobble.submit.fail", [
                "server": serverID.uuidString, "item": itemID, "err": String(reflecting: error),
            ])
            return .ignored(reason: "submit-failed")
        }
    }

    public func love(track _: TrackIdentity, loved _: Bool) async throws {
        // No-op: a Jellyfin favourite is written through `JellyfinAnnotations`,
        // not through this provider.
    }

    public func isAuthenticated() async -> Bool {
        await !(self.delivery.reportingServerIDs()).isEmpty
    }

    /// Seconds to Jellyfin's 100 ns ticks. The queue row's length is the song's
    /// run time, or the time played when the server sent none (see
    /// `ScrobbleQueueRepository.enqueueJellyfin`).
    static func positionTicks(seconds: TimeInterval) -> Int64 {
        Int64((max(seconds, 0) * 10_000_000).rounded())
    }
}
