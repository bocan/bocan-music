import Foundation
import Observability
import SwiftSonic

// MARK: - SubsonicMetricsRelay

/// Bridges `SwiftSonicRequestEvent` metrics into Bòcan's observability layer.
///
/// Pass an instance as `metricsCollector:` when building each `SwiftSonicClient`.
/// This gives us per-endpoint duration tracking, retry visibility, and failure
/// logging, all surfaced in Console.app and Instruments via `os.Logger`.
final class SubsonicMetricsRelay: SwiftSonicMetricsCollector, @unchecked Sendable {
    let serverName: String
    let log: AppLogger

    init(serverName: String) {
        self.serverName = serverName
        self.log = AppLogger.make(.subsonic)
    }

    func record(_ event: SwiftSonicRequestEvent) {
        switch event {
        case let .started(endpoint, _):
            self.log.trace(
                "subsonic.request.start",
                ["server": self.serverName, "endpoint": endpoint]
            )

        case let .succeeded(endpoint, _, duration):
            self.log.debug(
                "subsonic.request.ok",
                ["server": self.serverName, "endpoint": endpoint, "ms": Int(duration * 1000)]
            )

        case let .failed(endpoint, _, error, attempt):
            self.log.warning(
                "subsonic.request.fail",
                [
                    "server": self.serverName,
                    "endpoint": endpoint,
                    "attempt": attempt,
                    "err": error.localizedDescription,
                ]
            )

        case let .retryScheduled(endpoint, attempt, delay):
            self.log.info(
                "subsonic.request.retry",
                [
                    "server": self.serverName,
                    "endpoint": endpoint,
                    "attempt": attempt + 1,
                    "delay_ms": Int(delay * 1000),
                ]
            )
        }
    }
}

// MARK: - TrustBypassTransport

/// A custom `HTTPTransport` that allows a single named host to present a
/// self-signed TLS certificate. The exemption is host-scoped: no global
/// policy is changed.
final class TrustBypassTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession
    private let host: String

    init(host: String) {
        self.host = host
        let config = URLSessionConfiguration.ephemeral
        self.session = URLSession(
            configuration: config,
            delegate: HostTrustDelegate(host: host),
            delegateQueue: nil
        )
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

private final class HostTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    let host: String

    init(host: String) {
        self.host = host
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == self.host,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
