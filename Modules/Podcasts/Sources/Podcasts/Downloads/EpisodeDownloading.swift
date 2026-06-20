import Foundation
import Observability

// MARK: - Seam

/// A controllable handle to one in-flight transfer.
protocol EpisodeDownloadHandle: Sendable {
    /// Cancel and discard; no resume data is produced.
    func cancel()
    /// Cancel, returning resume data when the server supports range resume
    /// (`nil` otherwise). Used by `pause`.
    func cancelProducingResumeData() async -> Data?
}

/// Abstraction over the actual byte transfer so the manager's queue, state, and
/// progress logic can be tested deterministically without the network. The
/// production implementation is `URLSessionDownloader`; tests inject a fake.
protocol EpisodeDownloading: Sendable {
    /// Begin (or resume) a transfer. `onProgress` reports
    /// `(bytesWritten, totalBytes)`; `onFinished` reports a stable temp-file URL
    /// on success or an error. Returns a handle to pause / cancel it.
    func start(
        url: URL,
        resumeData: Data?,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void,
        onFinished: @escaping @Sendable (Result<URL, Error>) -> Void
    ) -> any EpisodeDownloadHandle
}

// MARK: - Production implementation

/// `EpisodeDownloading` backed by `URLSessionDownloadTask`.
///
/// Builds a delegate-backed `URLSession` from the caller's configuration so that
/// progress callbacks are delivered (`.shared` carries no delegate). The idle
/// (request) timeout is 60 s; the total (resource) timeout is left at the default
/// because episodes can be large, so only idle time is capped (per phase 21-6).
final class URLSessionDownloader: NSObject, EpisodeDownloading, URLSessionDownloadDelegate, @unchecked Sendable {
    private struct Callbacks {
        let onProgress: @Sendable (Int64, Int64) -> Void
        let onFinished: @Sendable (Result<URL, Error>) -> Void
        var finished = false
    }

    private let lock = NSLock()
    private var callbacks: [Int: Callbacks] = [:]
    private var session: URLSession!
    private let log = AppLogger.make(.podcasts)

    init(session base: URLSession) {
        super.init()
        let config = base.configuration
        config.timeoutIntervalForRequest = 60
        // Download tasks build their own URLRequest internally, so the User-Agent
        // is set on the session config to keep podcast traffic consistent.
        var headers = config.httpAdditionalHeaders ?? [:]
        headers["User-Agent"] = UserAgent.string
        config.httpAdditionalHeaders = headers
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }

    func start(
        url: URL,
        resumeData: Data?,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void,
        onFinished: @escaping @Sendable (Result<URL, Error>) -> Void
    ) -> any EpisodeDownloadHandle {
        let task: URLSessionDownloadTask = if let resumeData {
            self.session.downloadTask(withResumeData: resumeData)
        } else {
            self.session.downloadTask(with: url)
        }
        self.lock.withLock {
            self.callbacks[task.taskIdentifier] = Callbacks(onProgress: onProgress, onFinished: onFinished)
        }
        task.resume()
        return Handle(task: task)
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(
        _: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData _: Int64,
        totalBytesWritten written: Int64,
        totalBytesExpectedToWrite expected: Int64
    ) {
        let cb = self.lock.withLock { self.callbacks[downloadTask.taskIdentifier] }
        cb?.onProgress(written, expected)
    }

    func urlSession(
        _: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The temp file at `location` is deleted once this method returns, so move
        // it to a stable temp file synchronously before handing it off.
        let stable = FileManager.default.temporaryDirectory
            .appendingPathComponent("bocan-dl-\(UUID().uuidString).tmp")
        let result: Result<URL, Error>
        do {
            try FileManager.default.moveItem(at: location, to: stable)
            result = .success(stable)
        } catch {
            result = .failure(error)
        }
        let cb = self.lock.withLock { () -> Callbacks? in
            let existing = self.callbacks[downloadTask.taskIdentifier]
            self.callbacks[downloadTask.taskIdentifier]?.finished = true
            return existing
        }
        cb?.onFinished(result)
    }

    func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let cb = self.lock.withLock { () -> Callbacks? in
            let existing = self.callbacks[task.taskIdentifier]
            self.callbacks[task.taskIdentifier] = nil
            return existing
        }
        guard let cb, !cb.finished else { return } // success already delivered by didFinishDownloadingTo
        if let error {
            cb.onFinished(.failure(error))
        }
    }

    // MARK: Handle

    private final class Handle: EpisodeDownloadHandle, @unchecked Sendable {
        private let task: URLSessionDownloadTask
        init(task: URLSessionDownloadTask) {
            self.task = task
        }

        func cancel() {
            self.task.cancel()
        }

        func cancelProducingResumeData() async -> Data? {
            await withCheckedContinuation { continuation in
                self.task.cancel(byProducingResumeData: { data in continuation.resume(returning: data) })
            }
        }
    }
}
