import Foundation

/// An incremental, hard-capped HTTP/1.1 request parser. Fed bytes as they arrive
/// from the connection; it enforces the deliberate constraints from
/// sync-protocol.md section 5 so a hand-rolled parser stays safe:
///
/// - request line + headers are capped at 16 KB (`431` past that);
/// - a body is capped at 1 MB (`413` past that);
/// - chunked transfer encoding is rejected (`411`); bodies carry `Content-Length`;
/// - anything malformed is `400`.
///
/// One parser handles one request. On `.request` it returns any trailing bytes as
/// `leftover`; a keep-alive caller feeds those to a fresh parser.
struct HttpRequestParser {
    static let maxHeaderBytes = 16 * 1024
    static let maxBodyBytes = 1024 * 1024

    private var buffer = Data()

    enum Outcome {
        /// More bytes are needed before a request is complete.
        case incomplete
        /// A complete request, plus any bytes belonging to the next request.
        case request(HttpRequest, leftover: Data)
        /// The request is invalid; send this response and close the connection.
        case failure(HttpResponse)
    }

    mutating func feed(_ data: Data) -> Outcome {
        self.buffer.append(data)
        return self.parse()
    }

    private func parse() -> Outcome {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = self.buffer.range(of: separator) else {
            if self.buffer.count > Self.maxHeaderBytes {
                return .failure(.error(.internal, message: "Header too large", status: 431))
            }
            return .incomplete
        }

        let headerBytes = self.buffer.subdata(in: self.buffer.startIndex ..< headerRange.lowerBound)
        if headerBytes.count > Self.maxHeaderBytes {
            return .failure(.error(.internal, message: "Header too large", status: 431))
        }
        let head: Head
        switch Self.parseHead(headerBytes) {
        case let .rejected(response):
            return .failure(response)

        case let .parsed(parsed):
            head = parsed
        }

        let bodyLength: Int
        switch Self.declaredBodyLength(head.headers) {
        case let .rejected(response):
            return .failure(response)

        case let .parsed(count):
            bodyLength = count
        }

        let bodyStart = headerRange.upperBound
        let available = self.buffer.distance(from: bodyStart, to: self.buffer.endIndex)
        if available < bodyLength {
            return .incomplete
        }

        let bodyEnd = self.buffer.index(bodyStart, offsetBy: bodyLength)
        let body = self.buffer.subdata(in: bodyStart ..< bodyEnd)
        let leftover = self.buffer.subdata(in: bodyEnd ..< self.buffer.endIndex)

        let (path, query) = Self.splitTarget(head.target)
        let request = HttpRequest(method: head.method, path: path, query: query, headers: head.headers, body: body)
        return .request(request, leftover: leftover)
    }

    /// The request line and header fields of one request.
    private struct Head {
        let method: String
        let target: String
        let headers: [String: String]
    }

    /// One parsing step: the value it produced, or the response that rejects
    /// the request.
    private enum Step<Value> {
        case parsed(Value)
        case rejected(HttpResponse)
    }

    /// Parses the bytes before the blank line: the request line, then the
    /// header fields (names lowercased, a repeated name keeps its last value).
    private static func parseHead(_ headerBytes: Data) -> Step<Head> {
        guard let headerText = String(data: headerBytes, encoding: .utf8) else {
            return .rejected(.error(.internal, message: "Malformed request", status: 400))
        }

        var lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return .rejected(.error(.internal, message: "Malformed request", status: 400))
        }
        lines.removeFirst()

        // Request line: METHOD SP target SP HTTP/1.1
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3 else {
            return .rejected(.error(.internal, message: "Malformed request line", status: 400))
        }
        let method = String(parts[0]).uppercased()
        let target = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                return .rejected(.error(.internal, message: "Malformed header", status: 400))
            }
            let name = line[line.startIndex ..< colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return .parsed(Head(method: method, target: target, headers: headers))
    }

    /// The body length the headers declare: 0 with no `Content-Length`.
    /// Chunked transfer encoding is rejected before the length is read.
    private static func declaredBodyLength(_ headers: [String: String]) -> Step<Int> {
        if let encoding = headers["transfer-encoding"], encoding.lowercased().contains("chunked") {
            return .rejected(.error(.internal, message: "Chunked encoding is not supported", status: 411))
        }

        var bodyLength = 0
        if let contentLength = headers["content-length"] {
            guard let count = Int(contentLength), count >= 0 else {
                return .rejected(.error(.internal, message: "Bad Content-Length", status: 400))
            }
            if count > Self.maxBodyBytes {
                return .rejected(.error(.internal, message: "Body too large", status: 413))
            }
            bodyLength = count
        }
        return .parsed(bodyLength)
    }

    private static func splitTarget(_ target: String) -> (path: String, query: [String: String]) {
        let pieces = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPath = String(pieces.first ?? "")
        let path = rawPath.removingPercentEncoding ?? rawPath
        guard pieces.count == 2 else {
            return (path, [:])
        }
        var query: [String: String] = [:]
        for pair in pieces[1].split(separator: "&", omittingEmptySubsequences: true) {
            let keyValue = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(keyValue[0]).removingPercentEncoding ?? String(keyValue[0])
            let value = keyValue.count == 2 ? (String(keyValue[1]).removingPercentEncoding ?? String(keyValue[1])) : ""
            if !key.isEmpty {
                query[key] = value
            }
        }
        return (path, query)
    }
}
