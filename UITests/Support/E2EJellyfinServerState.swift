import Foundation
import Network

// MARK: - JellyfinServerState

/// Queue-confined state and connection handling for `E2EJellyfinServer`.
/// Everything here runs on the server's one serial queue, as in
/// `PodcastServerState`, so nothing needs its own lock.
final class JellyfinServerState: @unchecked Sendable {
    let songAudio: Data
    let songSeconds: Double

    /// See `E2EJellyfinServer.actions`.
    private(set) var actions: [String] = []
    /// See `E2EJellyfinServer.streamedItemIDs`.
    private(set) var streamedItemIDs: [String] = []
    /// Item ids marked as favourites. Starts empty.
    private(set) var favourites: Set<String> = []

    private var allConnections: [NWConnection] = []

    init(songAudio: Data, songSeconds: Double) {
        self.songAudio = songAudio
        self.songSeconds = songSeconds
    }

    // MARK: - Accept

    func accept(_ connection: NWConnection, queue: DispatchQueue) {
        queue.async {
            self.allConnections.append(connection)
            connection.start(queue: queue)
            self.readRequest(connection, buffer: Data())
        }
    }

    func cancelAll() {
        self.allConnections.forEach { $0.cancel() }
        self.allConnections.removeAll()
    }

    // MARK: - Request parsing

    /// One parsed request. The body is read so a POST is answered only after
    /// the client has sent it all.
    struct Request {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String]
        let body: Data

        /// A query value by name, ignoring case: the SDK sends `includeItemTypes`.
        func query(_ name: String) -> String? {
            self.query.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
    }

