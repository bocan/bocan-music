import Foundation
import Testing
@testable import SyncServer

@Suite("HttpRequestParser")
struct HttpParserTests {
    private func feed(_ string: String) -> HttpRequestParser.Outcome {
        var parser = HttpRequestParser()
        return parser.feed(Data(string.utf8))
    }

    @Test("parses a well-formed GET with query and headers")
    func parsesGet() {
        let outcome = self.feed("GET /v1/ping?x=1&y=two HTTP/1.1\r\nHost: mac\r\nAccept-Encoding: gzip\r\n\r\n")
        guard case let .request(request, leftover) = outcome else {
            Issue.record("expected a request")
            return
        }
        #expect(request.method == "GET")
        #expect(request.path == "/v1/ping")
        #expect(request.query["x"] == "1")
        #expect(request.query["y"] == "two")
        #expect(request.header("accept-encoding") == "gzip")
        #expect(request.body.isEmpty)
        #expect(leftover.isEmpty)
    }

    @Test("parses a POST body by Content-Length")
    func parsesPostBody() {
        let body = "{\"a\":1}"
        let outcome = self.feed("POST /v1/pair/start HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)")
        guard case let .request(request, leftover) = outcome else {
            Issue.record("expected a request")
            return
        }
        #expect(request.method == "POST")
        #expect(String(data: request.body, encoding: .utf8) == body)
        #expect(leftover.isEmpty)
    }

    @Test("a body split across feeds completes on the second feed")
    func splitBody() {
        var parser = HttpRequestParser()
        if case .incomplete = parser.feed(Data("POST /x HTTP/1.1\r\nContent-Length: 5\r\n\r\nab".utf8)) {
            // expected
        } else {
            Issue.record("expected incomplete")
        }
        guard case let .request(request, _) = parser.feed(Data("cde".utf8)) else {
            Issue.record("expected a request")
            return
        }
        #expect(String(data: request.body, encoding: .utf8) == "abcde")
    }

    @Test("chunked transfer encoding is rejected with 411")
    func chunkedRejected() {
        guard case let .failure(response) = self.feed("POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n") else {
            Issue.record("expected failure")
            return
        }
        #expect(response.status == 411)
    }

    @Test("an oversized header block is rejected with 431")
    func oversizedHeader() {
        let big = "GET /x HTTP/1.1\r\nX: " + String(repeating: "a", count: 17 * 1024) + "\r\n\r\n"
        guard case let .failure(response) = self.feed(big) else {
            Issue.record("expected failure")
            return
        }
        #expect(response.status == 431)
    }

    @Test("a Content-Length over 1 MB is rejected with 413")
    func oversizedBody() {
        guard case let .failure(response) = self.feed("POST /x HTTP/1.1\r\nContent-Length: \(1024 * 1024 + 1)\r\n\r\n") else {
            Issue.record("expected failure")
            return
        }
        #expect(response.status == 413)
    }

    @Test("a malformed request line is rejected with 400")
    func malformedRequestLine() {
        guard case let .failure(response) = self.feed("GARBAGE\r\n\r\n") else {
            Issue.record("expected failure")
            return
        }
        #expect(response.status == 400)
    }

    @Test("two pipelined requests return the second as leftover")
    func leftoverForNextRequest() {
        guard case let .request(first, leftover) = self.feed("GET /a HTTP/1.1\r\n\r\nGET /b HTTP/1.1\r\n\r\n") else {
            Issue.record("expected a request")
            return
        }
        #expect(first.path == "/a")

        var next = HttpRequestParser()
        guard case let .request(second, _) = next.feed(leftover) else {
            Issue.record("expected the second request")
            return
        }
        #expect(second.path == "/b")
    }
}
