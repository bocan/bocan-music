import Foundation
import Observability
import Subsonic
import SwiftSonic
import SwiftUI

// MARK: - SubsonicArtistsViewModel

/// Drives the per-server Artists destination (Phase 19 step 10).
///
/// `getArtists` returns the index pre-sectioned by leading letter; no paging
/// is exposed by the API, so we render the full result. Servers with very
/// large catalogues already chunk the index server-side.
@MainActor
public final class SubsonicArtistsViewModel: ObservableObject {
    public let serverID: UUID

    @Published public private(set) var sections: [ArtistIndex] = []
    @Published public private(set) var isLoading = false
    @Published public var errorMessage: String?

    private let dataSource: any SubsonicBrowseDataSource
    private let cache: (any SubsonicMetadataCaching)?
    private let log = AppLogger.make(.ui)

    private static let cacheKind = "artists"
    private static let cacheEntityID = "all"

    public var totalArtistCount: Int {
        self.sections.reduce(0) { $0 + $1.artist.count }
    }

    public init(
        serverID: UUID,
        dataSource: any SubsonicBrowseDataSource,
        cache: (any SubsonicMetadataCaching)? = nil
    ) {
        self.serverID = serverID
        self.dataSource = dataSource
        self.cache = cache
    }

    public func load() async {
        guard !self.isLoading else { return }
        if self.sections.isEmpty {
            await self.hydrateFromCache()
        }
        self.isLoading = true
        defer { self.isLoading = false }

        do {
            let fresh = try await self.dataSource.getArtists(serverID: self.serverID)
            self.sections = fresh
            await self.saveToCache(fresh)
            self.errorMessage = nil
        } catch {
            self.log.error("subsonic.artists.load.failed", ["error": String(reflecting: error)])
            self.errorMessage = (error as? LocalizedError)?.errorDescription
                ?? L10n.string("Could not load artists from this server.")
        }
    }

    private func hydrateFromCache() async {
        guard let cache = self.cache else { return }
        guard let data = await cache.loadCache(
            serverID: self.serverID,
            entityKind: Self.cacheKind,
            entityID: Self.cacheEntityID
        ) else { return }
        guard let cached = try? JSONDecoder().decode([ArtistIndex].self, from: data) else { return }
        self.sections = cached
    }

    private func saveToCache(_ sections: [ArtistIndex]) async {
        guard let cache = self.cache else { return }
        guard let payload = try? JSONEncoder().encode(sections) else { return }
        await cache.saveCache(
            serverID: self.serverID,
            entityKind: Self.cacheKind,
            entityID: Self.cacheEntityID,
            payload: payload
        )
    }
}
