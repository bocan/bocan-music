import Network
import XCTest

// MARK: - E2EStreamServerTests

/// Verifies `E2EStreamServer`'s wire format directly, byte-for-byte, over a
/// raw loopback socket — deliberately not through `AudioEngine`/FFmpeg.
/// Bugs in this layer would otherwise surface three steps away, as an
/// opaque FFmpeg decode failure inside a full radio E2E journey; catching
/// them here first is much cheaper to diagnose.
///
/// Uses a hand-rolled `NWConnection` test client rather than `URLSession`:
/// the `/stream` response has no `Content-Length` (an internet radio
/// stream has no fixed length by design), so a normal data-task request
/// would simply never complete.
final class E2EStreamServerTests: XCTestCase {
    // MARK: - /stream

    func testStreamHeadersAdvertiseTheScriptedStationAndMetaint() throws {
        let server = try E2EStreamServer(stationName: "Unit Test FM", genre: "Test Genre", metaintBytes: 4096)
        defer { server.stop() }

        let response = try Self.fetchStream(from: server, byteBudget: 4096 + 4096)

        XCTAssertTrue(response.headers.contains("icy-name: Unit Test FM"))
        XCTAssertTrue(response.headers.contains("icy-genre: Test Genre"))
        XCTAssertTrue(response.headers.contains("icy-metaint: 4096"))
        XCTAssertTrue(response.headers.hasPrefix("HTTP/1.1 200"))
    }

    func testFirstMetadataFrameCarriesTheInitialTitleFromByteZero() throws {
        // The doc's own gotcha: FFmpeg's probe reads past one metaint
        // interval at open, so a fixture that waited for a "real" title
        // update before sending one would race that probe. The very first
        // interval must already carry it.
        let server = try E2EStreamServer(initialTitle: "Opening Theme", metaintBytes: 4096)
        defer { server.stop() }

        let response = try Self.fetchStream(from: server, byteBudget: 4096 + 4096)
        let firstFrame = try XCTUnwrap(response.metadataFrames.first)

        XCTAssertEqual(firstFrame, "StreamTitle='Opening Theme';")
    }

    func testUnchangedIntervalsSendTheSingleUnchangedByte() throws {
        let server = try E2EStreamServer(initialTitle: "Opening Theme", metaintBytes: 4096)
        defer { server.stop() }

        // Three metaint intervals, no scriptTitle() call in between: only
        // the first should carry real text.
        let response = try Self.fetchStream(from: server, byteBudget: 4096 * 3 + 4096)

        XCTAssertEqual(response.metadataFrames.count, 3)
        XCTAssertEqual(response.metadataFrames[0], "StreamTitle='Opening Theme';")
        XCTAssertNil(response.metadataFrames[1])
        XCTAssertNil(response.metadataFrames[2])
    }

    func testScriptTitleChangesTheNextMetadataBoundary() throws {
        let server = try E2EStreamServer(initialTitle: "Opening Theme", metaintBytes: 4096)
        defer { server.stop() }

        server.scriptTitle("Track Two")
        // Give the queue-confined write a beat to observe the new title
        // before the connection reaches its next boundary.
        Thread.sleep(forTimeInterval: 0.1)

        let response = try Self.fetchStream(from: server, byteBudget: 4096 * 2 + 4096)

        XCTAssertEqual(response.metadataFrames[0], "StreamTitle='Track Two';")
    }

    // MARK: - /playlist.m3u

    func testPlaylistServesTheStationPointingAtTheStreamURL() throws {
        let server = try E2EStreamServer(stationName: "Dial Station")
        defer { server.stop() }

        let response = try Self.fetchFinite(server.playlistURL)

        XCTAssertTrue(response.status.hasPrefix("HTTP/1.1 200"))
        XCTAssertTrue(response.headers.contains("Content-Type: audio/x-mpegurl"))
        let text = String(bytes: response.body, encoding: .utf8) ?? ""
        XCTAssertTrue(text.hasPrefix("#EXTM3U"))
        XCTAssertTrue(text.contains("Dial Station"))
        XCTAssertTrue(text.contains(server.streamURL.absoluteString))
    }

    // MARK: - Unknown path

    func testUnknownPathReturns404() throws {
        let server = try E2EStreamServer()
        defer { server.stop() }

        let response = try Self.fetchFinite(server.streamURL.deletingLastPathComponent().appendingPathComponent("nope"))

        XCTAssertTrue(response.status.hasPrefix("HTTP/1.1 404"))
    }

    // MARK: - Script control

    func testDropConnectionsClosesAnOpenStreamConnection() throws {
        let server = try E2EStreamServer(metaintBytes: 4096)
        defer { server.stop() }
        let client = try Self.RawClient(url: server.streamURL)
        defer { client.cancel() }
        try client.sendRequest()
        _ = try client.receiveAtLeast(16) // headers have started arriving

        server.dropConnections()

        XCTAssertTrue(client.waitForClose(timeout: 5), "the connection must close once dropConnections() is called")
    }

    func testRefuseConnectionsRejectsNewConnectionsWithoutAnyBytes() throws {
        let server = try E2EStreamServer()
        defer { server.stop() }
        server.refuseConnections(for: 5)

        let client = try Self.RawClient(url: server.streamURL)
        defer { client.cancel() }
        try client.sendRequest()

        XCTAssertTrue(client.waitForClose(timeout: 5), "a refused connection must close without ever responding")
    }

    // MARK: - Test client

    private struct StreamResponse {
        let headers: String
        /// One entry per metadata boundary observed: the decoded
        /// `StreamTitle='...';` text, or `nil` for the single-byte
        /// "unchanged" frame.
        let metadataFrames: [String?]
    }

