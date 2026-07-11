import Foundation

/// Builds the `/v1/pair/*` routes. Both are available to any handshaked peer
/// (pre-pairing); the `PairingCoordinator` enforces the pairing-mode state, and
/// the peer identity always comes from the TLS layer via `ConnectionContext`,
/// never the JSON body.
enum PairingRoutes {
    static func routes(coordinator: PairingCoordinator) -> [Router.Route] {
        [
            Router.Route("POST", "/v1/pair/start", auth: .anyTLS) { request, match in
                await Self.start(request: request, context: match.context, coordinator: coordinator)
            },
            Router.Route("POST", "/v1/pair/confirm", auth: .anyTLS) { request, _ in
                await Self.confirm(request: request, coordinator: coordinator)
            },
        ]
    }

    private static func start(
        request: HttpRequest,
        context: ConnectionContext,
        coordinator: PairingCoordinator
    ) async -> HttpResponse {
        guard
            let fingerprint = context.peerFingerprint,
            let certDER = context.peerCertificateDER else {
            return .error(.internal, message: "No client certificate", status: 400)
        }
        let start: PairStart
        do {
            start = try JSONDecoder().decode(PairStart.self, from: request.body)
        } catch {
            return .error(.internal, message: "Malformed body", status: 400)
        }
        do {
            let response = try await coordinator.start(
                request: start,
                peerFingerprint: fingerprint,
                peerCertDER: certDER
            )
            return try .json(data: JSONEncoder().encode(response))
        } catch {
            return Self.mapError(error)
        }
    }

    private static func confirm(
        request: HttpRequest,
        coordinator: PairingCoordinator
    ) async -> HttpResponse {
        let confirm: PairConfirm
        do {
            confirm = try JSONDecoder().decode(PairConfirm.self, from: request.body)
        } catch {
            return .error(.internal, message: "Malformed body", status: 400)
        }
        do {
            let response = try await coordinator.confirm(request: confirm)
            return try .json(data: JSONEncoder().encode(response))
        } catch {
            return Self.mapError(error)
        }
    }

    private static func mapError(_ error: any Error) -> HttpResponse {
        guard let pairingError = error as? PairingError else {
            return .error(.internal, message: "Internal error", status: 500)
        }
        switch pairingError {
        case .expired:
            return .error(.pairingExpired, message: "Pairing expired", status: 410)
        case .badProof:
            return .error(.badProof, message: "Bad proof", status: 403)
        case .rateLimited:
            return .error(.rateLimited, message: "Too many attempts", status: 429)
        case .badRequest:
            return .error(.internal, message: "Bad request", status: 400)
        }
    }
}
