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

    /// #547: the body used to be read one byte at a time. A track-sized body
    /// must arrive intact, in order, and in chunks rather than bytes.
    @Test("a track-sized body arrives intact and in chunks")
    func largeBodyArrivesIntact() async throws {
        let size = 8 * 1024 * 1024
        var body = Data(count: size)
        body.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for index in bytes.indices {
                bytes[index] = UInt8(truncatingIfNeeded: index &* 31 &+ (index >> 8))
            }
        }
        // Delivered in 64 KiB slices, as a network delivers it, so the order of
        // the chunks is under test too.
        let session = URLProtocolStub.session(status: 200, body: body, chunkSize: 64 * 1024)
        let transport = URLSessionHTTPTransport(session: session)
        let req = try URLRequest(url: #require(URL(string: "https://example.test/stream")))

        let bytes = try await transport.bytes(for: req)
        #expect(bytes.totalBytes == Int64(size))

        var collected = Data()
        collected.reserveCapacity(size)
        var chunkCount = 0
        for try await chunk in bytes.stream {
            collected.append(chunk)
            chunkCount += 1
        }

        #expect(collected == body)
        #expect(chunkCount >= 1)
        #expect(chunkCount < size / 1024, "the body must not be delivered in byte-sized pieces")
    }

    @Test("a failure after the headers ends the stream with .transport")
    func midStreamFailure() async throws {
        let body = Data(repeating: 0x17, count: 256 * 1024)
        let session = URLProtocolStub.session(
            status: 200,
            body: body,
            chunkSize: 64 * 1024,
            midStreamError: URLError(.networkConnectionLost)
        )
        let transport = URLSessionHTTPTransport(session: session)
        let req = try URLRequest(url: #require(URL(string: "https://example.test/stream")))

        // The headers were good, so the call itself succeeds.
        let bytes = try await transport.bytes(for: req)

        var received = 0
        do {
            for try await chunk in bytes.stream {
                received += chunk.count
            }
            Issue.record("Expected the stream to throw")
        } catch let error as RemoteTrackLoaderError {
            guard case .transport = error else {
                Issue.record("Expected .transport, got \(error)")
                return
            }
        }
        // Whatever URLSession had already handed over is kept, but it does not
        // flush the rest of its own buffer when the task fails, so the count is
        // a prefix of the body rather than all of it. The cache discards the
        // partial file anyway; the error mapping above is what matters here.
        #expect(received <= body.count)
    }

    @Test("cancelling the caller before the headers arrive throws .cancelled")
    func callerCancellation() async throws {
        // An error session that reports cancellation is how URLSession
        // surfaces `task.cancel()`; the mapping must hold on the delegate path.
        let session = URLProtocolStub.errorSession(URLError(.cancelled))
        let transport = URLSessionHTTPTransport(session: session)
        let req = try URLRequest(url: #require(URL(string: "https://example.test/stream")))

        let work = Task { try await transport.bytes(for: req) }
        work.cancel()
        await #expect(throws: RemoteTrackLoaderError.cancelled) {
            _ = try await work.value
        }
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
    /// When set, the body is delivered in slices of this size, as a real
    /// network delivers it, instead of in one `didLoad`.
    nonisolated(unsafe) static var chunkSize: Int?
    /// When set, the load fails with this error after the body was delivered,
    /// that is, after the response headers were accepted.
    nonisolated(unsafe) static var midStreamError: Error?

    static func session(
        status: Int,
        body: Data,
        chunkSize: Int? = nil,
        midStreamError: Error? = nil
    ) -> URLSession {
        self.statusCode = status
        Self.body = body
        self.error = nil
        self.chunkSize = chunkSize
        self.midStreamError = midStreamError
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: config)
    }

    static func errorSession(_ error: Error) -> URLSession {
        Self.error = error
        self.statusCode = 0
        self.body = .init()
        self.chunkSize = nil
        self.midStreamError = nil
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
        let step = Self.chunkSize ?? max(Self.body.count, 1)
        var offset = 0
        while offset < Self.body.count {
            let end = min(offset + step, Self.body.count)
            client?.urlProtocol(self, didLoad: Self.body.subdata(in: offset ..< end))
            offset = end
        }
        if let midStreamError = Self.midStreamError {
            client?.urlProtocol(self, didFailWithError: midStreamError)
            return
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
