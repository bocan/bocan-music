import Crypto
import Foundation
import Persistence
import Podcasts
import Testing
@testable import SyncServer

@Suite("FileServing")
struct FileServingTests {
    // MARK: - Router-level (logic, no sockets)

    private func trustedContext() -> ConnectionContext {
        let context = ConnectionContext()
        context.recordPeer(certificateDER: Data([0x01]), fingerprint: "aa", isPairing: false, isTrusted: true)
        return context
    }

    private func get(_ router: Router, _ path: String, headers: [String: String] = [:]) async -> HttpResponse {
        await router.dispatch(
            HttpRequest(method: "GET", path: path, query: [:], headers: headers, body: Data()),
            context: self.trustedContext()
        )
    }

    private func router(_ database: Database, downloadRoot: URL? = nil) -> Router {
        Router(routes: FileServing(database: database, downloadRoot: downloadRoot).routes())
    }

    @Test("unknown, non-numeric, and disabled track ids all 404")
    func trackNotFound() async throws {
        let database = try await Database(location: .inMemory)
        let tracks = TrackRepository(database: database)
        let disabledId = try await tracks.insert(Track(fileURL: "file:///x.flac", disabled: true, addedAt: 0, updatedAt: 0))
        let router = self.router(database)

        #expect(await self.get(router, "/v1/file/track/999").status == 404)
        #expect(await self.get(router, "/v1/file/track/abc").status == 404)
        #expect(await self.get(router, "/v1/file/track/\(disabledId)").status == 404)
    }

    @Test("If-Match against the wrong content hash returns 412")
    func ifMatchMismatch() async throws {
        let database = try await Database(location: .inMemory)
        let tracks = TrackRepository(database: database)
        let trackId = try await tracks.insert(Track(fileURL: "file:///x.flac", contentHash: "correct", addedAt: 0, updatedAt: 0))
        let response = await self.get(self.router(database), "/v1/file/track/\(trackId)", headers: ["if-match": "wrong"])
        #expect(response.status == 412)
    }

    @Test("chapters and an undownloaded episode return 404")
    func chaptersAndMissingEpisode() async throws {
        let database = try await Database(location: .inMemory)
        let router = self.router(database)
        #expect(await self.get(router, "/v1/chapters/abc").status == 404)
        #expect(await self.get(router, "/v1/file/episode/deadbeef").status == 404)
    }

    @Test("lyrics are served as the section-8 document")
    func lyricsDocument() async throws {
        let database = try await Database(location: .inMemory)
        let tracks = TrackRepository(database: database)
        let lyrics = LyricsRepository(database: database)
        let trackId = try await tracks.insert(Track(fileURL: "file:///l.flac", contentHash: "aa", addedAt: 0, updatedAt: 0))
        try await lyrics.save(Lyrics(trackID: trackId, lyricsText: "[00:12.00]Hello", isSynced: true, source: "user"))

        let response = await self.get(self.router(database), "/v1/lyrics/\(trackId)")
        #expect(response.status == 200)
        struct Payload: Decodable { let trackId: Int64
            let kind: String
            let text: String
        }
        let payload = try JSONDecoder().decode(Payload.self, from: response.body)
        #expect(payload.trackId == trackId)
        #expect(payload.kind == "synced")
        #expect(payload.text.contains("Hello"))

        #expect(await self.get(self.router(database), "/v1/lyrics/999").status == 404)
    }

    // MARK: - Loopback (actual streamed bytes over TLS)

    private func header(_ headers: [AnyHashable: Any], _ name: String) -> String? {
        for (key, value) in headers where (key as? String)?.lowercased() == name.lowercased() {
            return value as? String
        }
        return nil
    }

