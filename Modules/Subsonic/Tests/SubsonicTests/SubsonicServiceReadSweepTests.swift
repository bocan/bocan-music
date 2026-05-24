import Foundation
import Persistence
import SwiftSonic
import Testing
@testable import Subsonic

// MARK: - File-local stub transport

private final class ReadStubTransport: HTTPTransport, @unchecked Sendable {
    private var responses: [(Data, Int)] = []
    private(set) var requests: [URL] = []

    func enqueue(json: String, statusCode: Int = 200) {
        self.responses.append((Data(json.utf8), statusCode))
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        self.requests.append(request.url ?? URL(string: "about:blank")!)
        guard !self.responses.isEmpty else {
            throw URLError(.badServerResponse)
        }
        let (data, status) = self.responses.removeFirst()
        let resp = HTTPURLResponse(
            url: request.url ?? URL(string: "https://test.local")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, resp)
    }
}

private let testServerURL = URL(string: "https://music.test.local")!

private func makeService() async throws -> (SubsonicService, UUID, ReadStubTransport) {
    let db = try await Database(location: .inMemory)
    let repo = SubsonicServerRepository(database: db)
    let store = SubsonicServerStore(repository: repo)
    let id = UUID()
    try await repo.insert(SubsonicServerDTO(
        id: id,
        name: "Test",
        serverURL: testServerURL,
        authKind: "tokenSalt",
        username: "alice",
        keychainAccount: id.uuidString
    ))
    let transport = ReadStubTransport()
    let client = SwiftSonicClient(
        configuration: ServerConfiguration(
            serverURL: testServerURL,
            auth: .tokenAuth(username: "alice", password: "s3cr3t", reusesSalt: false)
        ),
        transport: transport,
        retryPolicy: RetryPolicy(maxAttempts: 1, baseDelay: 0)
    )
    let service = SubsonicService(store: store)
    await service._registerClientForTesting(client, serverID: id)
    return (service, id, transport)
}

private let okEnv = """
{"subsonic-response":{"status":"ok","version":"1.16.1"}}
"""

private func envelope(_ inner: String) -> String {
    "{\"subsonic-response\":{\"status\":\"ok\",\"version\":\"1.16.1\",\(inner)}}"
}

// MARK: - Read endpoint sweep

@Suite("SubsonicService read endpoint sweep")
struct SubsonicServiceReadSweepTests {
    @Test("ping hits ping endpoint")
    func pingHits() async throws {
        let (service, id, transport) = try await makeService()
        transport.enqueue(json: okEnv)
        try await service.ping(serverID: id)
        #expect(transport.requests[0].path.contains("ping"))
    }

    @Test("getArtists parses an empty index list")
    func getArtists() async throws {
        let (service, id, transport) = try await makeService()
        transport.enqueue(json: envelope("\"artists\":{\"ignoredArticles\":\"The\",\"index\":[]}"))
        let result = try await service.getArtists(serverID: id)
        #expect(result.isEmpty)
        #expect(transport.requests[0].path.contains("getArtists"))
    }

    @Test("getArtist parses a stub artist")
    func getArtist() async throws {
        let (service, id, transport) = try await makeService()
        transport.enqueue(json: envelope("\"artist\":{\"id\":\"a1\",\"name\":\"Stub\",\"albumCount\":0}"))
        let result = try await service.getArtist(serverID: id, id: "a1")
        #expect(result.id == "a1")
        #expect(result.name == "Stub")
    }

    @Test("getAlbum parses a stub album")
    func getAlbum() async throws {
        let (service, id, transport) = try await makeService()
        transport.enqueue(json: envelope("\"album\":{\"id\":\"b1\",\"name\":\"Album\",\"songCount\":0,\"duration\":0}"))
        let result = try await service.getAlbum(serverID: id, id: "b1")
        #expect(result.id == "b1")
    }

    @Test("getGenres parses an empty list")
    func getGenres() async throws {
        let (service, id, transport) = try await makeService()
        transport.enqueue(json: envelope("\"genres\":{\"genre\":[]}"))
        let result = try await service.getGenres(serverID: id)
        #expect(result.isEmpty)
    }

    @Test("getAlbumList2 hits getAlbumList2 endpoint")
    func getAlbumList2() async throws {
        let (service, id, transport) = try await makeService()
        transport.enqueue(json: envelope("\"albumList2\":{\"album\":[]}"))
        let result = try await service.getAlbumList2(serverID: id, type: .newest, size: 10, offset: 0)
        #expect(result.isEmpty)
        #expect(transport.requests[0].path.contains("getAlbumList2"))
    }

