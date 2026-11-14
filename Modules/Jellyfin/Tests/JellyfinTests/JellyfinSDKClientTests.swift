import Foundation
import Testing
@testable import Jellyfin

/// Drives the real SDK client against a `URLProtocol` stub, so the request each
/// call sends is checked as it goes on the wire. No test touches the network.
extension StubbedNetwork {
    @Suite("JellyfinSDKClient")
    struct JellyfinSDKClientTests {
        private let token = "TEST-TOKEN-0123456789"
        private let userID = "7f3b1c0e9d2a4e5f8a6b0c1d2e3f4a5b"

        private func makeClient(url: String = "https://jf.example.test") -> JellyfinSDKClient {
            JellyfinSDKClient(
                configuration: .test(url: url, token: self.token),
                sessionConfiguration: StubURLProtocol.sessionConfiguration
            )
        }

        /// The query as name to value. The SDK sends a list as a repeated name
        /// (`sortBy=A&sortBy=B`), so repeated values are joined with commas, in order.
        private func query(_ request: URLRequest) -> [String: String] {
            guard let url = request.url else { return [:] }
            return Self.query(of: url)
        }

        private static func query(of url: URL) -> [String: String] {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            return Dictionary(items.map { ($0.name, $0.value ?? "") }) { first, second in first + "," + second }
        }