    @Test("serves track bytes in full and resumes with a Range request")
    func trackStreaming() async throws {
        let server = try await LoopbackFileServer.make()
        defer { Task { await server.teardown() } }

        let audioURL = server.scratch.appendingPathComponent("track.flac")
        let bytes = Data((0 ..< 5000).map { UInt8($0 % 251) })
        try bytes.write(to: audioURL)
        let bookmark = try audioURL.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let trackId = try await TrackRepository(database: server.database).insert(Track(
            fileURL: audioURL.absoluteString, fileBookmark: bookmark, fileFormat: "flac",
            contentHash: "hash123", addedAt: 0, updatedAt: 0
        ))

        let full = try await server.client.request(port: server.port, path: "/v1/file/track/\(trackId)")
        #expect(full.status == 200)
        #expect(full.body == bytes)
        #expect(self.header(full.headers, "etag") == "hash123")
        #expect(self.header(full.headers, "accept-ranges") == "bytes")

        let ranged = try await server.client.request(
            port: server.port, path: "/v1/file/track/\(trackId)", headers: ["Range": "bytes=2000-"]
        )
        #expect(ranged.status == 206)
        #expect(ranged.body == Data(bytes[2000...]))
        #expect(self.header(ranged.headers, "content-range") == "bytes 2000-4999/5000")
    }

    @Test("serves a downloaded episode, and an encoded path-traversal id 404s")
    func episodeStreamingAndTraversal() async throws {
        let server = try await LoopbackFileServer.make()
        defer { Task { await server.teardown() } }

        let podcasts = PodcastRepository(database: server.database)
        let episodes = EpisodeRepository(database: server.database)
        let states = EpisodeStateRepository(database: server.database)
        let podcastId = try await podcasts.insert(Podcast(feedURL: "https://x.test/feed", title: "Show", subscribed: true, addedAt: 0))
        let guid = "https://x.test/ep/1"
        _ = try await episodes.upsert(PodcastEpisode(
            podcastID: podcastId,
            guid: guid,
            title: "E1",
            audioURL: "u",
            audioMIME: "audio/mpeg",
            addedAt: 0
        ))

        let store = DownloadStore(root: server.downloadRoot)
        let fileURL = store.fileURL(podcastID: podcastId, guid: guid, mime: "audio/mpeg")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data((0 ..< 4000).map { UInt8($0 % 251) })
        try bytes.write(to: fileURL)
        let episodeHash = "ep64hashep64hashep64hashep64hashep64hashep64hashep64hashep64hash"
        try await states.setDownloadState(
            podcastID: podcastId,
            guid: guid,
            state: .downloaded,
            path: fileURL.path,
            bytes: Int64(bytes.count),
            hash: episodeHash
        )

        let episodeId = fileURL.deletingPathExtension().lastPathComponent
        let full = try await server.client.request(port: server.port, path: "/v1/file/episode/\(episodeId)")
        #expect(full.status == 200)
        #expect(full.body == bytes)
        #expect(self.header(full.headers, "etag") == episodeHash)

        let ranged = try await server.client.request(
            port: server.port, path: "/v1/file/episode/\(episodeId)", headers: ["Range": "bytes=1000-1999"]
        )
        #expect(ranged.status == 206)
        #expect(ranged.body == Data(bytes[1000 ... 1999]))

        // If-Match against the stored episode hash: 412 on mismatch.
        let stale = try await server.client.request(
            port: server.port, path: "/v1/file/episode/\(episodeId)", headers: ["If-Match": "wrong"]
        )
        #expect(stale.status == 412)

        // An encoded traversal decodes to extra path segments and never matches.
        let traversal = try await server.client.request(port: server.port, path: "/v1/file/track/..%2f..%2fetc%2fpasswd")
        #expect(traversal.status == 404)
    }

    @Test("serves cover artwork by content hash")
    func artwork() async throws {
        let server = try await LoopbackFileServer.make()
        defer { Task { await server.teardown() } }

        let imageURL = server.scratch.appendingPathComponent("art.png")
        let bytes = Data((0 ..< 800).map { UInt8($0 % 251) })
        try bytes.write(to: imageURL)
        _ = try await CoverArtRepository(database: server.database).save(CoverArt(hash: "arthash", path: imageURL.path, format: "png"))

        let response = try await server.client.request(port: server.port, path: "/v1/artwork/arthash")
        #expect(response.status == 200)
        #expect(response.body == bytes)
        #expect(self.header(response.headers, "etag") == "arthash")

        let missing = try await server.client.request(port: server.port, path: "/v1/artwork/nope")
        #expect(missing.status == 404)
    }

