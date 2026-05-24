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
    private let log = AppLogger.make(.ui)

    public var totalArtistCount: Int {
        self.sections.reduce(0) { $0 + $1.artist.count }
    }

    public init(serverID: UUID, dataSource: any SubsonicBrowseDataSource) {
        self.serverID = serverID
        self.dataSource = dataSource
    }

    public func load() async {
        guard !self.isLoading else { return }
        self.isLoading = true
        defer { self.isLoading = false }

        do {
            self.sections = try await self.dataSource.getArtists(serverID: self.serverID)
            self.errorMessage = nil
        } catch {
            self.log.error("subsonic.artists.load.failed", ["error": String(reflecting: error)])
            self.sections = []
            self.errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "Could not load artists from this server."
        }
    }
}
