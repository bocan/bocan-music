import Foundation
import Observability
import Subsonic
import SwiftSonic
import SwiftUI

// MARK: - Hit wrappers

/// One song match from a federated `search3` fan-out, tagged with the
/// originating server so the row can render a source badge and dispatch
/// playback back to the correct server.
public struct SubsonicSongHit: Identifiable, Sendable {
    public let serverID: UUID
    public let serverName: String
    public let song: Song

    /// Identifier scoped per server so two servers exposing the same song ID
    /// don't collapse in a `ForEach`.
    public var id: String {
        "\(self.serverID.uuidString)::\(self.song.id)"
    }
}

public struct SubsonicAlbumHit: Identifiable, Sendable {
    public let serverID: UUID
    public let serverName: String
    public let album: AlbumID3

    public var id: String {
        "\(self.serverID.uuidString)::\(self.album.id)"
    }
}

public struct SubsonicArtistHit: Identifiable, Sendable {
    public let serverID: UUID
    public let serverName: String
    public let artist: ArtistID3

    public var id: String {
        "\(self.serverID.uuidString)::\(self.artist.id)"
    }
}

// MARK: - SubsonicMultiSourceSearchViewModel

/// Drives the cross-server Subsonic search. Fans `search3` out to every
/// `includeInGlobalSearch` server in parallel with a soft per-server
/// timeout, then exposes flat, aggregated hit lists. The per-destination
/// Subsonic views (Songs / Albums / Artists) consume these lists through
/// their existing native layouts whenever the global search field has text.
@MainActor
public final class SubsonicMultiSourceSearchViewModel: ObservableObject {
    /// Per-server soft timeout. Slow servers stop blocking the aggregate.
    public static let defaultTimeout: Duration = .milliseconds(2000)

    /// Limits per server. The Subsonic spec caps `search3` at ~500 per type.
    public static let songCount = 500
    public static let albumCount = 200
    public static let artistCount = 100

    @Published public private(set) var query = ""
    @Published public private(set) var songs: [SubsonicSongHit] = []
    @Published public private(set) var albums: [SubsonicAlbumHit] = []
    @Published public private(set) var artists: [SubsonicArtistHit] = []
    @Published public private(set) var isSearching = false
    @Published public private(set) var failedServerNames: [String] = []

    private let dataSource: any SubsonicBrowseDataSource
    private let timeout: Duration
    private let log = AppLogger.make(.ui)
    private var currentTask: Task<Void, Never>?

    public init(
        dataSource: any SubsonicBrowseDataSource,
        timeout: Duration = SubsonicMultiSourceSearchViewModel.defaultTimeout
    ) {
        self.dataSource = dataSource
        self.timeout = timeout
    }

    /// Cancels any in-flight search and clears the aggregated lists.
    public func clear() {
        self.currentTask?.cancel()
        self.currentTask = nil
        self.query = ""
        self.songs = []
        self.albums = []
        self.artists = []
        self.isSearching = false
        self.failedServerNames = []
    }

    /// Fan out `search3` to every `includeInGlobalSearch` server and merge
    /// results into the published hit lists. Trimmed empty queries clear.
    public func search(query rawQuery: String, servers: [SubsonicSidebarServer]) {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        self.currentTask?.cancel()

        guard !trimmed.isEmpty else {
            self.clear()
            return
        }

        let included = servers.filter(\.includeInGlobalSearch)
        guard !included.isEmpty else {
            self.query = trimmed
            self.songs = []
            self.albums = []
            self.artists = []
            self.isSearching = false
            self.failedServerNames = []
            return
        }

        self.query = trimmed
        self.songs = []
        self.albums = []
        self.artists = []
        self.failedServerNames = []
        self.isSearching = true

        let dataSource = self.dataSource
        let timeout = self.timeout
        self.currentTask = Task { [weak self] in
            await withTaskGroup(
                of: (UUID, String, Result<SearchResult3, Error>).self
            ) { group in
                for server in included {
                    group.addTask {
                        let result = await Self.searchOne(
                            serverID: server.id,
                            query: trimmed,
                            dataSource: dataSource,
                            timeout: timeout
                        )
                        return (server.id, server.name, result)
                    }
                }
                for await (serverID, name, result) in group {
                    guard let self else { return }
                    if Task.isCancelled { return }
                    self.merge(serverID: serverID, serverName: name, result: result)
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.isSearching = false
        }
    }

    private func merge(
        serverID: UUID,
        serverName: String,
        result: Result<SearchResult3, Error>
    ) {
        switch result {
        case let .success(payload):
            let newArtists = (payload.artist ?? []).map {
                SubsonicArtistHit(serverID: serverID, serverName: serverName, artist: $0)
            }
            let newAlbums = (payload.album ?? []).map {
                SubsonicAlbumHit(serverID: serverID, serverName: serverName, album: $0)
            }
            let newSongs = (payload.song ?? []).map {
                SubsonicSongHit(serverID: serverID, serverName: serverName, song: $0)
            }
            self.artists.append(contentsOf: newArtists)
            self.albums.append(contentsOf: newAlbums)
            self.songs.append(contentsOf: newSongs)

        case .failure:
            self.failedServerNames.append(serverName)
        }
    }

    private static func searchOne(
        serverID: UUID,
        query: String,
        dataSource: any SubsonicBrowseDataSource,
        timeout: Duration
    ) async -> Result<SearchResult3, Error> {
        let log = AppLogger.make(.ui)
        return await withTaskGroup(of: Result<SearchResult3, Error>?.self) { group in
            group.addTask {
                do {
                    let value = try await dataSource.search3(
                        serverID: serverID,
                        query: query,
                        artistCount: Self.artistCount,
                        albumCount: Self.albumCount,
                        songCount: Self.songCount
                    )
                    return .success(value)
                } catch is CancellationError {
                    return nil
                } catch {
                    log.warning(
                        "subsonic.search.failed",
                        ["server": serverID.uuidString, "error": String(reflecting: error)]
                    )
                    return .failure(error)
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                if Task.isCancelled { return nil }
                struct TimedOut: Error {}
                return .failure(TimedOut())
            }
            let first = await (group.next()).flatMap(\.self)
            group.cancelAll()
            return first ?? .failure(CancellationError())
        }
    }
}
