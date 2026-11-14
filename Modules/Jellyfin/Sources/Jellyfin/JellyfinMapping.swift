import Foundation
import Get
import JellyfinAPI

// Maps SDK items to the module's own models. A mapper never invents a value:
// a field the server did not send stays `nil`. Ids are copied as the server
// sent them, never parsed, re-cased or reformatted.

// MARK: - JellyfinMapping

enum JellyfinMapping {
    /// Jellyfin counts time in 100 ns ticks.
    static let ticksPerSecond: Double = 10_000_000

    // MARK: Ticks

    /// Ticks to seconds, or `nil` if the server sent none.
    static func seconds(fromTicks ticks: Int?) -> Double? {
        ticks.map { Double($0) / self.ticksPerSecond }
    }

    /// Seconds to ticks. Negative or non-finite input gives 0.
    static func ticks(fromSeconds seconds: Double) -> Int64 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int64((seconds * self.ticksPerSecond).rounded())
    }

    // MARK: Cover art

    /// The item that owns the cover image, and the image tag to put in the URL.
    ///
    /// A song with no image of its own uses its album's (`AlbumId`), because the
    /// song id is not the id of the item that holds the picture.
    static func cover(of item: BaseItemDto) -> (id: String?, tag: String?) {
        if let id = item.id, let tag = item.imageTags?["Primary"] {
            return (id, tag)
        }
        if let albumID = item.albumID, let tag = item.albumPrimaryImageTag {
            return (albumID, tag)
        }
        if let parentID = item.parentPrimaryImageItemID, let tag = item.parentPrimaryImageTag {
            return (parentID, tag)
        }
        return (nil, nil)
    }

    // MARK: Items

    static func song(_ item: BaseItemDto) -> JellyfinSong? {
        guard let id = item.id else { return nil }
        let cover = self.cover(of: item)
        let source = item.mediaSources?.first
        return JellyfinSong(
            id: id,
            title: item.name ?? "",
            artistName: item.artists?.first ?? item.albumArtist,
            artistID: item.artistItems?.first?.id,
            albumTitle: item.album,
            albumID: item.albumID,
            trackNumber: item.indexNumber,
            discNumber: item.parentIndexNumber,
            year: item.productionYear,
            genre: item.genres?.first,
            durationSeconds: self.seconds(fromTicks: item.runTimeTicks),
            bitrateKbps: source?.bitrate.map { $0 / 1000 },
            container: item.container ?? source?.container,
            coverArtID: cover.id,
            coverArtTag: cover.tag,
            isStarred: item.userData?.isFavorite ?? false
        )
    }

    static func album(_ item: BaseItemDto) -> JellyfinAlbum? {
        guard let id = item.id else { return nil }
        let cover = self.cover(of: item)
        return JellyfinAlbum(
            id: id,
            title: item.name ?? "",
            artistName: item.albumArtist ?? item.albumArtists?.first?.name,
            artistID: item.albumArtists?.first?.id,
            year: item.productionYear,
            genre: item.genres?.first,
            songCount: item.childCount ?? item.songCount,
            durationSeconds: self.seconds(fromTicks: item.runTimeTicks),
            coverArtID: cover.id,
            coverArtTag: cover.tag,
            isStarred: item.userData?.isFavorite ?? false
        )
    }

    static func artist(_ item: BaseItemDto) -> JellyfinArtist? {
        guard let id = item.id else { return nil }
        let cover = self.cover(of: item)
        return JellyfinArtist(
            id: id,
            name: item.name ?? "",
            albumCount: item.albumCount,
            coverArtID: cover.id,
            coverArtTag: cover.tag,
            isStarred: item.userData?.isFavorite ?? false
        )
    }

    static func genre(_ item: BaseItemDto) -> JellyfinGenre? {
        guard let id = item.id, let name = item.name else { return nil }
        return JellyfinGenre(id: id, name: name, songCount: item.songCount, albumCount: item.albumCount)
    }

    static func playlist(_ item: BaseItemDto) -> JellyfinPlaylist? {
        guard let id = item.id else { return nil }
        let cover = self.cover(of: item)
        return JellyfinPlaylist(
            id: id,
            name: item.name ?? "",
            songCount: item.childCount ?? item.songCount,
            durationSeconds: self.seconds(fromTicks: item.runTimeTicks),
            coverArtID: cover.id,
            coverArtTag: cover.tag
        )
    }

    // MARK: Pages

    /// Maps a query result. An item without an id is dropped, since nothing can address it.
    static func page<Element: Sendable>(
        _ result: BaseItemDtoQueryResult,
        _ map: (BaseItemDto) -> Element?
    ) -> JellyfinPage<Element> {
        JellyfinPage(items: (result.items ?? []).compactMap(map), total: result.totalRecordCount)
    }

    // MARK: Server info

    static func serverInfo(_ info: PublicSystemInfo) -> JellyfinServerInfo {
        JellyfinServerInfo(serverName: info.serverName, version: info.version, serverID: info.id)
    }

    // MARK: Errors

    /// Wraps whatever the SDK or the network threw. Never keeps a URL or a token.
    static func error(from error: any Error) -> JellyfinError {
        if let known = error as? JellyfinError {
            return known
        }
        if let urlError = error as? URLError {
            return .network(self.describe(urlError))
        }
        if let client = error as? JellyfinClient.ClientError, client == .noAccessToken {
            return .noAccessToken
        }
        if let api = error as? APIError, case let .unacceptableStatusCode(status) = api {
            return status == 401 ? .unauthorized : .http(status: status)
        }
        if error is DecodingError {
            return .decoding("the response did not match the expected shape")
        }
        return .network(String(describing: type(of: error)))
    }

    /// A short, URL-free description of a transport failure.
    private static func describe(_ error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet:
            "no network connection"

        case .timedOut:
            "the request timed out"

        case .cannotFindHost, .dnsLookupFailed:
            "the host name was not found"

        case .cannotConnectToHost:
            "could not connect to the server"

        case .networkConnectionLost:
            "the connection was lost"

        case .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
             .secureConnectionFailed:
            "the secure connection failed"

        default:
            "the request failed (code \(error.code.rawValue))"
        }
    }
}
