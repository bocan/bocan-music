import Foundation
import SwiftSonic

/// The endpoint methods of `SubsonicService`: browsing, lists, playlists,
/// search, the capability-gated sections, annotations, scrobble and media URLs.
public extension SubsonicService {
    // MARK: - Browsing

    // Every endpoint method below throws `SubsonicError.unknownServer` when
    // `serverID` has no client, and `SubsonicError.transport` when the request
    // fails.

    /// Calls the server's `getArtists` endpoint.
    func getArtists(serverID: UUID) async throws -> [ArtistIndex] {
        try await self.withClient(serverID) { try await $0.getArtists() }
    }

    /// Calls `getArtist` for the artist with the server-side ID `id`.
    func getArtist(serverID: UUID, id: String) async throws -> ArtistID3 {
        try await self.withClient(serverID) { try await $0.getArtist(id: id) }
    }

    /// Calls `getAlbum` for the album with the server-side ID `id`.
    func getAlbum(serverID: UUID, id: String) async throws -> AlbumID3 {
        try await self.withClient(serverID) { try await $0.getAlbum(id: id) }
    }

    /// Calls the server's `getGenres` endpoint.
    func getGenres(serverID: UUID) async throws -> [Genre] {
        try await self.withClient(serverID) { try await $0.getGenres() }
    }

    // MARK: - Lists

    /// Calls `getAlbumList2`: one page of at most `size` albums of the list
    /// `type`, starting at `offset`.
    func getAlbumList2(
        serverID: UUID,
        type: AlbumListType,
        size: Int = 50,
        offset: Int = 0
    ) async throws -> [AlbumID3] {
        try await self.withClient(serverID) { try await $0.getAlbumList2(type: type, size: size, offset: offset) }
    }

    /// Calls `getRandomSongs`, asking for at most `size` songs.
    func getRandomSongs(serverID: UUID, size: Int = 50) async throws -> [Song] {
        try await self.withClient(serverID) { try await $0.getRandomSongs(size: size) }
    }

    /// Calls `getSongsByGenre`: one page of at most `count` songs in `genre`,
    /// starting at `offset`.
    func getSongsByGenre(
        serverID: UUID,
        genre: String,
        count: Int = 50,
        offset: Int = 0
    ) async throws -> [Song] {
        try await self.withClient(serverID) { try await $0.getSongsByGenre(genre, count: count, offset: offset) }
    }

    /// Calls the server's `getStarred2` endpoint.
    func getStarred2(serverID: UUID) async throws -> Starred2 {
        try await self.withClient(serverID) { try await $0.getStarred2() }
    }

    // MARK: - Playlists

    /// Calls the server's `getPlaylists` endpoint.
    func getPlaylists(serverID: UUID) async throws -> [Playlist] {
        try await self.withClient(serverID) { try await $0.getPlaylists() }
    }

    /// Calls `getPlaylist` for the playlist with the server-side ID `id`.
    func getPlaylist(serverID: UUID, id: String) async throws -> PlaylistWithSongs {
        try await self.withClient(serverID) { try await $0.getPlaylist(id: id) }
    }

    // MARK: - Search

    /// Calls `search3` with `query`. The three counts cap how many artists,
    /// albums and songs the request asks for.
    func search3(
        serverID: UUID,
        query: String,
        artistCount: Int = 5,
        albumCount: Int = 5,
        songCount: Int = 20
    ) async throws -> SearchResult3 {
        try await self.withClient(serverID) {
            try await $0.search3(
                query,
                artistCount: artistCount,
                albumCount: albumCount,
                songCount: songCount
            )
        }
    }

    // MARK: - Podcasts (capability-gated)

    /// Calls `getPodcasts`. A 404, 501 or API "not found" answer also revokes
    /// the server's `podcasts` capability before the error is thrown.
    func getPodcasts(serverID: UUID) async throws -> [PodcastChannel] {
        try await self.withCapabilityGatedClient(serverID, feature: "podcasts") { try await $0.getPodcasts() }
    }

    // MARK: - Internet radio (capability-gated)

    /// Calls `getInternetRadioStations`. A 404, 501 or API "not found" answer
    /// also revokes the server's `internetRadio` capability before the error is thrown.
    func getInternetRadioStations(serverID: UUID) async throws -> [InternetRadioStation] {
        try await self.withCapabilityGatedClient(serverID, feature: "internetRadio") {
            try await $0.getInternetRadioStations()
        }
    }

    // MARK: - Bookmarks (capability-gated)

    /// Calls `getBookmarks`. A 404, 501 or API "not found" answer also revokes
    /// the server's `bookmarks` capability before the error is thrown.
    func getBookmarks(serverID: UUID) async throws -> [Bookmark] {
        try await self.withCapabilityGatedClient(serverID, feature: "bookmarks") { try await $0.getBookmarks() }
    }

    // MARK: - Now Playing

    /// Calls the server's `getNowPlaying` endpoint.
    func getNowPlaying(serverID: UUID) async throws -> [NowPlayingEntry] {
        try await self.withClient(serverID) { try await $0.getNowPlaying() }
    }

    // MARK: - Annotations

    /// Stars the song on the server at once, with no retry and no `syncStars`
    /// check. `SubsonicAnnotations` adds both.
    func star(serverID: UUID, songID: String) async throws {
        try await self.withClient(serverID) { client in
            try await client.star(songId: songID)
            self.log.debug("subsonic.star", ["server": serverID.uuidString, "song": songID])
        }
    }

    /// Removes the star from the song on the server at once, with no retry
    /// and no `syncStars` check. `SubsonicAnnotations` adds both.
    func unstar(serverID: UUID, songID: String) async throws {
        try await self.withClient(serverID) { client in
            try await client.unstar(songId: songID)
            self.log.debug("subsonic.unstar", ["server": serverID.uuidString, "song": songID])
        }
    }

    /// Sends `rating` for the song to the server's `setRating` endpoint at
    /// once, with no retry and no `syncRatings` check. `SubsonicAnnotations` adds both.
    func setRating(serverID: UUID, songID: String, rating: Int) async throws {
        try await self.withClient(serverID) { client in
            try await client.setRating(id: songID, rating: rating)
            self.log.debug(
                "subsonic.rating",
                ["server": serverID.uuidString, "song": songID, "rating": rating]
            )
        }
    }

    // MARK: - Scrobble

    /// Calls the server's `scrobble` endpoint for the song. `submission` is
    /// passed through as the endpoint's `submission` parameter.
    func scrobble(serverID: UUID, songID: String, submission: Bool = true) async throws {
        try await self.withClient(serverID) { client in
            try await client.scrobble(id: songID, submission: submission)
            self.log.debug(
                "subsonic.scrobble",
                ["server": serverID.uuidString, "song": songID, "submission": submission]
            )
        }
    }

    // MARK: - Media URLs (nonisolated passthrough; never log these)

    /// Returns the stream URL for a song.
    ///
    /// > Warning: Never log this URL; it contains the per-request auth token.
    func streamURL(
        serverID: UUID,
        songID: String,
        maxBitRate: Int? = nil,
        format: String? = nil
    ) throws -> URL {
        let client = try self.requireClient(serverID)
        guard let url = client.streamURL(id: songID, maxBitRate: maxBitRate, format: format) else {
            throw SubsonicError.invalidServerRecord("streamURL returned nil for song \(songID)")
        }
        return url
    }

    /// Returns the cover-art URL for an entity.
    func coverArtURL(serverID: UUID, entityID: String, size: Int? = nil) throws -> URL? {
        let client = try self.requireClient(serverID)
        return client.coverArtURL(id: entityID, size: size)
    }
}
