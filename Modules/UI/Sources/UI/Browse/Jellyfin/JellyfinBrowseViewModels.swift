import Foundation
import Jellyfin
import Observability
import SwiftUI

// MARK: - JellyfinBrowseCache

/// Reads and writes a browse snapshot through the metadata cache, so a view can
/// draw at once from the last answer before it asks the server again.
///
/// The cache is best effort, as the Subsonic one is: a miss and a snapshot that
/// no longer decodes look the same to the caller. A snapshot that does not
/// decode is logged, since it means a model changed shape.
struct JellyfinBrowseCache {
    let cache: (any SubsonicMetadataCaching)?
    let serverID: UUID
    private let log = AppLogger.make(.ui)

    func load<Value: Decodable>(_ type: Value.Type, kind: String, id: String) async -> Value? {
        guard let cache = self.cache,
              let data = await cache.loadCache(serverID: self.serverID, entityKind: kind, entityID: id) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            self.log.warning("ui.jellyfin.cache.decodeFailed", ["kind": kind, "error": String(reflecting: error)])
            return nil
        }
    }

    func save(_ value: some Encodable, kind: String, id: String) async {
        guard let cache = self.cache else { return }
        do {
            let payload = try JSONEncoder().encode(value)
            await cache.saveCache(serverID: self.serverID, entityKind: kind, entityID: id, payload: payload)
        } catch {
            self.log.warning("ui.jellyfin.cache.encodeFailed", ["kind": kind, "error": String(reflecting: error)])
        }
    }
}

// MARK: - JellyfinSongsViewModel

/// Which list the per-server Songs view shows.
public enum JellyfinSongsSource: String, Sendable, Hashable {
    /// Every song, by artist, album and track, paged.
    case all
    /// A random selection. "Refresh" draws a new one.
    case random
    /// The songs played most, most first.
    case mostPlayed
}

/// Drives the per-server Songs, Random and Most Played destinations (ADR-097).
///
/// Unlike Subsonic, Jellyfin can page through every song, so Songs is the real
/// list and not a sample. Random and Most Played are one request each.
@MainActor
public final class JellyfinSongsViewModel: JellyfinSongListModel {
    public static let pageSize = 100

    public let source: JellyfinSongsSource
    @Published public private(set) var hasMorePages = true

    private let dataSource: any JellyfinBrowseDataSource
    private let browseCache: JellyfinBrowseCache
    private static let cacheKind = "songs.firstPage"

    public init(
        serverID: UUID,
        dataSource: any JellyfinBrowseDataSource,
        cache: (any SubsonicMetadataCaching)? = nil,
        source: JellyfinSongsSource = .all,
        serverName: String = ""
    ) {
        self.source = source
        self.dataSource = dataSource
        self.browseCache = JellyfinBrowseCache(cache: cache, serverID: serverID)
        super.init(serverID: serverID, serverName: serverName)
    }

    /// Draws the cached first page at once, then asks the server. A random
    /// selection that came from the cache is kept, so it does not reshuffle each
    /// time the view appears; "Refresh" draws a new one.
    public func load() async {
        if !self.songs.isEmpty {
            return
        }
        if let cached = await self.browseCache.load([JellyfinSong].self, kind: Self.cacheKind, id: self.source.rawValue) {
            self.songs = cached
            if self.source == .random {
                self.hasMorePages = false
                return
            }
        }
        self.hasMorePages = true
        await self.fetch(replacingFirstPage: true)
    }

    /// Throws the list away and asks the server again.
    public func refresh() async {
        self.songs = []
        self.hasMorePages = true
        await self.fetch(replacingFirstPage: true)
    }

    /// Appends the next page. Random and Most Played have no further page.
    public func loadMore() async {
        await self.fetch(replacingFirstPage: false)
    }

    private func fetch(replacingFirstPage: Bool) async {
        guard !self.isLoading, self.hasMorePages else { return }
        self.isLoading = true
        defer { self.isLoading = false }
        let isFirstPage = replacingFirstPage || self.songs.isEmpty
        do {
            let batch: [JellyfinSong]
            var total: Int?
            switch self.source {
            case .all:
                let page = try await self.dataSource.songs(
                    serverID: self.serverID,
                    startIndex: isFirstPage ? 0 : self.songs.count,
                    limit: Self.pageSize
                )
                batch = page.items
                total = page.total

            case .random:
                batch = try await self.dataSource.randomSongs(serverID: self.serverID, limit: Self.pageSize)

            case .mostPlayed:
                batch = try await self.dataSource.mostPlayedSongs(serverID: self.serverID, limit: Self.pageSize)
            }
            if isFirstPage {
                self.songs = batch
                await self.browseCache.save(batch, kind: Self.cacheKind, id: self.source.rawValue)
            } else {
                let existing = Set(self.songs.map(\.id))
                self.songs.append(contentsOf: batch.filter { !existing.contains($0.id) })
            }
            self.hasMorePages = self.source == .all && batch.count == Self.pageSize
                && total.map { self.songs.count < $0 } ?? true
            self.errorMessage = nil
        } catch {
            self.log.error("ui.jellyfin.songs.load.failed", ["error": String(reflecting: error)])
            self.errorMessage = self.message(for: error, fallback: L10n.string("Could not load songs from this server."))
        }
    }
}

