import Foundation

// The seam the `Jellyfin` module is written against (ADR-097, D6).
//
// `JellyfinService` and `JellyfinAuth` talk to these protocols only. The one
// implementation, `JellyfinSDKClient`, wraps the Jellyfin SDK and is the only
// file group that imports it, so a thin hand-written client can replace the
// SDK without touching anything above this line, and tests use a stub.

// MARK: - JellyfinClientIdentity

/// What the client tells the server about itself.
///
/// Every value goes into the `Authorization` header, so every value must be
/// plain ASCII with no `,`, `=` or `"`. The SDK builds that header from a
/// dictionary, without quotes and in a different field order on each request,
/// and CFNetwork cuts a header off at its first non-ASCII byte. A computer name
/// such as "Chris’s MacBook Pro" (U+2019) therefore dropped whichever fields
/// happened to follow it, the token included: about half of all requests got a
/// 401, and the monitor took the first one as a revoked sign-in. See
/// docs/GOTCHAS.md, "Jellyfin (ADR-097)".
struct JellyfinClientIdentity: Sendable, Equatable {
    /// ASCII app name, shown on the server's Devices page. Always "Bocan".
    var client: String
    /// The Mac's computer name, made header-safe. It goes only to the server the user chose.
    var deviceName: String
    /// The app version, from the bundle, made header-safe.
    var version: String

    static func current(bundle: Bundle = .main) -> Self {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return Self(
            client: JellyfinService.clientName,
            deviceName: Self.headerSafe(Host.current().localizedName ?? ProcessInfo.processInfo.hostName, fallback: "Mac"),
            version: Self.headerSafe(version ?? "0", fallback: "0")
        )
    }

    /// `text` as a value the SDK can put in its unquoted `Authorization` header:
    /// letters with accents or typographic punctuation become their plain ASCII
    /// form ("’" becomes "'", "é" becomes "e"), anything still outside printable
    /// ASCII is dropped, and so are `,`, `=` and `"`, which would end the field
    /// early. Runs of spaces collapse to one. An empty result gives `fallback`.
    static func headerSafe(_ text: String, fallback: String) -> String {
        let latin = text.applyingTransform(StringTransform("Any-Latin; Latin-ASCII"), reverse: false) ?? text
        let kept = latin.unicodeScalars.filter { scalar in
            scalar.value >= 0x20 && scalar.value < 0x7F && !",=\"".unicodeScalars.contains(scalar)
        }
        let collapsed = String(String.UnicodeScalarView(kept))
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        return collapsed.isEmpty ? fallback : collapsed
    }
}

// MARK: - JellyfinClientConfiguration

/// Everything needed to build a client for one server.
struct JellyfinClientConfiguration: Sendable {
    var serverURL: URL
    var deviceID: String
    var identity: JellyfinClientIdentity
    var allowSelfSignedTLS: Bool
    /// The signed-in user. `nil` for a client that has not signed in yet.
    var userID: String?
    /// The access token. `nil` for a client that has not signed in yet.
    var accessToken: String?
}

// MARK: - JellyfinItemQuery

/// One list request, in the module's own terms. `JellyfinSDKClient` turns it
/// into an `/Items` request.
struct JellyfinItemQuery: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case song, album, artist, playlist
    }

    enum SortField: Sendable, Equatable {
        case sortName, artist, album, albumArtist, dateCreated, playCount, random, productionYear
        case discNumber, trackNumber
    }

    var kind: Kind
    var sort: [SortField] = []
    var descending = false
    var favoritesOnly = false
    /// Restrict to items in this genre (a genre item id).
    var genreID: String?
    /// Restrict to the children of this item (the songs of an album).
    var parentID: String?
    /// Restrict albums or songs to this album artist.
    var albumArtistID: String?
    /// Fetch exactly these items.
    var ids: [String]?
    var searchTerm: String?
    var startIndex = 0
    var limit: Int?
}

// MARK: - JellyfinClientProtocol

/// A signed-in client for one server.
protocol JellyfinClientProtocol: Sendable {
    // MARK: System

    /// An authenticated round trip (`GET /Users/Me`), not `/System/Ping`: the
    /// ping endpoint needs no token, so it could never notice a revoked one.
    func ping() async throws
    func serverInfo() async throws -> JellyfinServerInfo

    // MARK: Browsing

    func songs(_ query: JellyfinItemQuery) async throws -> JellyfinPage<JellyfinSong>
    func albums(_ query: JellyfinItemQuery) async throws -> JellyfinPage<JellyfinAlbum>
    func artists(_ query: JellyfinItemQuery) async throws -> JellyfinPage<JellyfinArtist>
    func playlists(_ query: JellyfinItemQuery) async throws -> JellyfinPage<JellyfinPlaylist>
    func genres(startIndex: Int, limit: Int?) async throws -> JellyfinPage<JellyfinGenre>
    func playlistSongs(id: String, startIndex: Int, limit: Int?) async throws -> JellyfinPage<JellyfinSong>

    // MARK: Writes

    func setFavorite(itemID: String, isFavorite: Bool) async throws
    func reportPlaybackStarted(itemID: String) async throws
    func reportPlaybackStopped(itemID: String, positionTicks: Int64) async throws
    /// Asks the server to end this access token. Best effort.
    func signOut() async throws

    // MARK: URLs (never log these; they carry the access token)

    func streamURL(itemID: String, format: JellyfinStreamFormat, bitrate: JellyfinBitrate) throws -> URL
    func imageURL(itemID: String, tag: String?, maxWidth: Int?) throws -> URL
}

// MARK: - JellyfinAuthClientProtocol

/// A client that has not signed in. It probes a server and obtains a session.
///
/// The Quick Connect polling loop is not here. It lives in `JellyfinAuth`, so
/// its timing, timeout and cancellation are tested without the SDK.
protocol JellyfinAuthClientProtocol: Sendable {
    func serverInfo() async throws -> JellyfinServerInfo
    func quickConnectEnabled() async throws -> Bool
    func signIn(username: String, password: String) async throws -> JellyfinSession
    /// Asks the server for a Quick Connect code and a secret to poll with.
    func quickConnectInitiate() async throws -> JellyfinQuickConnectTicket
    /// Whether the code behind `ticket` has been approved.
    func quickConnectIsApproved(_ ticket: JellyfinQuickConnectTicket) async throws -> Bool
    /// Trades an approved ticket for a session.
    func signIn(approved ticket: JellyfinQuickConnectTicket) async throws -> JellyfinSession
}

// MARK: - JellyfinQuickConnectTicket

/// A pending Quick Connect request. The secret is a credential until it is
/// used, so it is never logged and never leaves the module.
struct JellyfinQuickConnectTicket: Sendable, Equatable {
    /// The short code the user types into an already signed-in session.
    let code: String
    let secret: String
}
