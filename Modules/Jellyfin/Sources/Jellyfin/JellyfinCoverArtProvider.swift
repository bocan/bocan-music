import Foundation
import Observability

// MARK: - JellyfinCoverArtProvider

/// Resolves cover-art URLs for Jellyfin items.
///
/// A lightweight facade over `JellyfinService.coverArtURL` that adds logging.
/// It mirrors `SubsonicCoverArtProvider`.
public struct JellyfinCoverArtProvider: Sendable {
    // MARK: - Dependencies

    private let service: JellyfinService
    private let log = AppLogger.make(.jellyfin)

    // MARK: - Init

    public init(service: JellyfinService) {
        self.service = service
    }

    // MARK: - API

    /// Returns the cover-art URL for an item on a specific server.
    ///
    /// - Parameters:
    ///   - serverID: The target server.
    ///   - itemID: The id of the item that owns the image (`coverArtID` on a model), not the song id.
    ///   - tag: That item's image tag (`coverArtTag`), so a changed cover does not show stale.
    ///   - size: The widest side wanted, in pixels, or `nil` for the original.
    /// - Returns: The URL, or `nil` if the item has no image (`itemID` is `nil`).
    public func coverArtURL(serverID: UUID, itemID: String?, tag: String?, size: Int? = nil) async throws -> URL? {
        guard let itemID else { return nil }
        do {
            let url = try await self.service.coverArtURL(serverID: serverID, itemID: itemID, tag: tag, size: size)
            // Log the item id but NOT the URL: it carries the access token.
            self.log.debug(
                "jellyfin.coverart.resolved",
                ["server": serverID.uuidString, "item": itemID, "size": size ?? 0]
            )
            return url
        } catch {
            self.log.warning(
                "jellyfin.coverart.fail",
                ["server": serverID.uuidString, "item": itemID, "err": error.localizedDescription]
            )
            throw error
        }
    }
}
