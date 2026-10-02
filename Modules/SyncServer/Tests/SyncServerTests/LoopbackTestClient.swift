import Foundation
import Security
import Testing

/// What `LoopbackClient.request` got back: the status (-1 when the response
/// is not HTTP), the body and the response headers.
struct LoopbackResponse {
    let status: Int
    let body: Data
    let headers: [AnyHashable: Any]
}

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
        body: Data? = nil,
        headers: [String: String] = [:]
    ) async throws -> LoopbackResponse {
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        // `#require` records a test failure; a plain throw could pass for the
        // refused handshake that some of these tests expect.
        var request = try URLRequest(url: #require(URL(string: "https://127.0.0.1:\(port)\(path)")))
        request.timeoutInterval = 10
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        return LoopbackResponse(status: http?.statusCode ?? -1, body: data, headers: http?.allHeaderFields ?? [:])
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
