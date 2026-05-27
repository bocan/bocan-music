import Foundation
import Subsonic
import SwiftSonic

// MARK: - NoopBrowseDataSource

/// No-op `SubsonicBrowseDataSource` used as a placeholder when a Subsonic
/// browse view is constructed without a real data source (e.g. in
/// previews / snapshots, or as the fallback for a `library.subsonicSearch`
/// that the @ObservedObject property requires to be non-nil). All calls
/// throw immediately so nothing partial ever surfaces.
struct NoopBrowseDataSource: SubsonicBrowseDataSource {
    struct Unavailable: Error {}
    func getArtists(serverID _: UUID) async throws -> [ArtistIndex] {
        throw Unavailable()
    }

    func getGenres(serverID _: UUID) async throws -> [Genre] {
        throw Unavailable()
    }

    func getAlbumList2(
        serverID _: UUID, type _: AlbumListType, size _: Int, offset _: Int
    ) async throws -> [AlbumID3] {
        throw Unavailable()
    }

    func getRandomSongs(serverID _: UUID, size _: Int) async throws -> [Song] {
        throw Unavailable()
    }

    func getSongsByGenre(
        serverID _: UUID, genre _: String, count _: Int, offset _: Int
    ) async throws -> [Song] {
        throw Unavailable()
    }

    func getArtist(serverID _: UUID, id _: String) async throws -> ArtistID3 {
        throw Unavailable()
    }

    func getAlbum(serverID _: UUID, id _: String) async throws -> AlbumID3 {
        throw Unavailable()
    }

    func getPlaylists(serverID _: UUID) async throws -> [Playlist] {
        throw Unavailable()
    }

    func getPlaylist(serverID _: UUID, id _: String) async throws -> PlaylistWithSongs {
        throw Unavailable()
    }

    func getStarred2(serverID _: UUID) async throws -> Starred2 {
        throw Unavailable()
    }

    func getPodcasts(serverID _: UUID) async throws -> [PodcastChannel] {
        throw Unavailable()
    }

    func getInternetRadioStations(serverID _: UUID) async throws -> [InternetRadioStation] {
        throw Unavailable()
    }

    func getBookmarks(serverID _: UUID) async throws -> [Bookmark] {
        throw Unavailable()
    }

    func search3(
        serverID _: UUID,
        query _: String,
        artistCount _: Int,
        albumCount _: Int,
        songCount _: Int
    ) async throws -> SearchResult3 {
        throw Unavailable()
    }
}
