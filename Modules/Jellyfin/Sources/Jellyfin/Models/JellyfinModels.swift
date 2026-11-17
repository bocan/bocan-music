import Foundation

// The value types the UI and the App see. They are plain, `Sendable` and
// `Hashable`. IDs are opaque strings and are never parsed or reformatted. A
// mapper never invents a value: a field the server did not send is `nil`.

// MARK: - JellyfinSong

/// One music track.
public struct JellyfinSong: Sendable, Hashable, Identifiable, Codable {
    public let id: String
    public var title: String
    public var artistName: String?
    public var artistID: String?
    public var albumTitle: String?
    public var albumID: String?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var year: Int?
    public var genre: String?
    /// `RunTimeTicks` divided by 10 000 000.
    public var durationSeconds: Double?
    public var bitrateKbps: Int?
    public var container: String?
    /// Id of the item that owns the cover image (the song or its album).
    public var coverArtID: String?
    /// The image tag of that item. It goes in the image URL so a changed cover does not show stale.
    public var coverArtTag: String?
    public var isStarred: Bool

    public init(
        id: String,
        title: String,
        artistName: String? = nil,
        artistID: String? = nil,
        albumTitle: String? = nil,
        albumID: String? = nil,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        year: Int? = nil,
        genre: String? = nil,
        durationSeconds: Double? = nil,
        bitrateKbps: Int? = nil,
        container: String? = nil,
        coverArtID: String? = nil,
        coverArtTag: String? = nil,
        isStarred: Bool = false
    ) {
        self.id = id
        self.title = title
        self.artistName = artistName
        self.artistID = artistID
        self.albumTitle = albumTitle
        self.albumID = albumID
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.year = year
        self.genre = genre
        self.durationSeconds = durationSeconds
        self.bitrateKbps = bitrateKbps
        self.container = container
        self.coverArtID = coverArtID
        self.coverArtTag = coverArtTag
        self.isStarred = isStarred
    }
}

// MARK: - JellyfinAlbum

/// One music album.
public struct JellyfinAlbum: Sendable, Hashable, Identifiable, Codable {
    public let id: String
    public var title: String
    public var artistName: String?
    public var artistID: String?
    public var year: Int?
    public var genre: String?
    public var songCount: Int?
    public var durationSeconds: Double?
    public var coverArtID: String?
    public var coverArtTag: String?
    public var isStarred: Bool

    public init(
        id: String,
        title: String,
        artistName: String? = nil,
        artistID: String? = nil,
        year: Int? = nil,
        genre: String? = nil,
        songCount: Int? = nil,
        durationSeconds: Double? = nil,
        coverArtID: String? = nil,
        coverArtTag: String? = nil,
        isStarred: Bool = false
    ) {
        self.id = id
        self.title = title
        self.artistName = artistName
        self.artistID = artistID
        self.year = year
        self.genre = genre
        self.songCount = songCount
        self.durationSeconds = durationSeconds
        self.coverArtID = coverArtID
        self.coverArtTag = coverArtTag
        self.isStarred = isStarred
    }
}

// MARK: - JellyfinArtist

/// One artist.
public struct JellyfinArtist: Sendable, Hashable, Identifiable, Codable {
    public let id: String
    public var name: String
    public var albumCount: Int?
    public var coverArtID: String?
    public var coverArtTag: String?
    public var isStarred: Bool

    public init(
        id: String,
        name: String,
        albumCount: Int? = nil,
        coverArtID: String? = nil,
        coverArtTag: String? = nil,
        isStarred: Bool = false
    ) {
        self.id = id
        self.name = name
        self.albumCount = albumCount
        self.coverArtID = coverArtID
        self.coverArtTag = coverArtTag
        self.isStarred = isStarred
    }
}

// MARK: - JellyfinGenre

/// One music genre.
public struct JellyfinGenre: Sendable, Hashable, Identifiable, Codable {
    public let id: String
    public var name: String
    public var songCount: Int?
    public var albumCount: Int?

    public init(id: String, name: String, songCount: Int? = nil, albumCount: Int? = nil) {
        self.id = id
        self.name = name
        self.songCount = songCount
        self.albumCount = albumCount
    }
}

