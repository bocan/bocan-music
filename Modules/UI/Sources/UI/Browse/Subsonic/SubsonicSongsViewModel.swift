import Foundation
import Observability
import Subsonic
import SwiftSonic
import SwiftUI

// MARK: - SubsonicSongsViewModel

/// Drives the per-server Songs destination (Phase 19 step 10).
///
/// Subsonic has no efficient "all songs" endpoint, so this view model
/// repeatedly calls `getRandomSongs` to surface a deep but shuffled sample of
/// the server's library. "Refresh" reseeds the sample; "Load more" appends.
@MainActor
public final class SubsonicSongsViewModel: ObservableObject {
    public static let pageSize = 100

    public let serverID: UUID

    @Published public private(set) var songs: [Song] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var hasMorePages = true
    @Published public var errorMessage: String?

    private let dataSource: any SubsonicBrowseDataSource
    private let log = AppLogger.make(.ui)

    public init(serverID: UUID, dataSource: any SubsonicBrowseDataSource) {
        self.serverID = serverID
        self.dataSource = dataSource
    }

    /// Initial load — replaces the current sample.
    public func load() async {
        self.songs = []
        self.hasMorePages = true
        await self.loadMore()
    }

    /// Appends another page of random songs. The server controls the seed,
    /// so duplicates across pages are possible. We dedupe defensively.
    public func loadMore() async {
        guard !self.isLoading, self.hasMorePages else { return }
        self.isLoading = true
        defer { self.isLoading = false }

        do {
            let batch = try await self.dataSource.getRandomSongs(
                serverID: self.serverID,
                size: Self.pageSize
            )
            if batch.isEmpty {
                self.hasMorePages = false
                return
            }
            let existing = Set(self.songs.map(\.id))
            let appended = batch.filter { !existing.contains($0.id) }
            self.songs.append(contentsOf: appended)
            // If the server returned a short page, assume we've sampled all
            // it's willing to give us in this session.
            if batch.count < Self.pageSize {
                self.hasMorePages = false
            }
            self.errorMessage = nil
        } catch {
            self.log.error("subsonic.songs.load.failed", ["error": String(reflecting: error)])
            self.errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "Could not load songs from this server."
        }
    }
}
