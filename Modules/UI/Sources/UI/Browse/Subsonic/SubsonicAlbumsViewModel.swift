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

    @Published public private(set) var albums: [AlbumID3] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var hasMorePages = true
    @Published public var errorMessage: String?

    private let dataSource: any SubsonicBrowseDataSource
    private let log = AppLogger.make(.ui)

    public init(serverID: UUID, dataSource: any SubsonicBrowseDataSource) {
        self.serverID = serverID
        self.dataSource = dataSource
    }

    public func load() async {
        self.albums = []
        self.hasMorePages = true
        await self.loadMore()
    }

    public func loadMore() async {
        guard !self.isLoading, self.hasMorePages else { return }
        self.isLoading = true
        defer { self.isLoading = false }

        do {
            let batch = try await self.dataSource.getAlbumList2(
                serverID: self.serverID,
                type: .alphabeticalByName,
                size: Self.pageSize,
                offset: self.albums.count
            )
            self.albums.append(contentsOf: batch)
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
}