    @Test("serves podcast show art through the artwork fallback (22-10)")
    func podcastArtworkFallback() async throws {
        let server = try await LoopbackFileServer.make()
        defer { Task { await server.teardown() } }

        let podcasts = PodcastRepository(database: server.database)
        let imageURL = server.scratch.appendingPathComponent("show.jpg")
        let bytes = Data((0 ..< 600).map { UInt8($0 % 251) })
        try bytes.write(to: imageURL)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let podcastId = try await podcasts.insert(Podcast(feedURL: "https://x.test/feed", title: "Show", subscribed: true, addedAt: 0))
        try await podcasts.setArtwork(id: podcastId, path: imageURL.path, hash: hash)

        // The podcast fallback serves the bytes with the same header contract
        // as cover art: etag == hash, immutable cache, extension-derived MIME.
        let response = try await server.client.request(port: server.port, path: "/v1/artwork/\(hash)")
        #expect(response.status == 200)
        #expect(response.body == bytes)
        #expect(self.header(response.headers, "etag") == hash)
        #expect(self.header(response.headers, "content-type") == "image/jpeg")
        #expect(self.header(response.headers, "cache-control")?.contains("immutable") == true)

        // A stored hash whose file is gone is a 404, not a 500.
        try FileManager.default.removeItem(at: imageURL)
        let gone = try await server.client.request(port: server.port, path: "/v1/artwork/\(hash)")
        #expect(gone.status == 404)

        // The fallback resolves only through the artwork_hash column: an
        // encoded traversal is just a hash that matches no row (22-6 rule).
        let traversal = try await server.client.request(port: server.port, path: "/v1/artwork/..%2f..%2fetc%2fpasswd")
        #expect(traversal.status == 404)
    }
}

/// A loopback server wired to `FileServing`, with a trusted client and a scratch
/// directory. Test-only.
private struct LoopbackFileServer {
    let database: Database
    let port: UInt16
    let client: LoopbackClient
    let listener: SyncListener
    let serverStore: KeychainIdentityStore
    let clientStore: KeychainIdentityStore
    let scratch: URL
    let downloadRoot: URL

    static func make() async throws -> LoopbackFileServer {
        let database = try await Database(location: .inMemory)
        let serverStore = KeychainIdentityStore(service: "io.cloudcauldron.bocan.sync.test.server.\(UUID().uuidString)")
        let clientStore = KeychainIdentityStore(service: "io.cloudcauldron.bocan.sync.test.client.\(UUID().uuidString)")
        let serverIdentity = ServerIdentity(store: serverStore)
        let clientMaterial = try clientStore.loadOrCreate()
        let clientIdentity = try clientStore.secIdentity(for: clientMaterial)
        let clientFingerprint = ServerFingerprint(certificateDER: clientMaterial.certificateDER).hex

        let trusted = TrustedFingerprintSet()
        trusted.replace(with: [clientFingerprint])

        let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sync-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let downloadRoot = scratch.appendingPathComponent("downloads")

        let router = Router(routes: FileServing(database: database, downloadRoot: downloadRoot).routes())
        let listener = SyncListener(identity: serverIdentity, router: router, trusted: trusted, pairingMode: { false })
        let port = try await listener.start()

        return LoopbackFileServer(
            database: database, port: port, client: LoopbackClient(clientIdentity: clientIdentity),
            listener: listener, serverStore: serverStore, clientStore: clientStore,
            scratch: scratch, downloadRoot: downloadRoot
        )
    }

    func teardown() async {
        await self.listener.stop()
        self.serverStore.deleteAll()
        self.clientStore.deleteAll()
        try? FileManager.default.removeItem(at: self.scratch)
    }
}
