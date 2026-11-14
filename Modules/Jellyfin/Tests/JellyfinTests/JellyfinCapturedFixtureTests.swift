import Foundation
import Testing
@testable import Jellyfin

/// Runs real server captures through the real SDK client and the mappers.
///
/// Opt-in: set `JELLYFIN_CAPTURE_DIR` to a folder made by
/// `Scripts/capture-jellyfin-fixtures.py`. The captures hold a person's own
/// library, so they are never checked in; the suite is skipped without the
/// variable. Nothing here touches the network: the files are served by
/// `StubURLProtocol`.
private let captureDir: URL? = ProcessInfo.processInfo.environment["JELLYFIN_CAPTURE_DIR"].map { URL(filePath: $0) }

@Suite("Captured server responses", .serialized, .enabled(if: captureDir != nil))
struct JellyfinCapturedFixtureTests {
    private func file(_ name: String) throws -> Data {
        let dir = try #require(captureDir)
        return try Data(contentsOf: dir.appending(path: "\(name).json"))
    }

    private func client() -> JellyfinSDKClient {
        JellyfinSDKClient(
            configuration: .test(userID: "ec070173e6474d938ea2902a89f13058"),
            sessionConfiguration: StubURLProtocol.sessionConfiguration
        )
    }

    private func serve(_ name: String) throws {
        let body = try self.file(name)
        StubURLProtocol.install { _ in StubURLProtocol.Reply(body: body) }
    }

    private func rawItems(_ name: String) throws -> [[String: Any]] {
        let object = try #require(try JSONSerialization.jsonObject(with: self.file(name)) as? [String: Any])
        return object["Items"] as? [[String: Any]] ?? []
    }

    @Test("the public info decodes")
    func publicInfo() async throws {
        try self.serve("public-info")
        defer { StubURLProtocol.reset() }
        let info = try await self.client().serverInfo()
        #expect(info.version?.isEmpty == false)
        #expect(info.serverID?.isEmpty == false)
    }

    @Test("the sign-in answer decodes to a session")
    func signIn() async throws {
        try self.serve("auth-result")
        defer { StubURLProtocol.reset() }
        let session = try await self.client().signIn(username: "someone", password: "unused")
        #expect(!session.userID.isEmpty)
        #expect(!session.accessToken.isEmpty)
    }

    @Test("every captured song decodes and maps with its id, title, length and container")
    func songs() async throws {
        try self.serve("songs")
        defer { StubURLProtocol.reset() }
        let raw = try self.rawItems("songs")
        let page = try await self.client().songs(JellyfinItemQuery(kind: .song))
        #expect(page.items.count == raw.count, "a song was dropped by the mapper")
        #expect(!page.items.isEmpty)
        for (song, item) in zip(page.items, raw) {
            #expect(song.id == item["Id"] as? String)
            #expect(song.durationSeconds != nil)
            #expect(song.container != nil)
            #expect(song.bitrateKbps != nil)
        }
    }

    @Test("every captured album, artist, genre and playlist decodes and keeps its id")
    func lists() async throws {
        let client = self.client()
        try self.serve("albums")
        let albums = try await client.albums(JellyfinItemQuery(kind: .album))
        try self.serve("artists")
        let artists = try await client.artists(JellyfinItemQuery(kind: .artist))
        try self.serve("genres")
        let genres = try await client.genres(startIndex: 0, limit: nil)
        try self.serve("playlists")
        let playlists = try await client.playlists(JellyfinItemQuery(kind: .playlist))
        StubURLProtocol.reset()
        #expect(try albums.items.map(\.id) == (self.rawItems("albums")).compactMap { $0["Id"] as? String })
        #expect(try artists.items.map(\.id) == (self.rawItems("artists")).compactMap { $0["Id"] as? String })
        #expect(try genres.items.map(\.id) == (self.rawItems("genres")).compactMap { $0["Id"] as? String })
        // The server may say `Unknown` for an audio playlist, so the mapper keeps those.
        #expect(try playlists.items.count == (self.rawItems("playlists")).count)
        #expect(albums.total != nil)
        #expect(albums.items.allSatisfy { !$0.title.isEmpty })
    }

    @Test("ids are 32 hex characters with no dashes, as the server sends them")
    func idShape() throws {
        for name in ["songs", "albums", "artists", "genres", "playlists"] {
            for item in try self.rawItems(name) {
                let id = try #require(item["Id"] as? String)
                #expect(id.count == 32, "\(name) id \(id) is not 32 characters")
                #expect(!id.contains("-"))
            }
        }
    }

    @Test("no captured file holds a token")
    func noToken() throws {
        for name in ["auth-result", "songs", "albums", "artists", "genres", "playlists", "public-info"] {
            let text = try String(data: self.file(name), encoding: .utf8) ?? ""
            #expect(!text.contains("ApiKey="))
            if name == "auth-result" {
                #expect(text.contains("REDACTED-TEST-TOKEN"))
            }
        }
    }
}