    /// Reads until the blank line after the headers, then until the body is
    /// as long as `Content-Length` says.
    private func readRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            var buffer = buffer
            if let data {
                buffer.append(data)
            }
            if let request = Self.parse(buffer) {
                self.dispatch(connection, request: request)
                return
            }
            guard error == nil, !isComplete, buffer.count < 1_048_576 else {
                connection.cancel()
                return
            }
            self.readRequest(connection, buffer: buffer)
        }
    }

    /// The request, or nil while bytes are still missing.
    static func parse(_ buffer: Data) -> Request? {
        guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(bytes: buffer[..<range.lowerBound], encoding: .utf8) ?? ""
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.isEmpty ? "" : lines.removeFirst()
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = headers["content-length"].flatMap(Int.init) ?? 0
        let body = buffer[range.upperBound...]
        guard body.count >= length else { return nil }

        let parts = requestLine.split(separator: " ")
        let method = parts.first.map(String.init) ?? ""
        let target = parts.count > 1 ? String(parts[1]) : ""
        let components = URLComponents(string: target)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        return Request(
            method: method,
            path: components?.path ?? target,
            query: query,
            headers: headers,
            body: Data(body.prefix(length))
        )
    }

    // MARK: - Routing

    private func dispatch(_ connection: NWConnection, request: Request) {
        let path = request.path
        // Open endpoints: a real server answers these before sign-in.
        switch (request.method, path) {
        case ("GET", "/System/Info/Public"):
            self.sendJSON(connection, Self.publicInfo)

        case ("GET", "/QuickConnect/Enabled"):
            self.sendJSON(connection, false)

        case ("POST", "/Users/AuthenticateByName"):
            self.signIn(connection, request: request)

        default:
            if Self.isAuthorized(request) {
                self.dispatchSignedIn(connection, request: request)
            } else {
                self.send(connection, status: "401 Unauthorized", contentType: nil, body: Data())
            }
        }
    }

    private func dispatchSignedIn(_ connection: NWConnection, request: Request) {
        let path = request.path
        let segments = path.split(separator: "/").map(String.init)
        switch (request.method, segments.first) {
        case ("GET", "Users") where path == "/Users/Me":
            self.sendJSON(connection, Self.user)

        case ("GET", "Items") where segments.count == 1:
            self.sendJSON(connection, self.items(request))

        case ("GET", "Artists"):
            self.sendJSON(connection, Self.page([Self.artist]))

        case ("GET", "Genres"):
            self.sendJSON(connection, Self.page([Self.genre]))

        case ("GET", "Playlists"):
            self.sendJSON(connection, Self.page(self.songItems(E2EJellyfinFixture.songs)))

        case ("GET", "Audio") where segments.count == 3:
            self.streamedItemIDs.append(segments[1])
            self.send(connection, status: "200 OK", contentType: "audio/wav", body: self.songAudio)

        case ("POST", "UserFavoriteItems"), ("DELETE", "UserFavoriteItems"):
            self.toggleFavourite(connection, request: request, itemID: segments.last ?? "")

        case ("POST", "Sessions"):
            self.actions.append("POST \(path)")
            self.send(connection, status: "204 No Content", contentType: nil, body: Data())

        default:
            // Images included: the fixture has no cover art, so the app shows
            // its placeholder.
            self.send(connection, status: "404 Not Found", contentType: nil, body: Data())
        }
    }

    /// Stream and image URLs carry the token as `ApiKey`; every other call
    /// sends it in the `Authorization` header.
    private static func isAuthorized(_ request: Request) -> Bool {
        let token = E2EJellyfinFixture.accessToken
        if request.query("ApiKey") == token || request.query("api_key") == token {
            return true
        }
        return ["authorization", "x-emby-authorization", "x-emby-token"].contains { name in
            request.headers[name]?.contains(token) == true
        }
    }

    private func signIn(_ connection: NWConnection, request: Request) {
        let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
        let accepted = body?["Username"] as? String == E2EJellyfinFixture.username
            && body?["Pw"] as? String == E2EJellyfinFixture.password
        self.actions.append("POST /Users/AuthenticateByName \(accepted ? "accepted" : "refused")")
        guard accepted else {
            self.send(connection, status: "401 Unauthorized", contentType: nil, body: Data())
            return
        }
        self.sendJSON(connection, [
            "User": Self.user,
            "SessionInfo": [String: Any](),
            "AccessToken": E2EJellyfinFixture.accessToken,
            "ServerId": E2EJellyfinFixture.serverID,
        ])
    }

    private func toggleFavourite(_ connection: NWConnection, request: Request, itemID: String) {
        let isFavourite = request.method == "POST"
        if isFavourite {
            self.favourites.insert(itemID)
        } else {
            self.favourites.remove(itemID)
        }
        self.actions.append("\(request.method) /UserFavoriteItems/\(itemID)")
        self.sendJSON(connection, Self.userData(isFavourite: isFavourite, key: itemID))
    }

    /// `/Items` answers by the kind asked for. Songs honour the favourites and
    /// search filters, which Starred and in-view search use.
    private func items(_ request: Request) -> [String: Any] {
        switch request.query("includeItemTypes") ?? "" {
        case "MusicAlbum":
            return Self.page([Self.album])

        case "Playlist":
            return Self.page([Self.playlist])

        case "Audio":
            var songs = E2EJellyfinFixture.songs
            if request.query("isFavorite") == "true" {
                songs = songs.filter { self.favourites.contains($0.id) }
            }
            if let term = request.query("searchTerm"), !term.isEmpty {
                songs = songs.filter { $0.title.localizedCaseInsensitiveContains(term) }
            }
            return Self.page(self.songItems(songs))

        default:
            return Self.page([])
        }
    }

    // MARK: - Sending

    private func sendJSON(_ connection: NWConnection, _ object: Any) {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])) ?? Data()
        self.send(connection, status: "200 OK", contentType: "application/json; charset=utf-8", body: body)
    }

    private func send(_ connection: NWConnection, status: String, contentType: String?, body: Data) {
        var text = "HTTP/1.1 \(status)\r\n"
        if let contentType {
            text += "Content-Type: \(contentType)\r\n"
        }
        text += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var payload = Data(text.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
    }
}

// MARK: - Response bodies

extension JellyfinServerState {
    static var publicInfo: [String: Any] {
        [
            "LocalAddress": "http://127.0.0.1",
            "ServerName": E2EJellyfinFixture.serverName,
            "Version": "10.10.7",
            "ProductName": "Jellyfin Server",
            "OperatingSystem": "",
            "Id": E2EJellyfinFixture.serverID,
            "StartupWizardCompleted": true,
        ]
    }

