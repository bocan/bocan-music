import Foundation

/// Matches an incoming request to a registered route and dispatches it, applying
/// the pre-pairing vs paired authorization rule (sync-protocol.md section 6).
///
/// Path templates use `{name}` segments for captures (for example
/// `/v1/file/track/{trackId}`); matching is a plain split on `/`, no regex, so a
/// request path never names a filesystem path.
struct Router {
    enum Auth {
        /// Available to any successfully handshaked peer (ping, pairing).
        case anyTLS
        /// Requires a trusted (paired) connection.
        case paired
    }

    struct Route {
        let method: String
        let template: [String]
        let auth: Auth
        let handler: @Sendable (HttpRequest, RouteMatch) async -> HttpResponse

        init(
            _ method: String,
            _ path: String,
            auth: Auth,
            handler: @escaping @Sendable (HttpRequest, RouteMatch) async -> HttpResponse
        ) {
            self.method = method.uppercased()
            self.template = Router.segments(of: path)
            self.auth = auth
            self.handler = handler
        }
    }

    struct RouteMatch {
        let parameters: [String: String]
        let context: ConnectionContext
    }

    private let routes: [Route]

    init(routes: [Route]) {
        self.routes = routes
    }

    func dispatch(_ request: HttpRequest, context: ConnectionContext) async -> HttpResponse {
        let requestSegments = Self.segments(of: request.path)
        var pathMatched = false

        for route in self.routes {
            guard let parameters = Self.match(template: route.template, path: requestSegments) else {
                continue
            }
            pathMatched = true
            guard route.method == request.method else {
                continue
            }
            if route.auth == .paired, !context.isTrusted {
                return .error(.notPaired, message: "Not paired", status: 403)
            }
            return await route.handler(request, RouteMatch(parameters: parameters, context: context))
        }

        if pathMatched {
            return .error(.internal, message: "Method not allowed", status: 405)
        }
        return .error(.notFound, message: "Not found", status: 404)
    }

    // MARK: - Path matching

    private static func segments(of path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    private static func match(template: [String], path: [String]) -> [String: String]? {
        guard template.count == path.count else {
            return nil
        }
        var parameters: [String: String] = [:]
        for (templateSegment, pathSegment) in zip(template, path) {
            if templateSegment.hasPrefix("{"), templateSegment.hasSuffix("}") {
                parameters[String(templateSegment.dropFirst().dropLast())] = pathSegment
            } else if templateSegment != pathSegment {
                return nil
            }
        }
        return parameters
    }
}
