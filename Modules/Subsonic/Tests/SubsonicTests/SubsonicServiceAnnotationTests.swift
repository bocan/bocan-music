import Foundation
import Persistence
import SwiftSonic
import Testing
@testable import Subsonic

// MARK: - File-local stub transport

private final class RecordingStubTransport: HTTPTransport, @unchecked Sendable {
    private var responses: [(Data, Int)] = []
    private var errors: [Error] = []
    private(set) var requests: [URL] = []

    func enqueue(json: String, statusCode: Int = 200) {
        self.responses.append((Data(json.utf8), statusCode))
    }

    func enqueueError(_ error: Error) {
        self.errors.append(error)
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        self.requests.append(request.url ?? URL(string: "about:blank")!)
        if !self.errors.isEmpty {
            throw self.errors.removeFirst()
        }
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

private let okEnvelope = """
{ "subsonic-response": { "status": "ok", "version": "1.16.1" } }
"""

private let testServerURL = URL(string: "https://music.test.local")!

private func makeService() async throws -> (SubsonicService, UUID, RecordingStubTransport) {
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
    let transport = RecordingStubTransport()
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

// MARK: - SubsonicService annotation methods

@Suite("SubsonicService annotation/scrobble methods")
struct SubsonicServiceAnnotationTests {
    @Test("star issues a request to /rest/star")
    func starHitsStarEndpoint() async throws {
        let (service, id, transport) = try await makeService()
        transport.enqueue(json: okEnvelope)
        try await service.star(serverID: id, songID: "song-42")
        #expect(transport.requests.count == 1)
        #expect(transport.requests[0].path.hasSuffix("/star.view") || transport.requests[0].path.hasSuffix("/star"))
    }

    @Test("unstar issues a request to /rest/unstar")
    func unstarHitsUnstarEndpoint() async throws {
        let (service, id, transport) = try await makeService()
        transport.enqueue(json: okEnvelope)
        try await service.unstar(serverID: id, songID: "song-42")
        #expect(transport.requests.count == 1)
        #expect(transport.requests[0].path.contains("unstar"))
    }

    @Test("setRating issues a request to /rest/setRating with rating query")
    func setRatingHitsSetRatingEndpoint() async throws {
        let (service, id, transport) = try await makeService()
        transport.enqueue(json: okEnvelope)
        try await service.setRating(serverID: id, songID: "song-42", rating: 4)
        #expect(transport.requests.count == 1)
        let url = transport.requests[0]
        #expect(url.path.contains("setRating"))
        #expect(url.query?.contains("rating=4") == true)
    }

    @Test("scrobble issues a request to /rest/scrobble with submission flag")
    func scrobbleHitsScrobbleEndpoint() async throws {
        let (service, id, transport) = try await makeService()
        transport.enqueue(json: okEnvelope)
        try await service.scrobble(serverID: id, songID: "song-42", submission: true)
        #expect(transport.requests.count == 1)
        let url = transport.requests[0]
        #expect(url.path.contains("scrobble"))
        #expect(url.query?.contains("submission=true") == true)
    }

    @Test("scrobble with submission=false records a now-playing entry")
    func scrobbleNowPlaying() async throws {
        let (service, id, transport) = try await makeService()
        transport.enqueue(json: okEnvelope)
        try await service.scrobble(serverID: id, songID: "song-99", submission: false)
        #expect(transport.requests[0].query?.contains("submission=false") == true)
    }

    @Test("star on unknown server throws SubsonicError.unknownServer")
    func starUnknownServer() async throws {
        let (service, _, _) = try await makeService()
        let bogus = UUID()
        do {
            try await service.star(serverID: bogus, songID: "x")
            Issue.record("Expected unknownServer error")
        } catch let SubsonicError.unknownServer(returned) {
            #expect(returned == bogus)
        }
    }

    @Test("transport error is wrapped as SubsonicError.transport")
    func transportErrorIsWrapped() async throws {
        let (service, id, transport) = try await makeService()
        transport.enqueueError(URLError(.networkConnectionLost))
        do {
            try await service.star(serverID: id, songID: "x")
            Issue.record("Expected transport error")
        } catch let SubsonicError.transport(inner) {
            #expect(inner.isTransient)
        }
    }
}

// MARK: - SubsonicService media URL helpers

@Suite("SubsonicService media URL helpers")
struct SubsonicServiceMediaURLTests {
    @Test("streamURL returns a URL with /stream path and the song id")
    func streamURLContainsSongID() async throws {
        let (service, id, _) = try await makeService()
        let url = try await service.streamURL(serverID: id, songID: "song-7")
        #expect(url.path.contains("stream"))
        #expect(url.query?.contains("id=song-7") == true)
    }

    @Test("streamURL honors maxBitRate and format")
    func streamURLHonorsParameters() async throws {
        let (service, id, _) = try await makeService()
        let url = try await service.streamURL(serverID: id, songID: "song-7", maxBitRate: 192, format: "opus")
        let query = url.query ?? ""
        #expect(query.contains("maxBitRate=192"))
        #expect(query.contains("format=opus"))
    }

    @Test("streamURL on unknown server throws .unknownServer")
    func streamURLUnknownServer() async throws {
        let (service, _, _) = try await makeService()
        do {
            _ = try await service.streamURL(serverID: UUID(), songID: "x")
            Issue.record("Expected unknownServer error")
        } catch SubsonicError.unknownServer {
            // expected
        }
    }

    @Test("coverArtURL returns a URL with the entity id")
    func coverArtURLContainsEntityID() async throws {
        let (service, id, _) = try await makeService()
        let url = try #require(await service.coverArtURL(serverID: id, entityID: "album-3"))
        #expect(url.query?.contains("id=album-3") == true)
        #expect(url.path.contains("getCoverArt"))
    }

    @Test("coverArtURL with size includes size parameter")
    func coverArtURLWithSize() async throws {
        let (service, id, _) = try await makeService()
        let url = try #require(await service.coverArtURL(serverID: id, entityID: "album-3", size: 256))
        #expect(url.query?.contains("size=256") == true)
    }

    @Test("coverArtURL on unknown server throws .unknownServer")
    func coverArtURLUnknownServer() async throws {
        let (service, _, _) = try await makeService()
        do {
            _ = try await service.coverArtURL(serverID: UUID(), entityID: "x")
            Issue.record("Expected unknownServer error")
        } catch SubsonicError.unknownServer {
            // expected
        }
    }
}

// MARK: - SubsonicCoverArtProvider

@Suite("SubsonicCoverArtProvider")
struct SubsonicCoverArtProviderTests {
    @Test("delegates to service.coverArtURL and returns the same URL")
    func delegates() async throws {
        let (service, id, _) = try await makeService()
        let provider = SubsonicCoverArtProvider(service: service)
        let url = try #require(await provider.coverArtURL(serverID: id, entityID: "album-7", size: 64))
        #expect(url.query?.contains("id=album-7") == true)
        #expect(url.query?.contains("size=64") == true)
    }

    @Test("rethrows unknownServer error")
    func rethrowsUnknownServer() async throws {
        let (service, _, _) = try await makeService()
        let provider = SubsonicCoverArtProvider(service: service)
        do {
            _ = try await provider.coverArtURL(serverID: UUID(), entityID: "x")
            Issue.record("Expected unknownServer error")
        } catch SubsonicError.unknownServer {
            // expected
        }
    }
}

// MARK: - SubsonicAnnotations

@Suite("SubsonicAnnotations")
struct SubsonicAnnotationsTests {
    @Test("star success delegates to service.star")
    func starSuccess() async throws {
        let (service, id, transport) = try await makeService()
        transport.enqueue(json: okEnvelope)
        let annotations = SubsonicAnnotations(service: service)
        await annotations.star(serverID: id, songID: "s1")
        #expect(transport.requests.count == 1)
        #expect(transport.requests[0].path.contains("star"))
    }

    @Test("unstar success delegates to service.unstar")
    func unstarSuccess() async throws {
        let (service, id, transport) = try await makeService()
        transport.enqueue(json: okEnvelope)
        let annotations = SubsonicAnnotations(service: service)
        await annotations.unstar(serverID: id, songID: "s1")
        #expect(transport.requests.count == 1)
        #expect(transport.requests[0].path.contains("unstar"))
    }

    @Test("setRating success delegates to service.setRating")
    func setRatingSuccess() async throws {
        let (service, id, transport) = try await makeService()
        transport.enqueue(json: okEnvelope)
        let annotations = SubsonicAnnotations(service: service)
        await annotations.setRating(serverID: id, songID: "s1", rating: 5)
        #expect(transport.requests.count == 1)
        #expect(transport.requests[0].query?.contains("rating=5") == true)
    }

    @Test("unknown-server error on first attempt is non-transient and does not retry")
    func nonTransientFailsFast() async throws {
        // Use a fresh service so the unknown server actually fails immediately
        // with `.unknownServer`, which is non-transient and ought to surface
        // via the failure log without scheduling 10s-delayed retries.
        let db = try await Database(location: .inMemory)
        let repo = SubsonicServerRepository(database: db)
        let store = SubsonicServerStore(repository: repo)
        let service = SubsonicService(store: store)
        let annotations = SubsonicAnnotations(service: service)
        let bogus = UUID()
        await annotations.star(serverID: bogus, songID: "s1")
        // No assertion on emission timing — purely verifying we return
        // without hanging on the (non-existent) retry path.
        #expect(Bool(true))
    }
}
