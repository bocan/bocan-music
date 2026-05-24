import Foundation
import Testing
@testable import AudioEngine

/// Tests are serialized because they mutate `URLProtocolStub`'s static handlers.
@Suite("URLSessionHTTPTransport", .serialized)
struct URLSessionHTTPTransportTests {
    @Test("200 streams body and surfaces Content-Length as totalBytes")
    func happyPath() async throws {
        let body = Data(repeating: 0x42, count: 4096)
        let session = URLProtocolStub.session(status: 200, body: body)
        let transport = URLSessionHTTPTransport(session: session)
        let req = try URLRequest(url: #require(URL(string: "https://example.test/stream")))

        let bytes = try await transport.bytes(for: req)
        #expect(bytes.totalBytes == Int64(body.count))

        var collected = Data()
        for try await chunk in bytes.stream {
            collected.append(chunk)
        }
        #expect(collected == body)
    }

    @Test("401 throws .unauthorized")
    func unauthorized() async throws {
        let session = URLProtocolStub.session(status: 401, body: Data())
        let transport = URLSessionHTTPTransport(session: session)
        let req = try URLRequest(url: #require(URL(string: "https://example.test/stream")))

        await #expect(throws: RemoteTrackLoaderError.unauthorized) {
            _ = try await transport.bytes(for: req)
        }
    }

    @Test("403 throws .gone")
    func gone403() async throws {
        let session = URLProtocolStub.session(status: 403, body: Data())
        let transport = URLSessionHTTPTransport(session: session)
        let req = try URLRequest(url: #require(URL(string: "https://example.test/stream")))

        await #expect(throws: RemoteTrackLoaderError.gone) {
            _ = try await transport.bytes(for: req)
        }
    }

    @Test("410 throws .gone")
    func gone410() async throws {
        let session = URLProtocolStub.session(status: 410, body: Data())
        let transport = URLSessionHTTPTransport(session: session)
        let req = try URLRequest(url: #require(URL(string: "https://example.test/stream")))

        await #expect(throws: RemoteTrackLoaderError.gone) {
            _ = try await transport.bytes(for: req)
        }
    }

    @Test("500 throws .server with status code")
    func serverError() async throws {
        let session = URLProtocolStub.session(status: 500, body: Data())
        let transport = URLSessionHTTPTransport(session: session)
        let req = try URLRequest(url: #require(URL(string: "https://example.test/stream")))

        await #expect(throws: RemoteTrackLoaderError.server(statusCode: 500)) {
            _ = try await transport.bytes(for: req)
        }
    }

    @Test("URLError.cancelled is mapped to .cancelled")
    func cancelled() async throws {
        let session = URLProtocolStub.errorSession(URLError(.cancelled))
        let transport = URLSessionHTTPTransport(session: session)
        let req = try URLRequest(url: #require(URL(string: "https://example.test/stream")))

        await #expect(throws: RemoteTrackLoaderError.cancelled) {
            _ = try await transport.bytes(for: req)
        }
    }

    @Test("generic URLError is mapped to .transport")
    func transportFailure() async throws {
        let session = URLProtocolStub.errorSession(URLError(.notConnectedToInternet))
        let transport = URLSessionHTTPTransport(session: session)
        let req = try URLRequest(url: #require(URL(string: "https://example.test/stream")))

        do {
            _ = try await transport.bytes(for: req)
            Issue.record("Expected throw")
        } catch let error as RemoteTrackLoaderError {
            guard case .transport = error else {
                Issue.record("Expected .transport, got \(error)")
                return
            }
        }
    }
}

// MARK: - URLProtocol stub

private final class URLProtocolStub: URLProtocol {
    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var body: Data = .init()
    nonisolated(unsafe) static var error: Error?

    static func session(status: Int, body: Data) -> URLSession {
        self.statusCode = status
        Self.body = body
        self.error = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: config)
    }

    static func errorSession(_ error: Error) -> URLSession {
        Self.error = error
        self.statusCode = 0
        self.body = .init()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: config)
    }

    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        if let error = Self.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let headers = ["Content-Length": "\(Self.body.count)"]
        let resp = HTTPURLResponse(
            url: request.url!, // swiftlint:disable:this force_unwrapping
            statusCode: Self.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )! // swiftlint:disable:this force_unwrapping
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