// MARK: - JellyfinAlbumsViewModel

/// Drives the per-server Albums and Recently Added destinations (ADR-097).
/// Pages with `StartIndex` and `Limit`, 100 at a time.
@MainActor
public final class JellyfinAlbumsViewModel: ObservableObject {
    public static let pageSize = 100

    public let serverID: UUID
    public let list: JellyfinAlbumList

    @Published public private(set) var albums: [JellyfinAlbum] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var hasMorePages = true
    @Published public var errorMessage: String?

    private let dataSource: any JellyfinBrowseDataSource
    private let browseCache: JellyfinBrowseCache
    private let log = AppLogger.make(.ui)
    private static let cacheKind = "albums.firstPage"

    private var cacheEntityID: String {
        switch self.list {
        case .alphabetical:
            "alphabetical"

        case .recentlyAdded:
            "recentlyAdded"
        }
    }

    public init(
        serverID: UUID,
        dataSource: any JellyfinBrowseDataSource,
        cache: (any SubsonicMetadataCaching)? = nil,
        list: JellyfinAlbumList = .alphabetical
    ) {
        self.serverID = serverID
        self.dataSource = dataSource
        self.browseCache = JellyfinBrowseCache(cache: cache, serverID: serverID)
        self.list = list
    }

    public func load() async {
        if self.albums.isEmpty,
           let cached = await self.browseCache.load([JellyfinAlbum].self, kind: Self.cacheKind, id: self.cacheEntityID) {
            self.albums = cached
        }
        self.hasMorePages = true
        await self.fetch(replacingFirstPage: true)
    }

    public func loadMore() async {
        await self.fetch(replacingFirstPage: false)
    }

    private func fetch(replacingFirstPage: Bool) async {
        guard !self.isLoading, self.hasMorePages else { return }
        self.isLoading = true
        defer { self.isLoading = false }
        let isFirstPage = replacingFirstPage || self.albums.isEmpty
        do {
            let page = try await self.dataSource.albums(
                serverID: self.serverID,
                list: self.list,
                startIndex: isFirstPage ? 0 : self.albums.count,
                limit: Self.pageSize
            )
            if isFirstPage {
                self.albums = page.items
                await self.browseCache.save(page.items, kind: Self.cacheKind, id: self.cacheEntityID)
            } else {
                let existing = Set(self.albums.map(\.id))
                self.albums.append(contentsOf: page.items.filter { !existing.contains($0.id) })
            }
            self.hasMorePages = page.items.count == Self.pageSize && page.total.map { self.albums.count < $0 } ?? true
            self.errorMessage = nil
        } catch {
            self.log.error("ui.jellyfin.albums.load.failed", ["error": String(reflecting: error)])
            self.errorMessage = (error as? LocalizedError)?.errorDescription
                ?? L10n.string("Could not load albums from this server.")
        }
    }
}

// MARK: - JellyfinArtistsViewModel

/// Drives the per-server Artists destination (ADR-097). Album artists come in
/// pages; the view groups the loaded ones by initial.
@MainActor
public final class JellyfinArtistsViewModel: ObservableObject {
    public static let pageSize = 100

    /// One letter of the artist list.
    public struct Section: Identifiable, Sendable {
        public let letter: String
        public let artists: [JellyfinArtist]
        public var id: String {
            self.letter
        }
    }

    public let serverID: UUID

    @Published public private(set) var artists: [JellyfinArtist] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var hasMorePages = true
    @Published public var errorMessage: String?

    private let dataSource: any JellyfinBrowseDataSource
    private let browseCache: JellyfinBrowseCache
    private let log = AppLogger.make(.ui)
    private static let cacheKind = "artists.firstPage"
    private static let cacheEntityID = "all"

    public init(serverID: UUID, dataSource: any JellyfinBrowseDataSource, cache: (any SubsonicMetadataCaching)? = nil) {
        self.serverID = serverID
        self.dataSource = dataSource
        self.browseCache = JellyfinBrowseCache(cache: cache, serverID: serverID)
    }

    /// The loaded artists grouped by initial, with a "#" group last.
    public var sections: [Section] {
        Self.group(self.artists)
    }

    public func load() async {
        if self.artists.isEmpty,
           let cached = await self.browseCache.load([JellyfinArtist].self, kind: Self.cacheKind, id: Self.cacheEntityID) {
            self.artists = cached
        }
        self.hasMorePages = true
        await self.fetch(replacingFirstPage: true)
    }

    public func loadMore() async {
        await self.fetch(replacingFirstPage: false)
    }

