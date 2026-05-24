import Foundation
import Subsonic
import SwiftSonic

// MARK: - SubsonicBrowseDataSource

/// Narrow protocol the Phase 19 step 10 per-server browse view-models depend
/// on. Lets tests substitute a deterministic in-memory stub for the real
/// `SubsonicService` actor without standing up a SwiftSonic client.
public protocol SubsonicBrowseDataSource: Sendable {
    func getArtists(serverID: UUID) async throws -> [ArtistIndex]
    func getGenres(serverID: UUID) async throws -> [Genre]
    func getAlbumList2(
        serverID: UUID,
        type: AlbumListType,
        size: Int,
        offset: Int
    ) async throws -> [AlbumID3]
    func getRandomSongs(serverID: UUID, size: Int) async throws -> [Song]
    func getSongsByGenre(
        serverID: UUID,
        genre: String,
        count: Int,
        offset: Int
    ) async throws -> [Song]
    func getArtist(serverID: UUID, id: String) async throws -> ArtistID3
    func getAlbum(serverID: UUID, id: String) async throws -> AlbumID3

    // Phase 19 step 11 — optional per-server destinations.
    func getPlaylists(serverID: UUID) async throws -> [Playlist]
    func getPlaylist(serverID: UUID, id: String) async throws -> PlaylistWithSongs
    func getStarred2(serverID: UUID) async throws -> Starred2
    func getPodcasts(serverID: UUID) async throws -> [PodcastChannel]
    func getInternetRadioStations(serverID: UUID) async throws -> [InternetRadioStation]
    func getBookmarks(serverID: UUID) async throws -> [Bookmark]
}

// MARK: - SubsonicService conformance

extension SubsonicService: SubsonicBrowseDataSource {}
