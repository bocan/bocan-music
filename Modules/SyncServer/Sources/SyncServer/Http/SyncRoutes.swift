import Foundation

/// Builders for the Phone Sync endpoints. Each phase-22 slice adds its routes
/// here; this slice provides `/v1/ping`, the only endpoint available to any
/// handshaked peer (pairing or paired).
enum SyncRoutes {
    /// `GET /v1/ping` -> `{ protocolVersion, serverId, generation }`
    /// (sync-protocol.md section 6). `serverId` and `generation` are injected;
    /// phase 22-5 wires them to the `sync_meta` store.
    static func ping(
        serverId: @escaping @Sendable () async -> String,
        generation: @escaping @Sendable () async -> Int
    ) -> Router.Route {
        Router.Route("GET", "/v1/ping", auth: .anyTLS) { _, _ in
            let identifier = await serverId()
            let generationValue = await generation()
            let escaped = identifier
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let json = "{\"protocolVersion\":1,\"serverId\":\"\(escaped)\",\"generation\":\(generationValue)}"
            return .json(data: Data(json.utf8))
        }
    }
}