    /// Fetches `byteBudget` raw bytes from `server.streamURL` and parses
    /// out the ICY headers plus every interleaved metadata frame in that
    /// span, using the server's own `metaintBytes` to walk the interleave.
    private static func fetchStream(from server: E2EStreamServer, byteBudget: Int) throws -> StreamResponse {
        let client = try RawClient(url: server.streamURL)
        defer { client.cancel() }
        try client.sendRequest()
        let raw = try client.receiveAtLeast(byteBudget)

        guard let headerEnd = raw.range(of: Data("\r\n\r\n".utf8)) else {
            throw TestClientError.noHeaderTerminator
        }
        let headers = String(bytes: raw[..<headerEnd.lowerBound], encoding: .utf8) ?? ""
        guard let metaintText = headers
            .split(separator: "\r\n")
            .first(where: { $0.hasPrefix("icy-metaint:") })?
            .split(separator: ":", maxSplits: 1).last?
            .trimmingCharacters(in: .whitespaces),
            let metaint = Int(metaintText) else {
            throw TestClientError.noMetaint
        }

        var body = raw[headerEnd.upperBound...]
        var frames: [String?] = []
        while body.count > metaint {
            body = body.dropFirst(metaint)
            guard let lengthByte = body.first else { break }
            let metaLength = Int(lengthByte) * 16
            body = body.dropFirst(1)
            guard body.count >= metaLength else { break }
            if metaLength == 0 {
                frames.append(nil)
            } else {
                let text = String(bytes: body.prefix(metaLength), encoding: .utf8) ?? ""
                let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                frames.append(trimmed)
            }
            body = body.dropFirst(metaLength)
        }
        return StreamResponse(headers: headers, metadataFrames: frames)
    }

    private struct FiniteResponse {
        let status: String
        let headers: String
        let body: Data
    }

    /// Fetches a normal, `Content-Length`-terminated response in full.
    private static func fetchFinite(_ url: URL) throws -> FiniteResponse {
        let client = try RawClient(url: url)
        defer { client.cancel() }
        try client.sendRequest()
        let raw = try client.receiveUntilClosed(timeout: 5)

        guard let headerEnd = raw.range(of: Data("\r\n\r\n".utf8)) else {
            throw TestClientError.noHeaderTerminator
        }
        let headerBlock = String(bytes: raw[..<headerEnd.lowerBound], encoding: .utf8) ?? ""
        let lines = headerBlock.split(separator: "\r\n")
        let status = lines.first.map(String.init) ?? ""
        let headers = lines.dropFirst().joined(separator: "\r\n")
        let body = raw[headerEnd.upperBound...]
        return FiniteResponse(status: status, headers: headers, body: Data(body))
    }

    private enum TestClientError: Error {
        case badURL
        case neverConnected
        case noHeaderTerminator
        case noMetaint
    }

    /// A minimal raw TCP client good enough to drive `E2EStreamServer` from
    /// a test: connect, send a plain GET, and either collect a byte budget
    /// (for the open-ended `/stream`) or read until the peer closes (for a
    /// normal finite response).
    private final class RawClient {
        private let connection: NWConnection
        private let queue = DispatchQueue(label: "e2e.stream-server-test-client")
        private let path: String

        init(url: URL) throws {
            guard let host = url.host, let port = url.port else { throw TestClientError.badURL }
            self.path = url.path
            self.connection = NWConnection(
                host: .init(host),
                port: NWEndpoint.Port(integerLiteral: UInt16(port)),
                using: .tcp
            )
            let ready = DispatchSemaphore(value: 0)
            self.connection.stateUpdateHandler = { state in
                if case .ready = state { ready.signal() }
            }
            self.connection.start(queue: self.queue)
            guard ready.wait(timeout: .now() + 5) == .success else {
                self.connection.cancel()
                throw TestClientError.neverConnected
            }
        }

        func sendRequest() throws {
            let request = "GET \(self.path) HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
            let done = DispatchSemaphore(value: 0)
            self.connection.send(content: Data(request.utf8), completion: .contentProcessed { _ in done.signal() })
            _ = done.wait(timeout: .now() + 5)
        }

        func receiveAtLeast(_ byteBudget: Int, timeout: TimeInterval = 10) throws -> Data {
            var collected = Data()
            let done = DispatchSemaphore(value: 0)
            func more() {
                self.connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                    if let data { collected.append(data) }
                    if collected.count >= byteBudget || error != nil || data == nil {
                        done.signal()
                    } else {
                        more()
                    }
                }
            }
            more()
            _ = done.wait(timeout: .now() + timeout)
            return collected
        }

        func receiveUntilClosed(timeout: TimeInterval) throws -> Data {
            var collected = Data()
            let done = DispatchSemaphore(value: 0)
            func more() {
                self.connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                    if let data { collected.append(data) }
                    if isComplete || error != nil {
                        done.signal()
                    } else {
                        more()
                    }
                }
            }
            more()
            _ = done.wait(timeout: .now() + timeout)
            return collected
        }

        /// Blocks until the connection reports it closed (peer hung up or
        /// errored), or `timeout` elapses without that happening.
        func waitForClose(timeout: TimeInterval) -> Bool {
            let closed = DispatchSemaphore(value: 0)
            func watch() {
                self.connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, isComplete, error in
                    if isComplete || error != nil {
                        closed.signal()
                    } else {
                        watch()
                    }
                }
            }
            watch()
            return closed.wait(timeout: .now() + timeout) == .success
        }

        func cancel() {
            self.connection.cancel()
        }
    }
}