// MARK: - JellyfinPlaylist

/// One audio playlist.
public struct JellyfinPlaylist: Sendable, Hashable, Identifiable, Codable {
    public let id: String
    public var name: String
    public var songCount: Int?
    public var durationSeconds: Double?
    public var coverArtID: String?
    public var coverArtTag: String?

    public init(
        id: String,
        name: String,
        songCount: Int? = nil,
        durationSeconds: Double? = nil,
        coverArtID: String? = nil,
        coverArtTag: String? = nil
    ) {
        self.id = id
        self.name = name
        self.songCount = songCount
        self.durationSeconds = durationSeconds
        self.coverArtID = coverArtID
        self.coverArtTag = coverArtTag
    }
}

// MARK: - JellyfinSearchResult

/// Songs, albums and artists that match a search term, or that are favourites.
public struct JellyfinSearchResult: Sendable, Hashable {
    public var songs: [JellyfinSong]
    public var albums: [JellyfinAlbum]
    public var artists: [JellyfinArtist]

    public init(songs: [JellyfinSong] = [], albums: [JellyfinAlbum] = [], artists: [JellyfinArtist] = []) {
        self.songs = songs
        self.albums = albums
        self.artists = artists
    }

    public var isEmpty: Bool {
        self.songs.isEmpty && self.albums.isEmpty && self.artists.isEmpty
    }
}

// MARK: - JellyfinPage

/// One page of a list. `total` is the server's `TotalRecordCount`, or `nil` if it did not say.
public struct JellyfinPage<Element: Sendable>: Sendable {
    public var items: [Element]
    public var total: Int?

    public init(items: [Element], total: Int? = nil) {
        self.items = items
        self.total = total
    }
}

extension JellyfinPage: Equatable where Element: Equatable {}
extension JellyfinPage: Hashable where Element: Hashable {}

// MARK: - JellyfinAlbumList

/// Which ordering of albums a browse view asks for.
public enum JellyfinAlbumList: Sendable, Hashable {
    /// By title.
    case alphabetical
    /// Newest first, by date added to the library.
    case recentlyAdded
}

// MARK: - JellyfinServerInfo

/// What "Test server" shows: the answer of the public info endpoint.
public struct JellyfinServerInfo: Sendable, Hashable {
    public var serverName: String?
    public var version: String?
    /// The server's own id. Not the local server UUID.
    public var serverID: String?

    public init(serverName: String? = nil, version: String? = nil, serverID: String? = nil) {
        self.serverName = serverName
        self.version = version
        self.serverID = serverID
    }
}

// MARK: - JellyfinSession

/// The result of a sign-in: who signed in, and the token to store.
///
/// The token is `internal` on purpose: only `JellyfinServerStore` takes it, and
/// it goes straight to the Keychain.
public struct JellyfinSession: Sendable {
    public let userID: String
    public let username: String
    let accessToken: String

    /// Creates a session. Only a sign-in makes one in the app; the initialiser is
    /// public so a test double for `JellyfinAuthenticating` can return one.
    public init(userID: String, username: String, accessToken: String) {
        self.userID = userID
        self.username = username
        self.accessToken = accessToken
    }
}

// MARK: - JellyfinQuickConnectEvent

/// One step of a Quick Connect sign-in.
public enum JellyfinQuickConnectEvent: Sendable {
    /// The server made a code. Show it; the user approves it in another signed-in session.
    case waiting(code: String)
    /// The code was approved. The session is ready to store.
    case approved(JellyfinSession)
}

/// The timing of a Quick Connect poll. The defaults are the SDK's: every 5 s,
/// at most 200 times, which is a little under 17 minutes.
public struct JellyfinQuickConnectPolicy: Sendable, Equatable {
    public var interval: Duration
    public var maxPolls: Int
    /// How many poll requests in a row may fail before the sign-in is abandoned.
    public var failureTolerance: Int

    public init(interval: Duration = .seconds(5), maxPolls: Int = 200, failureTolerance: Int = 5) {
        self.interval = interval
        self.maxPolls = maxPolls
        self.failureTolerance = failureTolerance
    }
}
