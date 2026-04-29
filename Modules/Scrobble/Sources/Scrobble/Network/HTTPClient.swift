import Foundation

// MARK: - HTTPClient

/// Abstraction over `URLSession` so unit tests can inject a stub without
/// hitting the network. Mirrors the protocol used elsewhere in the codebase
/// (Acoustics, Library) deliberately so test patterns transfer.
public protocol HTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPClient {
    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await self.data(for: request, delegate: nil)
    }
}
