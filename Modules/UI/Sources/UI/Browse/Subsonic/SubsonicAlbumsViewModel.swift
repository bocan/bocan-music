import Foundation
import Observability
import Subsonic
import SwiftSonic
import SwiftUI

// MARK: - SubsonicAlbumsViewModel

/// Drives the per-server Albums destination (Phase 19 step 10).
/// Pages via `getAlbumList2(type: .alphabeticalByName, size:, offset:)`.
@MainActor
public final class SubsonicAlbumsViewModel: ObservableObject {
    public static let pageSize = 100

    public let serverID: UUID
    public let listType: AlbumListType

    @Published public private(set) var albums: [AlbumID3] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var hasMorePages = true
    @Published public var errorMessage: String?

    private let dataSource: any SubsonicBrowseDataSource
    private let cache: (any SubsonicMetadataCaching)?
    private let log = AppLogger.make(.ui)

    private var cacheEntityID: String {
        self.listType.rawValue
    }

    private static let cacheKind = "albums.firstPage"

    public init(
        serverID: UUID,
        dataSource: any SubsonicBrowseDataSource,
        cache: (any SubsonicMetadataCaching)? = nil,
        listType: AlbumListType = .alphabeticalByName
    ) {
        self.serverID = serverID
        self.dataSource = dataSource
        self.cache = cache
        self.listType = listType
    }

    public func load() async {
        if self.albums.isEmpty {
            await self.hydrateFromCache()
        }
        self.hasMorePages = true
        await self.loadMore(replacingFirstPage: true)
    }

    public func loadMore() async {
        await self.loadMore(replacingFirstPage: false)
    }

    private func loadMore(replacingFirstPage: Bool) async {
        guard !self.isLoading, self.hasMorePages else { return }
        self.isLoading = true
        defer { self.isLoading = false }

        let isFirstPage = replacingFirstPage || self.albums.isEmpty
        do {
            let batch = try await self.dataSource.getAlbumList2(
                serverID: self.serverID,
                type: self.listType,
                size: Self.pageSize,
                offset: isFirstPage ? 0 : self.albums.count
            )
            if isFirstPage {
                self.albums = batch
                await self.saveFirstPageToCache(batch)
            } else {
                self.albums.append(contentsOf: batch)
            }
            if batch.count < Self.pageSize {
                self.hasMorePages = false
            }
            self.errorMessage = nil
        } catch {
            self.log.error("subsonic.albums.load.failed", ["error": String(reflecting: error)])
            self.errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "Could not load albums from this server."
        }
    }

    private func hydrateFromCache() async {
        guard self.albums.isEmpty, let cache = self.cache else { return }
        guard let data = await cache.loadCache(
            serverID: self.serverID,
            entityKind: Self.cacheKind,
            entityID: self.cacheEntityID
        ) else { return }
        guard let cached = try? JSONDecoder().decode([AlbumID3].self, from: data) else { return }
        self.albums = cached
    }

    private func saveFirstPageToCache(_ batch: [AlbumID3]) async {
        guard let cache = self.cache else { return }
        guard let payload = try? JSONEncoder().encode(batch) else { return }
        await cache.saveCache(
            serverID: self.serverID,
            entityKind: Self.cacheKind,
            entityID: self.cacheEntityID,
            payload: payload
        )
    }
}
