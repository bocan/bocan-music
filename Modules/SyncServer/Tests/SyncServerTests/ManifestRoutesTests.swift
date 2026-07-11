import Foundation
import Persistence
import Testing
@testable import SyncServer

@Suite("ManifestRoutes")
struct ManifestRoutesTests {
    private func trustedContext() -> ConnectionContext {
        let context = ConnectionContext()
        context.recordPeer(certificateDER: Data([0x01]), fingerprint: "aa", isPairing: false, isTrusted: true)
        return context
    }

    private func request(_ path: String) -> HttpRequest {
        HttpRequest(method: "GET", path: path, query: [:], headers: [:], body: Data())
    }

    private func makeRouter(_ database: Database) -> Router {
        Router(routes: ManifestRoutes.routes(
            builder: ManifestBuilder(database: database),
            profileRepository: SyncProfileRepository(database: database),
            syncMeta: SyncMetaRepository(database: database),
            serverName: { "Test Mac" },
            now: { Date(timeIntervalSince1970: 0) }
        ))
    }

    @Test("the manifest route builds a manifest for a paired connection")
    func manifestForPaired() async throws {
        let database = try await Database(location: .inMemory)
        _ = try await LibraryRootRepository(database: database).upsert(LibraryRoot(path: "/Music", bookmark: Data([0x01]), addedAt: 0))
        _ = try await TrackRepository(database: database).insert(Track(
            fileURL: URL(fileURLWithPath: "/Music/a.flac").absoluteString,
            fileFormat: "flac", contentHash: "aa", addedAt: 0, updatedAt: 0
        ))

        let response = await self.makeRouter(database).dispatch(self.request("/v1/manifest"), context: self.trustedContext())
        #expect(response.status == 200)
        let manifest = try JSONDecoder().decode(Manifest.self, from: response.body)
        #expect(manifest.tracks.count == 1)
        #expect(manifest.serverName == "Test Mac")
        #expect(!manifest.serverId.isEmpty)
    }

    @Test("the manifest is gzipped when the client sends Accept-Encoding: gzip")
    func manifestGzip() async throws {
        let database = try await Database(location: .inMemory)
        _ = try await LibraryRootRepository(database: database).upsert(LibraryRoot(path: "/Music", bookmark: Data([0x01]), addedAt: 0))
        _ = try await TrackRepository(database: database).insert(Track(
            fileURL: URL(fileURLWithPath: "/Music/a.flac").absoluteString,
            fileFormat: "flac", contentHash: "aa", addedAt: 0, updatedAt: 0
        ))

        let request = HttpRequest(
            method: "GET",
            path: "/v1/manifest",
            query: [:],
            headers: ["accept-encoding": "gzip"],
            body: Data()
        )
        let response = await self.makeRouter(database).dispatch(request, context: self.trustedContext())

        #expect(response.status == 200)
        #expect(response.headers["content-encoding"] == "gzip")
        let inflated = try #require(TestGunzip.inflate(response.body))
        let manifest = try JSONDecoder().decode(Manifest.self, from: inflated)
        #expect(manifest.tracks.count == 1)
    }

    @Test("the manifest route rejects an unpaired connection")
    func manifestRejectsUnpaired() async throws {
        let database = try await Database(location: .inMemory)
        let response = await self.makeRouter(database).dispatch(self.request("/v1/manifest"), context: ConnectionContext())
        #expect(response.status == 403)
    }

    @Test("ping reports the server id and generation from sync_meta")
    func pingReportsGeneration() async throws {
        let database = try await Database(location: .inMemory)
        let syncMeta = SyncMetaRepository(database: database)
        _ = try await syncMeta.bumpGeneration()
        _ = try await syncMeta.bumpGeneration()

        let response = await self.makeRouter(database).dispatch(self.request("/v1/ping"), context: self.trustedContext())
        #expect(response.status == 200)
        let body = String(data: response.body, encoding: .utf8) ?? ""
        #expect(body.contains("\"generation\":2"))
        #expect(body.contains("\"protocolVersion\":1"))
    }
}
