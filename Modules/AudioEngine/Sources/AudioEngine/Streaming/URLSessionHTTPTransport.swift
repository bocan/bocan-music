import Foundation

/// Default `HTTPTransport` backed by a delegate-driven `URLSessionDataTask`.
/// The Subsonic module wires this into a `RemoteTrackLoader` for production
/// use; tests substitute their own deterministic transport.
///
/// The body is forwarded in the chunks `URLSession` delivers. It used to be
/// read through `URLSession.AsyncBytes`, one byte per loop iteration, and
/// re-assembled into 64 KiB blocks (#547).
public struct URLSessionHTTPTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func bytes(for request: URLRequest) async throws -> RemoteTrackBytes {
        let task = self.session.dataTask(with: request)
        let delegate = StreamingDataDelegate(task: task)
        task.delegate = delegate
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.begin(awaiting: continuation)
            }
        } onCancel: {
            task.cancel()
        }
    }
}

// MARK: - StreamingDataDelegate

/// Per-task delegate that turns the response into a `RemoteTrackBytes` and
/// each `didReceive data` callback into one stream element.
///
/// A class with a lock rather than an actor because `URLSessionDataDelegate`
/// callbacks are synchronous: the response callback must call its completion
/// handler before it returns, and data must be yielded in arrival order.
private final class StreamingDataDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let task: URLSessionDataTask
    private let streamContinuation: AsyncThrowingStream<Data, Error>.Continuation

    private let lock = NSLock()
    /// Waits for the response headers. `nil` once it has been resumed.
    private var responseContinuation: CheckedContinuation<RemoteTrackBytes, Error>?
    /// Held only until it is handed to the caller. After that the caller owns
    /// the one reference, so dropping it unread terminates the stream and
    /// cancels the transfer.
    private var stream: AsyncThrowingStream<Data, Error>?

    init(task: URLSessionDataTask) {
        self.task = task
        // Unbounded, as before: the one consumer writes each chunk straight to
        // a local file, which outruns the network.
        let (stream, continuation) = AsyncThrowingStream.makeStream(
            of: Data.self,
            throwing: Error.self,
            bufferingPolicy: .unbounded
        )
        self.stream = stream
        self.streamContinuation = continuation
        super.init()
        // The consumer stopped iterating (or was cancelled): stop the transfer.
        self.streamContinuation.onTermination = { [task] _ in task.cancel() }
    }

    func begin(awaiting continuation: CheckedContinuation<RemoteTrackBytes, Error>) {
        self.lock.withLock { self.responseContinuation = continuation }
        self.task.resume()
    }

    private func takeResponseContinuation() -> CheckedContinuation<RemoteTrackBytes, Error>? {
        self.lock.withLock {
            defer { self.responseContinuation = nil }
            return self.responseContinuation
        }
    }

    private func takeStream() -> AsyncThrowingStream<Data, Error>? {
        self.lock.withLock {
            defer { self.stream = nil }
            return self.stream
        }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(
        _: URLSession,
        dataTask _: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse, let failure = Self.failure(forStatus: http.statusCode) {
            _ = self.takeStream()
            self.takeResponseContinuation()?.resume(throwing: failure)
            self.streamContinuation.finish(throwing: failure)
            completionHandler(.cancel)
            return
        }
        let total: Int64? = response.expectedContentLength >= 0 ? response.expectedContentLength : nil
        guard let stream = self.takeStream(), let waiting = self.takeResponseContinuation() else {
            // A second response (a redirect chain ends in one, but be safe):
            // the caller already has the stream.
            completionHandler(.allow)
            return
        }
        waiting.resume(returning: RemoteTrackBytes(stream: stream, totalBytes: total))
        completionHandler(.allow)
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive data: Data) {
        self.streamContinuation.yield(data)
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else {
            self.streamContinuation.finish()
            return
        }
        let mapped = Self.mapped(error)
        // Before the headers arrived this fails `bytes(for:)`; after, it ends
        // the stream. Finishing an already-finished stream is a no-op.
        self.takeResponseContinuation()?.resume(throwing: mapped)
        self.streamContinuation.finish(throwing: mapped)
    }

    // MARK: Error mapping

    private static func failure(forStatus statusCode: Int) -> RemoteTrackLoaderError? {
        switch statusCode {
        case 200 ..< 300:
            nil

        case 401:
            .unauthorized

        case 403, 410:
            .gone

        default:
            .server(statusCode: statusCode)
        }
    }

    private static func mapped(_ error: Error) -> Error {
        guard let urlError = error as? URLError else { return error }
        return urlError.code == .cancelled
            ? RemoteTrackLoaderError.cancelled
            : RemoteTrackLoaderError.transport(urlError.localizedDescription)
    }
}
