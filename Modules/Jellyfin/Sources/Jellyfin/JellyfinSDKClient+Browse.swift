import Foundation
import Get
import JellyfinAPI

// The list requests. Every one carries the user id and asks for the fields the
// mappers need (`Genres`, `MediaSources`, child and item counts) so no view
// needs a second round trip.

extension JellyfinSDKClient {
    // MARK: - Lists

    func songs(_ query: JellyfinItemQuery) async throws -> JellyfinPage<JellyfinSong> {
        try await JellyfinMapping.page(self.items(query, kind: .audio), JellyfinMapping.song)
    }

    func albums(_ query: JellyfinItemQuery) async throws -> JellyfinPage<JellyfinAlbum> {
        try await JellyfinMapping.page(self.items(query, kind: .musicAlbum), JellyfinMapping.album)
    }

    func artists(_ query: JellyfinItemQuery) async throws -> JellyfinPage<JellyfinArtist> {
        let userID = try self.requireUserID()
        var parameters = Paths.GetAlbumArtistsParameters()
        parameters.userID = userID
        parameters.startIndex = query.startIndex
        parameters.limit = query.limit
        parameters.searchTerm = query.searchTerm
        parameters.isFavorite = query.favoritesOnly ? true : nil
        parameters.fields = Self.fields
        parameters.sortBy = [.sortName]
        parameters.sortOrder = [.ascending]
        parameters.enableUserData = true
        parameters.enableTotalRecordCount = true
        // The SDK marks the `getAlbumArtists` builder deprecated, but the path
        // is the documented album-artist list and the spec has no replacement
        // that keeps the "album artists only" meaning. The request is built here
        // so the call site is one line to change if the SDK moves it.
        let request = Request<BaseItemDtoQueryResult>(
            path: "/Artists/AlbumArtists",
            method: "GET",
            query: parameters.asQuery,
            id: "GetAlbumArtists"
        )
        let result = try await self.run { try await self.client.send(request).value }
        return JellyfinMapping.page(result, JellyfinMapping.artist)
    }

    func playlists(_ query: JellyfinItemQuery) async throws -> JellyfinPage<JellyfinPlaylist> {
        try await JellyfinMapping.page(self.items(query, kind: .playlist), JellyfinMapping.playlist)
    }

    func genres(startIndex: Int, limit: Int?) async throws -> JellyfinPage<JellyfinGenre> {
        let userID = try self.requireUserID()
        var parameters = Paths.GetGenresParameters()
        parameters.userID = userID
        parameters.startIndex = startIndex
        parameters.limit = limit
        // Music genres only: genres of audio items, not of films.
        parameters.includeItemTypes = [.audio]
        parameters.fields = [.itemCounts]
        parameters.sortBy = [.sortName]
        parameters.sortOrder = [.ascending]
        parameters.enableTotalRecordCount = true
        let result = try await self.run { try await self.client.send(Paths.getGenres(parameters: parameters)).value }
        return JellyfinMapping.page(result, JellyfinMapping.genre)
    }

    func playlistSongs(id: String, startIndex: Int, limit: Int?) async throws -> JellyfinPage<JellyfinSong> {
        let userID = try self.requireUserID()
        var parameters = Paths.GetPlaylistItemsParameters()
        parameters.userID = userID
        parameters.startIndex = startIndex
        parameters.limit = limit
        parameters.fields = Self.fields
        parameters.enableUserData = true
        let request = Paths.getPlaylistItems(playlistID: id, parameters: parameters)
        let result = try await self.run { try await self.client.send(request).value }
        return JellyfinMapping.page(result, JellyfinMapping.song)
    }

    // MARK: - Shared `/Items` request

    /// The fields every music list asks for beyond the defaults.
    static let fields: [ItemFields] = [.genres, .mediaSources, .childCount, .itemCounts]

    private func items(_ query: JellyfinItemQuery, kind: BaseItemKind) async throws -> BaseItemDtoQueryResult {
        let userID = try self.requireUserID()
        var parameters = Paths.GetItemsParameters()
        parameters.userID = userID
        parameters.startIndex = query.startIndex
        parameters.limit = query.limit
        parameters.isRecursive = true
        parameters.includeItemTypes = [kind]
        parameters.fields = Self.fields
        parameters.searchTerm = query.searchTerm
        parameters.parentID = query.parentID
        parameters.ids = query.ids
        parameters.isFavorite = query.favoritesOnly ? true : nil
        parameters.genreIDs = query.genreID.map { [$0] }
        parameters.albumArtistIDs = query.albumArtistID.map { [$0] }
        parameters.sortBy = query.sort.isEmpty ? nil : query.sort.map(Self.sortBy)
        parameters.sortOrder = query.sort.isEmpty ? nil : [query.descending ? .descending : .ascending]
        parameters.enableUserData = true
        parameters.enableTotalRecordCount = true
        return try await self.run { try await self.client.send(Paths.getItems(parameters: parameters)).value }
    }

    private static func sortBy(_ field: JellyfinItemQuery.SortField) -> ItemSortBy {
        switch field {
        case .sortName:
            .sortName

        case .artist:
            .artist

        case .album:
            .album

        case .albumArtist:
            .albumArtist

        case .dateCreated:
            .dateCreated

        case .playCount:
            .playCount

        case .random:
            .random

        case .productionYear:
            .productionYear

        case .discNumber:
            .parentIndexNumber

        case .trackNumber:
            .indexNumber
        }
    }
}
