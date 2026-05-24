import Foundation
import Observability

// MARK: - SubsonicScrobbleDelivering

/// Narrow adapter the provider talks to so the `Scrobble` module doesn't have
/// to depend on the `Subsonic` module. The app wires this up by closing over
/// `SubsonicService.scrobble(serverID:songID:submission:)` and the
/// per-server "scrobble" toggle set.
public protocol SubsonicScrobbleDelivering: Sendable {
    /// Servers for which the user has enabled scrobble write-through.
    func scrobbleEnabledServerIDs() async -> Set<UUID>
    /// Submit a play to the given server. `submission == false` means this is
    /// a now-playing notification rather than a completed-play record.
    func scrobble(serverID: UUID, songID: String, submission: Bool) async throws
}

// MARK: - SubsonicScrobbleProvider

/// Write-through scrobble provider for Subsonic/Navidrome/OpenSubsonic servers.
///
/// Only handles events with a `subsonicServerID`/`subsonicSongID` pair —
/// events from local-library plays are reported as `.ignored` so the worker
/// drains them from the Subsonic queue without ever touching a server.
public actor SubsonicScrobbleProvider: ScrobbleProvider {
    public nonisolated let id = "subsonic"
    public nonisolated let displayName = "Subsonic"

    private let delivery: any SubsonicScrobbleDelivering
    private let log = AppLogger.make(.scrobble)

    public init(delivery: any SubsonicScrobbleDelivering) {
        self.delivery = delivery
    }

    public func nowPlaying(_ play: PlayEvent) async throws {
        guard let serverID = play.subsonicServerID, let songID = play.subsonicSongID else { return }
        let enabled = await self.delivery.scrobbleEnabledServerIDs()
        guard enabled.contains(serverID) else { return }
        do {
            try await self.delivery.scrobble(serverID: serverID, songID: songID, submission: false)
        } catch {
            // Now-playing is best-effort; never throw out of the dispatch path.
            self.log.warning("subsonic.scrobble.nowplaying.fail", [
                "server": serverID.uuidString, "song": songID, "err": String(reflecting: error),
            ])
        }
    }

    public func submit(_ plays: [PlayEvent]) async throws -> [SubmissionResult] {
        let enabled = await self.delivery.scrobbleEnabledServerIDs()
        var results: [SubmissionResult] = []
        results.reserveCapacity(plays.count)
        for play in plays {
            guard let serverID = play.subsonicServerID, let songID = play.subsonicSongID else {
                // Local-library plays — not our concern.
                results.append(SubmissionResult(queueID: play.queueID, outcome: .ignored(reason: "not-subsonic")))
                continue
            }
            guard enabled.contains(serverID) else {
                results.append(SubmissionResult(
                    queueID: play.queueID,
                    outcome: .ignored(reason: "server-scrobble-disabled")
                ))
                continue
            }
            do {
                try await self.delivery.scrobble(serverID: serverID, songID: songID, submission: true)
                results.append(SubmissionResult(queueID: play.queueID, outcome: .success))
            } catch {
                self.log.warning("subsonic.scrobble.submit.fail", [
                    "server": serverID.uuidString, "song": songID, "err": String(reflecting: error),
                ])
                results.append(SubmissionResult(
                    queueID: play.queueID,
                    outcome: .ignored(reason: "submit-failed")
                ))
            }
        }
        return results
    }

    public func love(track _: TrackIdentity, loved _: Bool) async throws {
        // No-op — Subsonic "star" is handled write-through via
        // `SubsonicAnnotations` (Phase 19 step 14), not through this provider.
    }

    public func isAuthenticated() async -> Bool {
        await !(self.delivery.scrobbleEnabledServerIDs()).isEmpty
    }
}
