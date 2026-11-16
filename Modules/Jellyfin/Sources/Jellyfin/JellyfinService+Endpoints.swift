import Foundation

/// The endpoint methods of `JellyfinService`: browsing, lists, playlists,
/// search, favourites, play reports and media URLs.
///
/// Every method throws `JellyfinError.unknownServer` when `serverID` has no
/// client, and another `JellyfinError` when the request fails.
public extension JellyfinService {
    // MARK: - Browsing

    /// One page of every song, by artist, album, disc and track.
    func songs(serverID: UUID, startIndex: Int = 0, limit: Int = 100) async throws -> JellyfinPage<JellyfinSong> {
        let query = JellyfinItemQuery(
            kind: .song,
            sort: [.albumArtist, .album, .discNumber, .trackNumber],
            startIndex: startIndex,
            limit: limit
        )
        return try await self.withClient(serverID) { try await $0.songs(query) }
    }

    /// One page of albums in the given order.
    func albums(
        serverID: UUID,
        list: JellyfinAlbumList = .alphabetical,
        startIndex: Int = 0,
        limit: Int = 100
    ) async throws -> JellyfinPage<JellyfinAlbum> {
        let query = switch list {
        case .alphabetical:
            JellyfinItemQuery(kind: .album, sort: [.sortName], startIndex: startIndex, limit: limit)

        case .recentlyAdded:
            JellyfinItemQuery(kind: .album, sort: [.dateCreated], descending: true, startIndex: startIndex, limit: limit)
        }
        return try await self.withClient(serverID) { try await $0.albums(query) }
    }

    /// One page of album artists, by name.
    func artists(serverID: UUID, startIndex: Int = 0, limit: Int = 100) async throws -> JellyfinPage<JellyfinArtist> {
        let query = JellyfinItemQuery(kind: .artist, sort: [.sortName], startIndex: startIndex, limit: limit)
        return try await self.withClient(serverID) { try await $0.artists(query) }
    }

    /// One page of music genres, by name.
    func genres(serverID: UUID, startIndex: Int = 0, limit: Int = 100) async throws -> JellyfinPage<JellyfinGenre> {
        try await self.withClient(serverID) { try await $0.genres(startIndex: startIndex, limit: limit) }
    }

    /// One page of the songs in a genre, by artist, album and track.
    func songsByGenre(
        serverID: UUID,
        genreID: String,
        startIndex: Int = 0,
        limit: Int = 100
    ) async throws -> JellyfinPage<JellyfinSong> {
        let query = JellyfinItemQuery(
            kind: .song,
            sort: [.albumArtist, .album, .discNumber, .trackNumber],
            genreID: genreID,
            startIndex: startIndex,
            limit: limit
        )
        return try await self.withClient(serverID) { try await $0.songs(query) }
    }

    /// The album with this id, or `nil` if the server has none.
    func album(serverID: UUID, id: String) async throws -> JellyfinAlbum? {
        let query = JellyfinItemQuery(kind: .album, ids: [id], limit: 1)
        return try await self.withClient(serverID) { try await $0.albums(query) }.items.first
    }

    /// Every song of an album, in disc and track order.
    func albumSongs(serverID: UUID, albumID: String) async throws -> [JellyfinSong] {
        let query = JellyfinItemQuery(kind: .song, sort: [.discNumber, .trackNumber], parentID: albumID)
        return try await self.withClient(serverID) { try await $0.songs(query) }.items
    }

    /// The artist with this id, or `nil` if the server has none.
    func artist(serverID: UUID, id: String) async throws -> JellyfinArtist? {
        let query = JellyfinItemQuery(kind: .artist, ids: [id], limit: 1)
        return try await self.withClient(serverID) { try await $0.artists(query) }.items.first
    }

    /// Every album by an album artist, newest first.
    func artistAlbums(serverID: UUID, artistID: String) async throws -> [JellyfinAlbum] {
        let query = JellyfinItemQuery(
            kind: .album,
            sort: [.productionYear, .sortName],
            descending: true,
            albumArtistID: artistID
        )
        return try await self.withClient(serverID) { try await $0.albums(query) }.items
    }

    // MARK: - Lists

    /// A random selection of songs.
    func randomSongs(serverID: UUID, limit: Int = 50) async throws -> [JellyfinSong] {
        let query = JellyfinItemQuery(kind: .song, sort: [.random], limit: limit)
        return try await self.withClient(serverID) { try await $0.songs(query) }.items
    }

    /// The songs played most, most first.
    func mostPlayedSongs(serverID: UUID, limit: Int = 50) async throws -> [JellyfinSong] {
        let query = JellyfinItemQuery(kind: .song, sort: [.playCount], descending: true, limit: limit)
        return try await self.withClient(serverID) { try await $0.songs(query) }.items
    }