    private func fetch(replacingFirstPage: Bool) async {
        guard !self.isLoading, self.hasMorePages else { return }
        self.isLoading = true
        defer { self.isLoading = false }
        let isFirstPage = replacingFirstPage || self.artists.isEmpty
        do {
            let page = try await self.dataSource.artists(
                serverID: self.serverID,
                startIndex: isFirstPage ? 0 : self.artists.count,
                limit: Self.pageSize
            )
            if isFirstPage {
                self.artists = page.items
                await self.browseCache.save(page.items, kind: Self.cacheKind, id: Self.cacheEntityID)
            } else {
                let existing = Set(self.artists.map(\.id))
                self.artists.append(contentsOf: page.items.filter { !existing.contains($0.id) })
            }
            self.hasMorePages = page.items.count == Self.pageSize && page.total.map { self.artists.count < $0 } ?? true
            self.errorMessage = nil
        } catch {
            self.log.error("ui.jellyfin.artists.load.failed", ["error": String(reflecting: error)])
            self.errorMessage = (error as? LocalizedError)?.errorDescription
                ?? L10n.string("Could not load artists from this server.")
        }
    }

    /// Groups artists by the first letter of the name, with "#" for anything else, last.
    static func group(_ artists: [JellyfinArtist]) -> [Section] {
        var groups: [String: [JellyfinArtist]] = [:]
        for artist in artists {
            groups[Self.letter(for: artist.name), default: []].append(artist)
        }
        return groups
            .map { Section(letter: $0.key, artists: $0.value) }
            .sorted { lhs, rhs in
                if lhs.letter == "#" {
                    return false
                }
                if rhs.letter == "#" {
                    return true
                }
                return lhs.letter < rhs.letter
            }
    }

    static func letter(for name: String) -> String {
        guard let first = name.first, first.isLetter else { return "#" }
        return String(first).uppercased()
    }
}

// MARK: - JellyfinGenresViewModel

/// Drives the genre list of the per-server Genres destination (ADR-097). The
/// songs of the chosen genre come from `JellyfinGenreSongsModel`.
@MainActor
public final class JellyfinGenresViewModel: ObservableObject {
    private static let pageSize = 500

    public let serverID: UUID

    @Published public private(set) var genres: [JellyfinGenre] = []
    @Published public private(set) var isLoading = false
    @Published public var errorMessage: String?

    private let dataSource: any JellyfinBrowseDataSource
    private let browseCache: JellyfinBrowseCache
    private let log = AppLogger.make(.ui)
    private static let cacheKind = "genres"
    private static let cacheEntityID = "all"

    public init(serverID: UUID, dataSource: any JellyfinBrowseDataSource, cache: (any SubsonicMetadataCaching)? = nil) {
        self.serverID = serverID
        self.dataSource = dataSource
        self.browseCache = JellyfinBrowseCache(cache: cache, serverID: serverID)
    }

    /// Loads every genre, a page at a time. A server has few genres, so the whole list is kept.
    public func load() async {
        guard !self.isLoading else { return }
        if self.genres.isEmpty,
           let cached = await self.browseCache.load([JellyfinGenre].self, kind: Self.cacheKind, id: Self.cacheEntityID) {
            self.genres = cached
        }
        self.isLoading = true
        defer { self.isLoading = false }
        do {
            var all: [JellyfinGenre] = []
            while true {
                let page = try await self.dataSource.genres(serverID: self.serverID, startIndex: all.count, limit: Self.pageSize)
                all.append(contentsOf: page.items)
                if page.items.count < Self.pageSize || page.total.map({ all.count >= $0 }) == true {
                    break
                }
            }
            self.genres = all
            await self.browseCache.save(all, kind: Self.cacheKind, id: Self.cacheEntityID)
            self.errorMessage = nil
        } catch {
            self.log.error("ui.jellyfin.genres.load.failed", ["error": String(reflecting: error)])
            self.errorMessage = (error as? LocalizedError)?.errorDescription
                ?? L10n.string("Could not load genres from this server.")
        }
    }
}

// MARK: - JellyfinGenreSongsModel

/// The songs of one genre, paged. One model per chosen genre.
@MainActor
public final class JellyfinGenreSongsModel: JellyfinSongListModel {
    public static let pageSize = 100

    public let genreID: String
    @Published public private(set) var hasMorePages = true

    private let dataSource: any JellyfinBrowseDataSource

    public init(serverID: UUID, genreID: String, dataSource: any JellyfinBrowseDataSource, serverName: String = "") {
        self.genreID = genreID
        self.dataSource = dataSource
        super.init(serverID: serverID, serverName: serverName)
    }

    public func loadMore() async {
        guard !self.isLoading, self.hasMorePages else { return }
        self.isLoading = true
        defer { self.isLoading = false }
        do {
            let page = try await self.dataSource.songsByGenre(
                serverID: self.serverID,
                genreID: self.genreID,
                startIndex: self.songs.count,
                limit: Self.pageSize
            )
            let existing = Set(self.songs.map(\.id))
            self.songs.append(contentsOf: page.items.filter { !existing.contains($0.id) })
            self.hasMorePages = page.items.count == Self.pageSize && page.total.map { self.songs.count < $0 } ?? true
            self.errorMessage = nil
        } catch {
            self.log.error("ui.jellyfin.genreSongs.load.failed", ["error": String(reflecting: error)])
            self.errorMessage = self.message(for: error, fallback: L10n.string("Could not load songs for this genre."))
        }
    }
}