        private func body(_ request: URLRequest) -> [String: Any] {
            var data = request.httpBody
            if data == nil, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var collected = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 {
                        break
                    }
                    collected.append(buffer, count: count)
                }
                data = collected
            }
            guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
            return object
        }

        private func reply(_ fixture: String, status: Int = 200) -> StubURLProtocol.Reply {
            StubURLProtocol.Reply(status: status, body: (try? Fixture.data(fixture)) ?? Data())
        }

        // MARK: Headers and ping

        @Test("every request carries the device identity and the token in the Authorization header")
        func authorizationHeader() async throws {
            StubURLProtocol.install { _ in StubURLProtocol.Reply(body: Data("{}".utf8)) }
            defer { StubURLProtocol.reset() }
            try await self.makeClient().ping()
            let request = try #require(StubURLProtocol.requests.first)
            #expect(request.url?.path == "/Users/Me")
            let header = try #require(request.value(forHTTPHeaderField: "Authorization"))
            #expect(header.hasPrefix("MediaBrowser "))
            #expect(header.contains("Client=Bocan"))
            #expect(header.contains("DeviceId=DEVICE-1"))
            #expect(header.contains("Token=\(self.token)"))
            // The token goes in the header, never in the query of an ordinary request.
            #expect(request.url?.query?.contains(self.token) != true)
        }

        @Test("ping is an authenticated call, so a revoked token reports unauthorized")
        func pingRevokedToken() async {
            StubURLProtocol.install { _ in StubURLProtocol.Reply(status: 401) }
            defer { StubURLProtocol.reset() }
            await #expect(throws: JellyfinError.unauthorized) {
                try await self.makeClient().ping()
            }
        }

        @Test("a 503 reports an http error with its status")
        func pingServerError() async {
            StubURLProtocol.install { _ in StubURLProtocol.Reply(status: 503) }
            defer { StubURLProtocol.reset() }
            await #expect(throws: JellyfinError.http(status: 503)) {
                try await self.makeClient().ping()
            }
        }

        @Test("a path prefix in the server URL is kept on requests and on media URLs")
        func pathPrefix() async throws {
            StubURLProtocol.install { _ in StubURLProtocol.Reply(body: Data("{}".utf8)) }
            defer { StubURLProtocol.reset() }
            let client = self.makeClient(url: "https://example.test/jellyfin")
            try await client.ping()
            #expect(StubURLProtocol.requests.first?.url?.path == "/jellyfin/Users/Me")
            let stream = try client.streamURL(itemID: "abc", format: .original, bitrate: .original)
            #expect(stream.path == "/jellyfin/Audio/abc/stream")
        }

        // MARK: Server info and sign-in

        @Test("serverInfo needs no sign-in and maps the public info")
        func serverInfo() async throws {
            StubURLProtocol.install { _ in self.reply("public-info") }
            defer { StubURLProtocol.reset() }
            let info = try await self.makeClient().serverInfo()
            #expect(StubURLProtocol.requests.first?.url?.path == "/System/Info/Public")
            #expect(info.serverName == "Basement")
            #expect(info.version == "10.10.7")
        }

        @Test("password sign-in posts the credentials once and returns user, name and token")
        func signIn() async throws {
            StubURLProtocol.install { _ in self.reply("auth-result") }
            defer { StubURLProtocol.reset() }
            let client = JellyfinSDKClient(
                configuration: .test(userID: nil, token: nil),
                sessionConfiguration: StubURLProtocol.sessionConfiguration
            )
            let session = try await client.signIn(username: "listener", password: "hunter2")
            let request = try #require(StubURLProtocol.requests.first)
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/Users/AuthenticateByName")
            let body = self.body(request)
            #expect(body["Username"] as? String == "listener")
            #expect(body["Pw"] as? String == "hunter2")
            #expect(session.userID == "7f3b1c0e9d2a4e5f8a6b0c1d2e3f4a5b")
            #expect(session.username == "listener")
            #expect(session.accessToken == "REDACTED-TEST-TOKEN-0123456789abcdef")
            // The password is sent in the body, never in the URL.
            #expect(request.url?.absoluteString.contains("hunter2") != true)
        }

        @Test("a wrong password reports unauthorized")
        func signInWrongPassword() async {
            StubURLProtocol.install { _ in StubURLProtocol.Reply(status: 401) }
            defer { StubURLProtocol.reset() }
            let client = JellyfinSDKClient(
                configuration: .test(userID: nil, token: nil),
                sessionConfiguration: StubURLProtocol.sessionConfiguration
            )
            await #expect(throws: JellyfinError.unauthorized) {
                _ = try await client.signIn(username: "listener", password: "wrong")
            }
        }

        @Test("a sign-in answer with no token reports noAccessToken")
        func signInNoToken() async {
            StubURLProtocol.install { _ in StubURLProtocol.Reply(body: Data("{\"User\":{\"Id\":\"u\",\"Name\":\"n\"}}".utf8)) }
            defer { StubURLProtocol.reset() }
            let client = JellyfinSDKClient(
                configuration: .test(userID: nil, token: nil),
                sessionConfiguration: StubURLProtocol.sessionConfiguration
            )
            await #expect(throws: JellyfinError.noAccessToken) {
                _ = try await client.signIn(username: "listener", password: "pw")
            }
        }

        @Test("Quick Connect enabled is read from a bare JSON boolean")
        func quickConnectEnabled() async throws {
            for (body, expected) in [("true", true), ("false", false), (" true\n", true)] {
                StubURLProtocol.install { _ in StubURLProtocol.Reply(body: Data(body.utf8)) }
                let on = try await self.makeClient().quickConnectEnabled()
                #expect(on == expected)
            }
            StubURLProtocol.reset()
        }

        @Test("Quick Connect initiate returns the code and secret, and the poll reads the state")
        func quickConnectTicket() async throws {
            defer { StubURLProtocol.reset() }
            StubURLProtocol.install { request in
                if request.url?.path == "/QuickConnect/Initiate" {
                    return StubURLProtocol.Reply(body: Data("{\"Code\":\"482913\",\"Secret\":\"s3cr3t\",\"Authenticated\":false}".utf8))
                }
                return StubURLProtocol.Reply(body: Data("{\"Secret\":\"s3cr3t\",\"Authenticated\":true}".utf8))
            }
            let client = self.makeClient()
            let ticket = try await client.quickConnectInitiate()
            #expect(ticket.code == "482913")
            #expect(try await client.quickConnectIsApproved(ticket))
            let poll = try #require(StubURLProtocol.requests.last)
            #expect(poll.url?.path == "/QuickConnect/Connect")
            #expect(self.query(poll)["secret"] == "s3cr3t")
        }

        // MARK: Browsing

        @Test("songs asks /Items for audio with the user id, paging, fields and total count")
        func songsRequest() async throws {
            StubURLProtocol.install { _ in self.reply("songs") }
            defer { StubURLProtocol.reset() }
            let page = try await self.makeClient().songs(JellyfinItemQuery(
                kind: .song,
                sort: [.albumArtist, .album, .discNumber, .trackNumber],
                startIndex: 100,
                limit: 100
            ))
            let request = try #require(StubURLProtocol.requests.first)
            let query = self.query(request)
            #expect(request.url?.path == "/Items")
            #expect(query["userId"] == self.userID)
            #expect(query["includeItemTypes"] == "Audio")
            #expect(query["recursive"] == "true")
            #expect(query["startIndex"] == "100")
            #expect(query["limit"] == "100")
            #expect(query["sortBy"] == "AlbumArtist,Album,ParentIndexNumber,IndexNumber")
            #expect(query["enableTotalRecordCount"] == "true")
            #expect(query["enableUserData"] == "true")
            #expect(try #require(query["fields"]).contains("MediaSources"))
            #expect(try #require(query["fields"]).contains("Genres"))
            #expect(page.items.count == 3)
            #expect(page.total == 412)
        }

        @Test("album songs, genre filter, favourites filter, ids, artist and search term reach the server")
        func filters() async throws {
            StubURLProtocol.install { _ in self.reply("songs") }
            defer { StubURLProtocol.reset() }
            let client = self.makeClient()
            _ = try await client.songs(JellyfinItemQuery(kind: .song, parentID: "album-1"))
            _ = try await client.songs(JellyfinItemQuery(kind: .song, genreID: "genre-1"))
            _ = try await client.songs(JellyfinItemQuery(kind: .song, favoritesOnly: true))
            _ = try await client.songs(JellyfinItemQuery(kind: .song, searchTerm: "wood"))
            _ = try await client.albums(JellyfinItemQuery(kind: .album, albumArtistID: "ar-1", ids: ["a1"]))
            let queries = StubURLProtocol.requests.map { self.query($0) }
            #expect(queries[0]["parentId"] == "album-1")
            #expect(queries[1]["genreIds"] == "genre-1")
            #expect(queries[2]["isFavorite"] == "true")
            #expect(queries[3]["searchTerm"] == "wood")
            #expect(queries[4]["includeItemTypes"] == "MusicAlbum")
            #expect(queries[4]["ids"] == "a1")
            #expect(queries[4]["albumArtistIds"] == "ar-1")
            // Nothing is sent that was not asked for.
            #expect(queries[0]["isFavorite"] == nil)
            #expect(queries[0]["searchTerm"] == nil)
        }

        @Test("a descending sort sends the descending order")
        func descendingSort() async throws {
            StubURLProtocol.install { _ in self.reply("albums") }
            defer { StubURLProtocol.reset() }
            _ = try await self.makeClient().albums(JellyfinItemQuery(kind: .album, sort: [.dateCreated], descending: true))
            let query = try self.query(#require(StubURLProtocol.requests.first))
            #expect(query["sortBy"] == "DateCreated")
            #expect(query["sortOrder"] == "Descending")
        }

        @Test("artists use the album-artist list, with the user id")
        func artistsRequest() async throws {
            StubURLProtocol.install { _ in self.reply("artists") }
            defer { StubURLProtocol.reset() }
            let page = try await self.makeClient().artists(JellyfinItemQuery(kind: .artist, startIndex: 0, limit: 50))
            let request = try #require(StubURLProtocol.requests.first)
            #expect(request.url?.path == "/Artists/AlbumArtists")
            #expect(self.query(request)["userId"] == self.userID)
            #expect(page.items.map(\.name) == ["Lilly Wood and The Prick"])
        }

        @Test("genres ask for the genres of audio items only")
        func genresRequest() async throws {
            StubURLProtocol.install { _ in self.reply("genres") }
            defer { StubURLProtocol.reset() }
            let page = try await self.makeClient().genres(startIndex: 0, limit: 100)
            let request = try #require(StubURLProtocol.requests.first)
            #expect(request.url?.path == "/Genres")
            #expect(self.query(request)["includeItemTypes"] == "Audio")
            #expect(page.items.count == 2)
        }

        @Test("playlists are Playlist items; playlist songs come from the playlist's own path")
        func playlistRequests() async throws {
            StubURLProtocol.install { request in
                request.url?.path.hasSuffix("/Items") == true && request.url?.path.contains("/Playlists/") == true
                    ? self.reply("songs") : self.reply("playlists")
            }
            defer { StubURLProtocol.reset() }
            let client = self.makeClient()
            _ = try await client.playlists(JellyfinItemQuery(kind: .playlist))
            _ = try await client.playlistSongs(id: "pl-1", startIndex: 0, limit: 100)
            let requests = StubURLProtocol.requests
            #expect(self.query(requests[0])["includeItemTypes"] == "Playlist")
            #expect(requests[1].url?.path == "/Playlists/pl-1/Items")
            #expect(self.query(requests[1])["userId"] == self.userID)
        }

        @Test("a signed-in call with no user id fails clearly instead of sending a bad request")
        func missingUserID() async {
            StubURLProtocol.install { _ in self.reply("songs") }
            defer { StubURLProtocol.reset() }
            let client = JellyfinSDKClient(
                configuration: .test(userID: nil),
                sessionConfiguration: StubURLProtocol.sessionConfiguration
            )
            await #expect(throws: JellyfinError.self) {
                _ = try await client.songs(JellyfinItemQuery(kind: .song))
            }
            #expect(StubURLProtocol.requests.isEmpty)
        }

        // MARK: Writes

        @Test("favourite is a POST and unfavourite is a DELETE on the same path")
        func favoriteRequests() async throws {
            StubURLProtocol.install { _ in StubURLProtocol.Reply(body: Data("{\"Key\":\"k\",\"IsFavorite\":true}".utf8)) }
            defer { StubURLProtocol.reset() }
            let client = self.makeClient()
            try await client.setFavorite(itemID: "item-1", isFavorite: true)
            try await client.setFavorite(itemID: "item-1", isFavorite: false)
            let requests = StubURLProtocol.requests
            #expect(requests[0].httpMethod == "POST")
            #expect(requests[1].httpMethod == "DELETE")
            #expect(requests[0].url?.path == "/UserFavoriteItems/item-1")
            #expect(requests[1].url?.path == "/UserFavoriteItems/item-1")
            #expect(self.query(requests[0])["userId"] == self.userID)
        }

        @Test("playback started posts the item at position zero")
        func playbackStarted() async throws {
            StubURLProtocol.install { _ in StubURLProtocol.Reply(status: 204) }
            defer { StubURLProtocol.reset() }
            try await self.makeClient().reportPlaybackStarted(itemID: "item-1")
            let request = try #require(StubURLProtocol.requests.first)
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/Sessions/Playing")
            let body = self.body(request)
            #expect(body["ItemId"] as? String == "item-1")
            #expect(body["PositionTicks"] as? Int == 0)
        }

        @Test("playback stopped posts the full-length position in ticks")
        func playbackStopped() async throws {
            StubURLProtocol.install { _ in StubURLProtocol.Reply(status: 204) }
            defer { StubURLProtocol.reset() }
            try await self.makeClient().reportPlaybackStopped(itemID: "item-1", positionTicks: 2_405_000_000)
            let request = try #require(StubURLProtocol.requests.first)
            #expect(request.url?.path == "/Sessions/Playing/Stopped")
            let body = self.body(request)
            #expect(body["ItemId"] as? String == "item-1")
            #expect(body["PositionTicks"] as? Int == 2_405_000_000)
        }

        @Test("sign out posts to the logout path, and a missing token sends nothing")
        func signOut() async throws {
            StubURLProtocol.install { _ in StubURLProtocol.Reply(status: 204) }
            defer { StubURLProtocol.reset() }
            try await self.makeClient().signOut()
            #expect(StubURLProtocol.requests.first?.url?.path == "/Sessions/Logout")
            StubURLProtocol.install { _ in StubURLProtocol.Reply(status: 204) }
            let anonymous = JellyfinSDKClient(
                configuration: .test(token: nil),
                sessionConfiguration: StubURLProtocol.sessionConfiguration
            )
            try await anonymous.signOut()
            #expect(StubURLProtocol.requests.isEmpty)
        }

        // MARK: Media URLs

        @Test("the original format builds a static stream URL with the token")
        func originalStream() throws {
            let url = try self.makeClient().streamURL(itemID: "item-1", format: .original, bitrate: .kbps(192))
            let query = Self.query(of: url)
            #expect(url.path == "/Audio/item-1/stream")
            #expect(query["static"] == "true")
            #expect(query["ApiKey"] == self.token)
            // With the original file the cap is ignored: a cap needs a target codec.
            #expect(query["audioBitRate"] == nil)
            #expect(query["container"] == nil)
        }

        @Test("a chosen format builds a transcode URL with the cap in bits per second", arguments: [
            (JellyfinStreamFormat.mp3, "mp3"),
            (.opus, "opus"),
            (.aac, "aac"),
            (.flac, "flac"),
        ])
        func transcodeStream(format: JellyfinStreamFormat, name: String) throws {
            let url = try self.makeClient().streamURL(itemID: "item-1", format: format, bitrate: .kbps(192))
            let query = Self.query(of: url)
            #expect(query["container"] == name)
            #expect(query["audioCodec"] == name)
            #expect(query["audioBitRate"] == "192000")
            #expect(query["static"] == nil)
            #expect(query["ApiKey"] == self.token)
        }

        @Test("a transcode with no cap leaves the bitrate to the server")
        func transcodeWithoutCap() throws {
            let url = try self.makeClient().streamURL(itemID: "item-1", format: .mp3, bitrate: .original)
            #expect(url.query?.contains("audioBitRate") != true)
        }

        @Test("the image URL names the item, the tag, the width and the token")
        func imageURL() throws {
            let url = try self.makeClient().imageURL(itemID: "album-1", tag: "c0ffee", maxWidth: 300)
            let query = Self.query(of: url)
            #expect(url.path == "/Items/album-1/Images/Primary")
            #expect(query["tag"] == "c0ffee")
            #expect(query["maxWidth"] == "300")
            #expect(query["ApiKey"] == self.token)
        }

        @Test("a media URL for a client with no token carries no key")
        func mediaURLWithoutToken() throws {
            let anonymous = JellyfinSDKClient(configuration: .test(token: nil))
            let url = try anonymous.streamURL(itemID: "item-1", format: .original, bitrate: .original)
            #expect(url.query?.contains("ApiKey") != true)
        }
    }
}
