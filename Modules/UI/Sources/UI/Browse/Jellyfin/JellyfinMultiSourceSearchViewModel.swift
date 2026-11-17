import Foundation
import Jellyfin
import Observability
import SwiftUI

// MARK: - Hit wrappers

/// One song match from a federated search, tagged with the server it came from
/// so a row can show a source badge and playback can go back to that server.
public struct JellyfinSongHit: Identifiable, Sendable {
    public let serverID: UUID
    public let serverName: String
    public let song: JellyfinSong

    /// Scoped per server, so two servers with the same item id do not collapse in a `ForEach`.
    public var id: String {
        "\(self.serverID.uuidString)::\(self.song.id)"
    }
}

public struct JellyfinAlbumHit: Identifiable, Sendable {
    public let serverID: UUID
    public let serverName: String
    public let album: JellyfinAlbum

    public var id: String {
        "\(self.serverID.uuidString)::\(self.album.id)"
    }
}

public struct JellyfinArtistHit: Identifiable, Sendable {
    public let serverID: UUID
    public let serverName: String
    public let artist: JellyfinArtist

    public var id: String {
        "\(self.serverID.uuidString)::\(self.artist.id)"
    }
}

// MARK: - JellyfinMultiSourceSearchViewModel

/// Drives the cross-server Jellyfin search, the twin of
/// `SubsonicMultiSourceSearchViewModel`. It sends one search to every
/// `includeInGlobalSearch` server in parallel with a soft per-server timeout,
/// then exposes flat lists. The Jellyfin Songs, Albums and Artists views show
/// those lists in their usual layouts whenever the search field has text.
@MainActor
public final class JellyfinMultiSourceSearchViewModel: ObservableObject {
    /// A slow server stops blocking the aggregate after this long (1.5 s soft limit per ADR-035).
    public static let defaultTimeout: Duration = .milliseconds(1500)

    /// Limits per server and type.
    public static let songCount = 200
    public static let albumCount = 100
    public static let artistCount = 50

    @Published public private(set) var query = ""
    @Published public private(set) var songs: [JellyfinSongHit] = [] {
        didSet { self.rebuildRows() }
    }

    /// Decorated rows for `JellyfinSongTable`, owned here so the decoration of a
    /// result set runs once per change of the hits, not once per re-render (#475).
    @Published private(set) var rows: [JellyfinSongTableRow] = [] {
        didSet { self.rowsVersion &+= 1 }
    }

    /// Moves on every write to `rows` via `didSet`, so no path can forget it (#455).
    private(set) var rowsVersion = 0

    @Published public private(set) var albums: [JellyfinAlbumHit] = []
    @Published public private(set) var artists: [JellyfinArtistHit] = []
    @Published public private(set) var isSearching = false
    @Published public private(set) var failedServerNames: [String] = []

    private let dataSource: any JellyfinBrowseDataSource
    private let timeout: Duration
    /// How the soft timeout waits. A test replaces it so the race between a
    /// server's answer and the deadline never depends on how busy the machine is.
    private let sleep: @Sendable (Duration) async throws -> Void
    private var currentTask: Task<Void, Never>?

    public init(
        dataSource: any JellyfinBrowseDataSource,
        timeout: Duration = JellyfinMultiSourceSearchViewModel.defaultTimeout,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.dataSource = dataSource
        self.timeout = timeout
        self.sleep = sleep
    }

    deinit {
        self.currentTask?.cancel()
    }

    /// Shows the user's latest favourite clicks over the servers' values.
    private weak var annotations: JellyfinAnnotationCoordinator?

    /// Starts following `coordinator`'s favourite overrides.
    func attach(_ coordinator: JellyfinAnnotationCoordinator?) {
        guard let coordinator, coordinator !== self.annotations else { return }
        self.annotations = coordinator
        coordinator.addObserver(self)
        self.rebuildRows()
    }

    private func rebuildRows() {
        let annotations = self.annotations
        self.rows = self.songs.map {
            JellyfinSongTableRow(
                song: annotations?.applying(to: $0.song, serverID: $0.serverID) ?? $0.song,
                serverID: $0.serverID,
                serverName: $0.serverName
            )
        }
    }

    /// Cancels any search in flight and empties every list.
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

    /// Searches every server that takes part in global search and merges the
    /// results into the lists. An empty query clears them.
    public func search(query rawQuery: String, servers: [JellyfinSidebarServer]) {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        self.currentTask?.cancel()

        guard !trimmed.isEmpty else {
            self.clear()
            return
        }

        self.query = trimmed
        self.songs = []
        self.albums = []
        self.artists = []
        self.failedServerNames = []

        let included = servers.filter(\.includeInGlobalSearch)
        guard !included.isEmpty else {
            self.isSearching = false
            return
        }
        self.isSearching = true

        let dataSource = self.dataSource
        let timeout = self.timeout
        let sleep = self.sleep
        self.currentTask = Task { [weak self] in
            await withTaskGroup(of: (UUID, String, Result<JellyfinSearchResult, Error>).self) { group in
                for server in included {
                    group.addTask {
                        let result = await Self.searchOne(
                            serverID: server.id,
                            query: trimmed,
                            dataSource: dataSource,
                            timeout: timeout,
                            sleep: sleep
                        )
                        return (server.id, server.name, result)
                    }
                }
                for await (serverID, name, result) in group {
                    guard let self, !Task.isCancelled else { return }
                    self.merge(serverID: serverID, serverName: name, result: result)
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.isSearching = false
        }
    }

    private func merge(serverID: UUID, serverName: String, result: Result<JellyfinSearchResult, Error>) {
        switch result {
        case let .success(payload):
            self.artists += payload.artists.map { JellyfinArtistHit(serverID: serverID, serverName: serverName, artist: $0) }
            self.albums += payload.albums.map { JellyfinAlbumHit(serverID: serverID, serverName: serverName, album: $0) }
            self.songs += payload.songs.map { JellyfinSongHit(serverID: serverID, serverName: serverName, song: $0) }

        case .failure:
            self.failedServerNames.append(serverName)
        }
    }

    /// One server's search, raced against the soft timeout.
    private static func searchOne(
        serverID: UUID,
        query: String,
        dataSource: any JellyfinBrowseDataSource,
        timeout: Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) async -> Result<JellyfinSearchResult, Error> {
        let log = AppLogger.make(.ui)
        return await withTaskGroup(of: Result<JellyfinSearchResult, Error>?.self) { group in
            group.addTask {
                do {
                    let value = try await dataSource.search(
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
                        "ui.jellyfin.search.failed",
                        ["server": serverID.uuidString, "error": String(reflecting: error)]
                    )
                    return .failure(error)
                }
            }
            group.addTask {
                do {
                    try await sleep(timeout)
                } catch {
                    return nil
                }
                return .failure(JellyfinBrowseError.searchTimedOut(serverID: serverID, after: timeout))
            }
            let first = await (group.next()).flatMap(\.self)
            group.cancelAll()
            return first ?? .failure(CancellationError())
        }
    }
}

extension JellyfinMultiSourceSearchViewModel: JellyfinAnnotationObserving {
    public func annotationOverridesDidChange() {
        self.rebuildRows()
    }
}