    static var user: [String: Any] {
        [
            "Name": E2EJellyfinFixture.username,
            "ServerId": E2EJellyfinFixture.serverID,
            "Id": E2EJellyfinFixture.userID,
            "HasPassword": true,
            "HasConfiguredPassword": true,
            "HasConfiguredEasyPassword": false,
            "EnableAutoLogin": false,
        ]
    }

    static func page(_ items: [[String: Any]]) -> [String: Any] {
        ["Items": items, "TotalRecordCount": items.count, "StartIndex": 0]
    }

    static func userData(isFavourite: Bool, key: String) -> [String: Any] {
        ["IsFavorite": isFavourite, "PlayCount": 0, "PlaybackPositionTicks": 0, "Played": false, "Key": key]
    }

    /// 100 ns ticks, as Jellyfin counts time.
    private var runTimeTicks: Int {
        Int(self.songSeconds * 10_000_000)
    }

    func songItems(_ songs: [E2EJellyfinSong]) -> [[String: Any]] {
        let artistRef: [String: Any] = ["Name": E2EJellyfinFixture.artistName, "Id": E2EJellyfinFixture.artistID]
        let mediaSource: (E2EJellyfinSong) -> [String: Any] = { song in
            [
                "Protocol": "File",
                "Id": song.id,
                "Container": "wav",
                "Bitrate": 1_411_200,
                "RunTimeTicks": self.runTimeTicks,
            ]
        }
        return songs.map { song in
            [
                "Name": song.title,
                "ServerId": E2EJellyfinFixture.serverID,
                "Id": song.id,
                "Container": "wav",
                "RunTimeTicks": self.runTimeTicks,
                "IndexNumber": song.track,
                "ParentIndexNumber": 1,
                "Genres": ["Test"],
                "Artists": [E2EJellyfinFixture.artistName],
                "ArtistItems": [artistRef],
                "Album": E2EJellyfinFixture.albumName,
                "AlbumId": E2EJellyfinFixture.albumID,
                "AlbumArtist": E2EJellyfinFixture.artistName,
                "AlbumArtists": [artistRef],
                "ImageTags": [String: Any](),
                "MediaSources": [mediaSource(song)],
                "UserData": Self.userData(isFavourite: self.favourites.contains(song.id), key: song.id),
                "Type": "Audio",
                "MediaType": "Audio",
            ]
        }
    }

    static var album: [String: Any] {
        [
            "Name": E2EJellyfinFixture.albumName,
            "Id": E2EJellyfinFixture.albumID,
            "ChildCount": E2EJellyfinFixture.songs.count,
            "Genres": ["Test"],
            "AlbumArtist": E2EJellyfinFixture.artistName,
            "AlbumArtists": [["Name": E2EJellyfinFixture.artistName, "Id": E2EJellyfinFixture.artistID]],
            "ImageTags": [String: Any](),
            "UserData": userData(isFavourite: false, key: E2EJellyfinFixture.albumID),
            "Type": "MusicAlbum",
        ]
    }

    static var artist: [String: Any] {
        [
            "Name": E2EJellyfinFixture.artistName,
            "Id": E2EJellyfinFixture.artistID,
            "AlbumCount": 1,
            "ImageTags": [String: Any](),
            "UserData": userData(isFavourite: false, key: E2EJellyfinFixture.artistID),
            "Type": "MusicArtist",
        ]
    }

    static var genre: [String: Any] {
        ["Name": "Test", "Id": E2EJellyfinFixture.genreID, "SongCount": 2, "AlbumCount": 1, "Type": "Genre"]
    }

    static var playlist: [String: Any] {
        [
            "Name": "E2E Stub Playlist",
            "Id": E2EJellyfinFixture.playlistID,
            "ChildCount": E2EJellyfinFixture.songs.count,
            "ImageTags": [String: Any](),
            "MediaType": "Audio",
            "Type": "Playlist",
        ]
    }
}