    @Test("getRandomSongs returns an empty array for empty payload")
    func getRandomSongs() async throws {
        let (service, id, transport) = try await makeService()
        transport.enqueue(json: envelope("\"randomSongs\":{\"song\":[]}"))
        let result = try await service.getRandomSongs(serverID: id, size: 5)
        #expect(result.isEmpty)
    }

    @Test("getSongsByGenre returns an empty array for empty payload")
    func getSongsByGenre() async throws {
        let (service, id, transport) = try await makeService()
        transport.enqueue(json: envelope("\"songsByGenre\":{\"song\":[]}"))
        let result = try await service.getSongsByGenre(serverID: id, genre: "Rock", count: 10, offset: 0)
        #expect(result.isEmpty)
    }

    @Test("getStarred2 returns an empty result")
    func getStarred2() async throws {
        let (service, id, transport) = try await makeService()
        transport.enqueue(json: envelope("\"starred2\":{}"))
        let result = try await service.getStarred2(serverID: id)
        #expect((result.song ?? []).isEmpty)
    }

    @Test("getPlaylists returns an empty list")
    func getPlaylists() async throws {
        let (service, id, transport) = try await makeService()
        transport.enqueue(json: envelope("\"playlists\":{\"playlist\":[]}"))
        let result = try await service.getPlaylists(serverID: id)
        #expect(result.isEmpty)
    }

    @Test("getPlaylist parses a stub playlist")
    func getPlaylist() async throws {
        let (service, id, transport) = try await makeService()
        transport
            .enqueue(
                json: envelope(
                    "\"playlist\":{\"id\":\"p1\",\"name\":\"Mix\",\"songCount\":0,\"duration\":0,\"owner\":\"alice\",\"public\":false,\"created\":\"2024-01-01T00:00:00.000Z\",\"changed\":\"2024-01-01T00:00:00.000Z\"}"
                )
            )
        let result = try await service.getPlaylist(serverID: id, id: "p1")
        #expect(result.id == "p1")
    }

    @Test("search3 returns an empty result")
    func search3() async throws {
        let (service, id, transport) = try await makeService()
        transport.enqueue(json: envelope("\"searchResult3\":{}"))
        let result = try await service.search3(serverID: id, query: "abba")
        #expect((result.song ?? []).isEmpty)
    }

    @Test("getPodcasts returns an empty list")
    func getPodcasts() async throws {
        let (service, id, transport) = try await makeService()
        transport.enqueue(json: envelope("\"podcasts\":{\"channel\":[]}"))
        let result = try await service.getPodcasts(serverID: id)
        #expect(result.isEmpty)
    }

    @Test("getInternetRadioStations returns an empty list")
    func getInternetRadioStations() async throws {
        let (service, id, transport) = try await makeService()
        transport.enqueue(json: envelope("\"internetRadioStations\":{\"internetRadioStation\":[]}"))
        let result = try await service.getInternetRadioStations(serverID: id)
        #expect(result.isEmpty)
    }

    @Test("getBookmarks returns an empty list")
    func getBookmarks() async throws {
        let (service, id, transport) = try await makeService()
        transport.enqueue(json: envelope("\"bookmarks\":{\"bookmark\":[]}"))
        let result = try await service.getBookmarks(serverID: id)
        #expect(result.isEmpty)
    }

    @Test("getNowPlaying returns an empty list")
    func getNowPlaying() async throws {
        let (service, id, transport) = try await makeService()
        transport.enqueue(json: envelope("\"nowPlaying\":{\"entry\":[]}"))
        let result = try await service.getNowPlaying(serverID: id)
        #expect(result.isEmpty)
    }

    @Test("reloadClients with no servers leaves the pool empty")
    func reloadClientsEmpty() async throws {
        let db = try await Database(location: .inMemory)
        let repo = SubsonicServerRepository(database: db)
        let store = SubsonicServerStore(repository: repo)
        let service = SubsonicService(store: store)
        try await service.reloadClients()
        // Unknown serverID still throws.
        do {
            try await service.ping(serverID: UUID())
            Issue.record("expected unknownServer")
        } catch SubsonicError.unknownServer {
            // expected
        }
    }

    @Test("removeClient drops the registered client")
    func removeClientDrops() async throws {
        let (service, id, _) = try await makeService()
        await service.removeClient(for: id)
        do {
            try await service.ping(serverID: id)
            Issue.record("expected unknownServer after removal")
        } catch SubsonicError.unknownServer {
            // expected
        }
    }

    @Test("getArtists on unknown server throws unknownServer")
    func getArtistsUnknown() async throws {
        let (service, _, _) = try await makeService()
        let bogus = UUID()
        do {
            _ = try await service.getArtists(serverID: bogus)
            Issue.record("expected unknownServer")
        } catch let SubsonicError.unknownServer(returned) {
            #expect(returned == bogus)
        }
    }
}