    /// The favourite songs, albums and artists.
    func starred(serverID: UUID) async throws -> JellyfinSearchResult {
        let client = try self.requireClient(serverID)
        async let songs = client.songs(JellyfinItemQuery(kind: .song, sort: [.sortName], favoritesOnly: true))
        async let albums = client.albums(JellyfinItemQuery(kind: .album, sort: [.sortName], favoritesOnly: true))
        async let artists = client.artists(JellyfinItemQuery(kind: .artist, favoritesOnly: true))
        return try await JellyfinSearchResult(songs: songs.items, albums: albums.items, artists: artists.items)
    }

    // MARK: - Playlists

    /// Every audio playlist the user can see, by name.
    func playlists(serverID: UUID) async throws -> [JellyfinPlaylist] {
        let query = JellyfinItemQuery(kind: .playlist, sort: [.sortName])
        return try await self.withClient(serverID) { try await $0.playlists(query) }.items
    }

    /// One page of a playlist's songs, in playlist order.
    func playlistSongs(
        serverID: UUID,
        id: String,
        startIndex: Int = 0,
        limit: Int = 100
    ) async throws -> JellyfinPage<JellyfinSong> {
        try await self.withClient(serverID) { try await $0.playlistSongs(id: id, startIndex: startIndex, limit: limit) }
    }

    // MARK: - Search

    /// Songs, albums and artists that match `query`, fetched as three parallel requests.
    func search(
        serverID: UUID,
        query: String,
        artistCount: Int = 5,
        albumCount: Int = 5,
        songCount: Int = 20
    ) async throws -> JellyfinSearchResult {
        let client = try self.requireClient(serverID)
        async let songs = client.songs(JellyfinItemQuery(kind: .song, searchTerm: query, limit: songCount))
        async let albums = client.albums(JellyfinItemQuery(kind: .album, searchTerm: query, limit: albumCount))
        async let artists = client.artists(JellyfinItemQuery(kind: .artist, searchTerm: query, limit: artistCount))
        return try await JellyfinSearchResult(songs: songs.items, albums: albums.items, artists: artists.items)
    }

    // MARK: - Favourites

    /// Sets `IsFavorite` on the item at once, with no retry and no `syncStars`
    /// check. `JellyfinAnnotations` adds both.
    func setFavorite(serverID: UUID, itemID: String, isFavorite: Bool) async throws {
        try await self.withClient(serverID) { try await $0.setFavorite(itemID: itemID, isFavorite: isFavorite) }
        self.log.debug(
            "jellyfin.favorite",
            ["server": serverID.uuidString, "item": itemID, "on": isFavorite]
        )
    }

    // MARK: - Play reports

    /// Tells the server a song has started ("now playing"), at position zero.
    func reportPlaybackStarted(serverID: UUID, itemID: String) async throws {
        try await self.withClient(serverID) { try await $0.reportPlaybackStarted(itemID: itemID) }
        self.log.debug("jellyfin.report.started", ["server": serverID.uuidString, "item": itemID])
    }

    /// Tells the server a song has stopped at `positionTicks` (100 ns ticks).
    /// A counted play sends the item's full run time, so the result does not
    /// depend on the server's resume percentages (ADR-097, D5).
    func reportPlaybackStopped(serverID: UUID, itemID: String, positionTicks: Int64) async throws {
        try await self.withClient(serverID) {
            try await $0.reportPlaybackStopped(itemID: itemID, positionTicks: positionTicks)
        }
        self.log.debug("jellyfin.report.stopped", ["server": serverID.uuidString, "item": itemID])
    }

    // MARK: - Sign out

    /// Asks the server to end this device's access token. Best effort: the
    /// failure is logged and never thrown, so it never blocks removing a server.
    func endSession(serverID: UUID) async {
        do {
            try await self.withClient(serverID) { try await $0.signOut() }
            self.log.info("jellyfin.signout.ok", ["server": serverID.uuidString])
        } catch {
            self.log.warning(
                "jellyfin.signout.failed",
                ["server": serverID.uuidString, "error": String(reflecting: error)]
            )
        }
    }

    // MARK: - Media URLs (never log these)

    /// Returns the stream URL for a song: the original file for `.original`,
    /// else a transcode to `format` capped at `bitrate`. The App's stream
    /// resolver hands it to the stream cache.
    ///
    /// > Warning: Never log this URL; it contains the access token.
    func streamURL(
        serverID: UUID,
        itemID: String,
        format: JellyfinStreamFormat = .original,
        bitrate: JellyfinBitrate = .original
    ) throws -> URL {
        try self.requireClient(serverID).streamURL(itemID: itemID, format: format, bitrate: bitrate)
    }

    /// Returns the cover-art URL for an item, or `nil` when the item has no image.
    /// `tag` is the item's image tag, which keeps a changed cover from showing stale.
    ///
    /// > Warning: Never log this URL; it contains the access token.
    func coverArtURL(serverID: UUID, itemID: String, tag: String?, size: Int? = nil) throws -> URL {
        try self.requireClient(serverID).imageURL(itemID: itemID, tag: tag, maxWidth: size)
    }
}
