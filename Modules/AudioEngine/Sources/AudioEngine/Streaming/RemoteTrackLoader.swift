import Foundation

/// Errors a `RemoteTrackLoader` can surface up to `SubsonicStreamCache`.
/// Mapped one-for-one from the spec's mid-stream failure cases so the engine
/// can decide whether to skip (`gone` / `unauthorized`) or retry (`network`).
public enum RemoteTrackLoaderError: Error, Sendable, Hashable {
    /// 401 — credentials no longer accepted by the server.
    case unauthorized
    /// 403 / 410 — track exists no more, or access revoked mid-stream.
    case gone
    /// Any other non-2xx HTTP status.
    case server(statusCode: Int)
    /// Underlying URLSession / transport failure.
    case transport(String)
    /// Caller cancelled the operation.
    case cancelled
}

/// Low-level streaming HTTP fetcher. Abstracted as a protocol so the cache
/// tests can drive it with a deterministic in-memory stub instead of a real
/// `URLSession`.
public protocol HTTPTransport: Sendable {
    /// Begin streaming bytes for `request`. The implementation is expected
    /// to:
    ///
    /// * inspect the HTTP status code and throw `RemoteTrackLoaderError`
    ///   for non-success;
    /// * surface the `Content-Length` header (when present) as
    ///   `RemoteTrackBytes.totalBytes`;
    /// * deliver bytes in any chunk size; the cache assembles them.
    func bytes(for request: URLRequest) async throws -> RemoteTrackBytes
}

/// A streaming download in progress. The cache pulls from `stream` and
/// writes each chunk to its on-disk cache file.
public struct RemoteTrackBytes: Sendable {
    public let stream: AsyncThrowingStream<Data, Error>
    public let totalBytes: Int64?

    public init(stream: AsyncThrowingStream<Data, Error>, totalBytes: Int64?) {
        self.stream = stream
        self.totalBytes = totalBytes
    }
}

/// Thin convenience over `HTTPTransport` that the Subsonic module composes
/// with its own URL signer. Kept inside `AudioEngine` (rather than the
/// `Subsonic` module) so the engine can own the cache wiring without a
/// reverse dependency on `Subsonic`.
public actor RemoteTrackLoader {
    private let transport: HTTPTransport

    public init(transport: HTTPTransport) {
        self.transport = transport
    }

    /// Build a `URLRequest` from the supplied URL (GET, no extra headers
    /// here — auth is baked into the URL by the Subsonic caller) and start
    /// streaming bytes.
    public func loadBytes(from url: URL) async throws -> RemoteTrackBytes {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        return try await self.transport.bytes(for: request)
    }
}
