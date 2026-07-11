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

/// An HTTP/1.1 response. Serialization always sets `Content-Length`; there is no
/// chunked encoding in either direction (sync-protocol.md section 5).
struct HttpResponse {
    var status: Int
    var headers: [String: String]
    var body: Data

    init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
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

    /// The full HTTP/1.1 response bytes, always carrying `Content-Length`.
    func serialized() -> Data {
        var fields = self.headers
        fields["content-length"] = String(self.body.count)
        var text = "HTTP/1.1 \(self.status) \(Self.reasonPhrase(self.status))\r\n"
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            text += "\(name): \(value)\r\n"
        }
        text += "\r\n"
        var data = Data(text.utf8)
        data.append(self.body)
        return data
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
