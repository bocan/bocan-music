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
    func getArtists(serverID _: UUID) async throws -> [ArtistIndex] {
        throw SubsonicBrowseError.dataSourceUnavailable
    }

    func getGenres(serverID _: UUID) async throws -> [Genre] {
        throw SubsonicBrowseError.dataSourceUnavailable
    }

    func getAlbumList2(
        serverID _: UUID, type _: AlbumListType, size _: Int, offset _: Int
    ) async throws -> [AlbumID3] {
        throw SubsonicBrowseError.dataSourceUnavailable
    }

    func getRandomSongs(serverID _: UUID, size _: Int) async throws -> [Song] {
        throw SubsonicBrowseError.dataSourceUnavailable
    }

    func getSongsByGenre(
        serverID _: UUID, genre _: String, count _: Int, offset _: Int
    ) async throws -> [Song] {
        throw SubsonicBrowseError.dataSourceUnavailable
    }

    func getArtist(serverID _: UUID, id _: String) async throws -> ArtistID3 {
        throw SubsonicBrowseError.dataSourceUnavailable
    }

    func getAlbum(serverID _: UUID, id _: String) async throws -> AlbumID3 {
        throw SubsonicBrowseError.dataSourceUnavailable
    }

    func getPlaylists(serverID _: UUID) async throws -> [Playlist] {
        throw SubsonicBrowseError.dataSourceUnavailable
    }

    func getPlaylist(serverID _: UUID, id _: String) async throws -> PlaylistWithSongs {
        throw SubsonicBrowseError.dataSourceUnavailable
    }

    func getStarred2(serverID _: UUID) async throws -> Starred2 {
        throw SubsonicBrowseError.dataSourceUnavailable
    }

    func getPodcasts(serverID _: UUID) async throws -> [PodcastChannel] {
        throw SubsonicBrowseError.dataSourceUnavailable
    }

    func getInternetRadioStations(serverID _: UUID) async throws -> [InternetRadioStation] {
        throw SubsonicBrowseError.dataSourceUnavailable
    }

    func getBookmarks(serverID _: UUID) async throws -> [Bookmark] {
        throw SubsonicBrowseError.dataSourceUnavailable
    }

    func search3(
        serverID _: UUID,
        query _: String,
        artistCount _: Int,
        albumCount _: Int,
        songCount _: Int
    ) async throws -> SearchResult3 {
        throw SubsonicBrowseError.dataSourceUnavailable
    }
}
