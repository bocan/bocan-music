import Foundation
import Security

/// A loopback HTTPS client for the TLS tests: presents a client certificate and
/// trusts the self-signed server. Each `request` uses a fresh session so every
/// call is a fresh TLS handshake (no keep-alive reuse across admission changes).
final class LoopbackClient: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let clientIdentity: SecIdentity

    init(clientIdentity: SecIdentity) {
        self.clientIdentity = clientIdentity
    }

    func request(
        port: UInt16,
        path: String,
        method: String = "GET",
        body: Data? = nil
    ) async throws -> (status: Int, body: Data) {
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: URL(string: "https://127.0.0.1:\(port)\(path)")!)
        request.timeoutInterval = 10
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? -1, data)
    }

    func urlSession(
        _: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            if let trust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        case NSURLAuthenticationMethodClientCertificate:
            completionHandler(
                .useCredential,
                URLCredential(identity: self.clientIdentity, certificates: nil, persistence: .forSession)
            )
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
