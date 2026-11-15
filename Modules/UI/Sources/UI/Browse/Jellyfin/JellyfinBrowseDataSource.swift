import Foundation
import Jellyfin

// MARK: - JellyfinBrowseDataSource

/// The narrow protocol the per-server Jellyfin browse view models depend on
/// (ADR-097, slice 4). It lets a test substitute a deterministic in-memory
/// double for the real `JellyfinService` actor. It is the twin of
/// `SubsonicBrowseDataSource`, in Jellyfin's own terms: pages use `StartIndex`
/// and `Limit`, and every list comes back as the module's own models.
public protocol JellyfinBrowseDataSource: Sendable {
    func songs(serverID: UUID, startIndex: Int, limit: Int) async throws -> JellyfinPage<JellyfinSong>
    func albums(
        serverID: UUID,
        list: JellyfinAlbumList,
        startIndex: Int,
        limit: Int
    ) async throws -> JellyfinPage<JellyfinAlbum>
    func artists(serverID: UUID, startIndex: Int, limit: Int) async throws -> JellyfinPage<JellyfinArtist>
    func genres(serverID: UUID, startIndex: Int, limit: Int) async throws -> JellyfinPage<JellyfinGenre>
    func songsByGenre(
        serverID: UUID,
        genreID: String,
        startIndex: Int,
        limit: Int
    ) async throws -> JellyfinPage<JellyfinSong>
    func album(serverID: UUID, id: String) async throws -> JellyfinAlbum?
    func albumSongs(serverID: UUID, albumID: String) async throws -> [JellyfinSong]
    func artist(serverID: UUID, id: String) async throws -> JellyfinArtist?
    func artistAlbums(serverID: UUID, artistID: String) async throws -> [JellyfinAlbum]
    func randomSongs(serverID: UUID, limit: Int) async throws -> [JellyfinSong]
    func mostPlayedSongs(serverID: UUID, limit: Int) async throws -> [JellyfinSong]
    func starred(serverID: UUID) async throws -> JellyfinSearchResult
    func playlists(serverID: UUID) async throws -> [JellyfinPlaylist]
    func playlistSongs(
        serverID: UUID,
        id: String,
        startIndex: Int,
        limit: Int
    ) async throws -> JellyfinPage<JellyfinSong>
    func search(
        serverID: UUID,
        query: String,
        artistCount: Int,
        albumCount: Int,
        songCount: Int
    ) async throws -> JellyfinSearchResult
}

// MARK: - JellyfinService conformance

extension JellyfinService: JellyfinBrowseDataSource {}

// MARK: - JellyfinBrowseError

/// Failures that start in the UI-side Jellyfin browse layer, as opposed to
/// `JellyfinError`, which the `Jellyfin` module throws for transport, Keychain
/// and API failures. Neither case reaches the user as text: a server that timed
/// out is listed by name in the search chrome, and the placeholder data source
/// only backs previews and snapshots.
enum JellyfinBrowseError: Error, Sendable {
    /// A browse view was built without a real data source, so there is no server to ask.
    case dataSourceUnavailable

    /// One server did not answer a multi-source search within the per-server
    /// deadline. The other servers' results still show.
    case searchTimedOut(serverID: UUID, after: Duration)
}

// MARK: - NoopJellyfinBrowseDataSource

/// Placeholder used when a Jellyfin browse view is built without a real data
/// source (previews, snapshots). Every call throws at once, so nothing partial
/// ever shows.
struct NoopJellyfinBrowseDataSource: JellyfinBrowseDataSource {
    func songs(serverID _: UUID, startIndex _: Int, limit _: Int) async throws -> JellyfinPage<JellyfinSong> {
        throw JellyfinBrowseError.dataSourceUnavailable
    }

    func albums(
        serverID _: UUID,
        list _: JellyfinAlbumList,
        startIndex _: Int,
        limit _: Int
    ) async throws -> JellyfinPage<JellyfinAlbum> {
        throw JellyfinBrowseError.dataSourceUnavailable
    }

    func artists(serverID _: UUID, startIndex _: Int, limit _: Int) async throws -> JellyfinPage<JellyfinArtist> {
        throw JellyfinBrowseError.dataSourceUnavailable
    }

    func genres(serverID _: UUID, startIndex _: Int, limit _: Int) async throws -> JellyfinPage<JellyfinGenre> {
        throw JellyfinBrowseError.dataSourceUnavailable
    }

    func songsByGenre(
        serverID _: UUID,
        genreID _: String,
        startIndex _: Int,
        limit _: Int
    ) async throws -> JellyfinPage<JellyfinSong> {
        throw JellyfinBrowseError.dataSourceUnavailable
    }

    func album(serverID _: UUID, id _: String) async throws -> JellyfinAlbum? {
        throw JellyfinBrowseError.dataSourceUnavailable
    }

    func albumSongs(serverID _: UUID, albumID _: String) async throws -> [JellyfinSong] {
        throw JellyfinBrowseError.dataSourceUnavailable
    }

    func artist(serverID _: UUID, id _: String) async throws -> JellyfinArtist? {
        throw JellyfinBrowseError.dataSourceUnavailable
    }

    func artistAlbums(serverID _: UUID, artistID _: String) async throws -> [JellyfinAlbum] {
        throw JellyfinBrowseError.dataSourceUnavailable
    }

    func randomSongs(serverID _: UUID, limit _: Int) async throws -> [JellyfinSong] {
        throw JellyfinBrowseError.dataSourceUnavailable
    }

    func mostPlayedSongs(serverID _: UUID, limit _: Int) async throws -> [JellyfinSong] {
        throw JellyfinBrowseError.dataSourceUnavailable
    }

    func starred(serverID _: UUID) async throws -> JellyfinSearchResult {
        throw JellyfinBrowseError.dataSourceUnavailable
    }

    func playlists(serverID _: UUID) async throws -> [JellyfinPlaylist] {
        throw JellyfinBrowseError.dataSourceUnavailable
    }

    func playlistSongs(
        serverID _: UUID,
        id _: String,
        startIndex _: Int,
        limit _: Int
    ) async throws -> JellyfinPage<JellyfinSong> {
        throw JellyfinBrowseError.dataSourceUnavailable
    }

    func search(
        serverID _: UUID,
        query _: String,
        artistCount _: Int,
        albumCount _: Int,
        songCount _: Int
    ) async throws -> JellyfinSearchResult {
        throw JellyfinBrowseError.dataSourceUnavailable
    }
}
