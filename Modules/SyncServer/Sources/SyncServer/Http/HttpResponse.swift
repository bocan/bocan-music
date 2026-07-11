import Foundation

/// Machine-readable error codes from sync-protocol.md section 5.
enum ErrorCode: String {
    case notPaired
    case pairingExpired
    case badProof
    case rateLimited
    case notFound
    case busy
    case `internal`
}

/// A body of known length produced in chunks, so large files are streamed rather
/// than buffered. `producer` calls `write` for each chunk; `write` throws if the
/// connection closes, which unwinds the producer (balancing any security scope).
struct StreamBody {
    let length: Int
    let producer: @Sendable (_ write: @Sendable (Data) async throws -> Void) async throws -> Void
}

/// An HTTP/1.1 response. Serialization always sets `Content-Length`; there is no
/// chunked encoding in either direction (sync-protocol.md section 5). A response
/// is either buffered (`body`) or streamed (`stream`).
struct HttpResponse {
    var status: Int
    var headers: [String: String]
    var body: Data
    var stream: StreamBody?

    init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
        self.stream = nil
    }

    /// A streamed response of known length.
    static func streamed(
        status: Int,
        headers: [String: String],
        length: Int,
        producer: @escaping @Sendable (_ write: @Sendable (Data) async throws -> Void) async throws -> Void
    ) -> HttpResponse {
        var response = HttpResponse(status: status, headers: headers)
        response.stream = StreamBody(length: length, producer: producer)
        return response
    }

    // MARK: - Convenience constructors

    static func noContent() -> HttpResponse {
        HttpResponse(status: 204)
    }

    static func json(status: Int = 200, data: Data) -> HttpResponse {
        HttpResponse(status: status, headers: ["content-type": "application/json"], body: data)
    }

    /// The section-5 error envelope. Built by hand (two known string fields) so no
    /// encoding can fail; `message` is JSON-string-escaped.
    static func error(_ code: ErrorCode, message: String, status: Int) -> HttpResponse {
        let escaped = message
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let json = "{\"error\":\"\(code.rawValue)\",\"message\":\"\(escaped)\"}"
        return HttpResponse(
            status: status,
            headers: ["content-type": "application/json"],
            body: Data(json.utf8)
        )
    }

    // MARK: - Serialization

    /// The full HTTP/1.1 response bytes for a buffered body, always carrying
    /// `Content-Length`.
    func serialized() -> Data {
        var data = self.headerBlock(contentLength: self.body.count)
        data.append(self.body)
        return data
    }

    /// The status line and headers (with `Content-Length`), without the body.
    /// Used by the streaming path, which sends the body chunks separately.
    func headerBlock(contentLength: Int) -> Data {
        var fields = self.headers
        fields["content-length"] = String(contentLength)
        var text = "HTTP/1.1 \(self.status) \(Self.reasonPhrase(self.status))\r\n"
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            text += "\(name): \(value)\r\n"
        }
        text += "\r\n"
        return Data(text.utf8)
    }

    private static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 204: "No Content"
        case 206: "Partial Content"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 411: "Length Required"
        case 412: "Precondition Failed"
        case 413: "Payload Too Large"
        case 416: "Range Not Satisfiable"
        case 429: "Too Many Requests"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        case 503: "Service Unavailable"
        default: "Status \(status)"
        }
    }
}
