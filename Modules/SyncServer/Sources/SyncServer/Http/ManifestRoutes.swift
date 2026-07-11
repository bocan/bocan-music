import Foundation
import Persistence

/// Builds the `/v1/ping` and `/v1/manifest` routes, wired to the live
/// `sync_meta` server id and generation. Phase 22-7 assembles these with the
/// pairing and file routes into the running server.
enum ManifestRoutes {
    static func routes(
        builder: ManifestBuilder,
        profileRepository: SyncProfileRepository,
        syncMeta: SyncMetaRepository,
        serverName: @escaping @Sendable () -> String,
        now: @escaping @Sendable () -> Date = Date.init
    ) -> [Router.Route] {
        [
            Router.Route("GET", "/v1/ping", auth: .anyTLS) { _, _ in
                let serverId = await (try? syncMeta.serverId()) ?? ""
                let generation = await (try? syncMeta.generation()) ?? 0
                let escaped = serverId
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                let json = "{\"protocolVersion\":1,\"serverId\":\"\(escaped)\",\"generation\":\(generation)}"
                return .json(data: Data(json.utf8))
            },
            Router.Route("GET", "/v1/manifest", auth: .paired) { request, _ in
                do {
                    let profile = await Self.loadProfile(profileRepository)
                    let serverId = try await syncMeta.serverId()
                    let generation = try await syncMeta.generation()
                    let manifest = try await builder.build(
                        profile: profile,
                        serverId: serverId,
                        serverName: serverName(),
                        generation: generation,
                        generatedAt: now()
                    )
                    let data = try JSONEncoder().encode(manifest)
                    // Gzip the manifest when the client asks for it (protocol s7).
                    if request.header("accept-encoding")?.lowercased().contains("gzip") == true,
                       let gzipped = Gzip.compress(data) {
                        return HttpResponse(
                            status: 200,
                            headers: ["content-type": "application/json", "content-encoding": "gzip"],
                            body: gzipped
                        )
                    }
                    return .json(data: data)
                } catch {
                    return .error(.internal, message: "Manifest unavailable", status: 500)
                }
            },
        ]
    }

    /// The persisted profile, or the default (everything, podcasts included).
    static func loadProfile(_ repository: SyncProfileRepository) async -> SyncProfile {
        guard
            let data = try? await repository.profileJSON(),
            let profile = try? JSONDecoder().decode(SyncProfile.self, from: data) else {
            return .default
        }
        return profile
    }
}
