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
    private let cache: (any SubsonicMetadataCaching)?
    private let log = AppLogger.make(.ui)

    private static let cacheKind = "songs.randomSample"
    private static let cacheEntityID = "default"

    public init(
        serverID: UUID,
        dataSource: any SubsonicBrowseDataSource,
        cache: (any SubsonicMetadataCaching)? = nil
    ) {
        self.serverID = serverID
        self.dataSource = dataSource
        self.cache = cache
    }

    /// Initial load — populates the random sample once per view lifetime.
    /// Idempotent: if `songs` is already non-empty (from a prior in-session
    /// fetch) or the persisted cache hydrates one, no network re-fetch is
    /// issued. This stops the sample from re-shuffling every time `.task`
    /// re-fires (e.g. on view re-appearance) and avoids the visible flash of
    /// "cached snapshot → fresh random batch replaces it" on launch.
    /// Use `refresh()` to explicitly reseed.
    public func load() async {
        if !self.songs.isEmpty { return }
        await self.hydrateFromCache()
        if !self.songs.isEmpty { return }
        self.hasMorePages = true
        await self.loadMore(replacingSample: true)
    }

    /// Explicit user-triggered reshuffle: discards the current sample and
    /// fetches a fresh random batch from the server. Used by the toolbar's
    /// Refresh button.
    public func refresh() async {
        self.songs = []
        self.hasMorePages = true
        await self.loadMore(replacingSample: true)
    }

    /// Appends another page of random songs. The server controls the seed,
    /// so duplicates across pages are possible. We dedupe defensively.
    public func loadMore() async {
        await self.loadMore(replacingSample: false)
    }

    private func loadMore(replacingSample: Bool) async {
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
            if replacingSample {
                self.songs = batch
                await self.saveToCache(batch)
            } else {
                let existing = Set(self.songs.map(\.id))
                let appended = batch.filter { !existing.contains($0.id) }
                self.songs.append(contentsOf: appended)
            }
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

    private func hydrateFromCache() async {
        guard let cache = self.cache else { return }
        guard let data = await cache.loadCache(
            serverID: self.serverID,
            entityKind: Self.cacheKind,
            entityID: Self.cacheEntityID
        ) else { return }
        guard let cached = try? JSONDecoder().decode([Song].self, from: data) else { return }
        self.songs = cached
    }

    private func saveToCache(_ songs: [Song]) async {
        guard let cache = self.cache else { return }
        guard let payload = try? JSONEncoder().encode(songs) else { return }
        await cache.saveCache(
            serverID: self.serverID,
            entityKind: Self.cacheKind,
            entityID: Self.cacheEntityID,
            payload: payload
        )
    }
}
