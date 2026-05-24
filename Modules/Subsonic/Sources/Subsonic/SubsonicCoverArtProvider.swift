import Foundation
import Observability

// MARK: - SubsonicCoverArtProvider

/// Resolves cover-art URLs for Subsonic entities.
///
/// This is a lightweight façade over `SubsonicService.coverArtURL` that adds
/// logging and hides the raw `SwiftSonicClient` from callers.
public struct SubsonicCoverArtProvider: Sendable {
    // MARK: - Dependencies

    private let service: SubsonicService
    private let log = AppLogger.make(.subsonic)

    // MARK: - Init

    public init(service: SubsonicService) {
        self.service = service
    }

    // MARK: - API

    /// Returns the cover-art URL for an entity on a specific server.
    ///
    /// - Parameters:
    ///   - serverID: The target server.
    ///   - entityID: The Subsonic entity ID (song, album, artist, playlist…).
    ///   - size: Requested thumbnail size in pixels, or `nil` for original.
    /// - Returns: The URL, or `nil` if the server doesn't support cover art.
    public func coverArtURL(serverID: UUID, entityID: String, size: Int? = nil) async throws -> URL? {
        do {
            let url = try await self.service.coverArtURL(serverID: serverID, entityID: entityID, size: size)
            // Log the entity ID but NOT the full URL (it may contain auth params).
            self.log.debug(
                "subsonic.coverart.resolved",
                ["server": serverID.uuidString, "entity": entityID, "size": size ?? 0]
            )
            return url
        } catch {
            self.log.warning(
                "subsonic.coverart.fail",
                ["server": serverID.uuidString, "entity": entityID, "err": error.localizedDescription]
            )
            throw error
        }
    }
}
