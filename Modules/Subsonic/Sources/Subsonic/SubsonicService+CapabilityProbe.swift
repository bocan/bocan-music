import Foundation
import SwiftSonic

// MARK: - Legacy-core capability probe

/// Probes the legacy-core Subsonic endpoints (Internet Radio, Podcasts,
/// Bookmarks) and merges the results into the given capability snapshot.
///
/// These endpoints are part of the core Subsonic API since 1.9 — they are
/// NOT listed in `openSubsonicExtensions`, so `caps.supports(...)` from the
/// extensions response always reports `false` even for servers (like
/// Navidrome) that fully implement them. The only reliable signal is to
/// call each endpoint once:
///
/// - Success (any 200 response, even empty list) → supported.
/// - HTTP 404 / 501 / Subsonic `notFound` → unsupported.
/// - Transient errors (network failure, malformed response, etc.) →
///   leave the existing flag untouched so we never downgrade on a flaky
///   network.
///
/// Skipped for any capability already advertised via openSubsonicExtensions:
/// the advertised value is authoritative when present, and skipping spares
/// us a round-trip per server on launch.
extension SubsonicService {
    func probeLegacyCoreCapabilities(
        _ caps: SubsonicCapabilities,
        serverID: UUID
    ) async -> SubsonicCapabilities {
        guard let client = self.clientForCapabilityProbe(serverID: serverID) else { return caps }

        var updated = caps
        if !updated.supportsInternetRadio,
           let supported = await Self.classifyProbe({ _ = try await client.getInternetRadioStations() }) {
            updated.supportsInternetRadio = supported
        }
        if !updated.supportsPodcasts,
           let supported = await Self.classifyProbe({ _ = try await client.getPodcasts(includeEpisodes: false) }) {
            updated.supportsPodcasts = supported
        }
        if !updated.supportsBookmarks,
           let supported = await Self.classifyProbe({ _ = try await client.getBookmarks() }) {
            updated.supportsBookmarks = supported
        }
        return updated
    }

    /// Classifies a probe call's outcome: success → `true`, capability-lie
    /// signal → `false`, anything else → `nil` (don't override).
    private static func classifyProbe(_ call: () async throws -> Void) async -> Bool? {
        do {
            try await call()
            return true
        } catch let sonicError as SwiftSonicError where isCapabilityLie(sonicError) {
            return false
        } catch {
            return nil
        }
    }
}
