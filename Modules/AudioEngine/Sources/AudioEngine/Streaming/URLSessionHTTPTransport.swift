import Foundation

/// Default `HTTPTransport` backed by `URLSession.bytes(for:)`. The Subsonic
/// module wires this into a `RemoteTrackLoader` for production use; tests
/// substitute their own deterministic transport.
public struct URLSessionHTTPTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func bytes(for request: URLRequest) async throws -> RemoteTrackBytes {
        let (asyncBytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (asyncBytes, response) = try await self.session.bytes(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw RemoteTrackLoaderError.cancelled
        } catch let error as URLError {
            throw RemoteTrackLoaderError.transport(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200 ..< 300:
                break

            case 401:
                throw RemoteTrackLoaderError.unauthorized

            case 403, 410:
                throw RemoteTrackLoaderError.gone

            default:
                throw RemoteTrackLoaderError.server(statusCode: http.statusCode)
            }
        }

        let total: Int64? = response.expectedContentLength >= 0 ? response.expectedContentLength : nil

        let stream = AsyncThrowingStream<Data, Error>(bufferingPolicy: .unbounded) { continuation in
            let pump = Task {
                var buffer = Data()
                buffer.reserveCapacity(64 * 1024)
                do {
                    for try await byte in asyncBytes {
                        buffer.append(byte)
                        if buffer.count >= 64 * 1024 {
                            continuation.yield(buffer)
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if !buffer.isEmpty { continuation.yield(buffer) }
                    continuation.finish()
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish(throwing: RemoteTrackLoaderError.cancelled)
                } catch let error as URLError {
                    continuation.finish(throwing: RemoteTrackLoaderError.transport(error.localizedDescription))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in pump.cancel() }
        }

        return RemoteTrackBytes(stream: stream, totalBytes: total)
    }
}
