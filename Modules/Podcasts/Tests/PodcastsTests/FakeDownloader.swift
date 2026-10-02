import Foundation
@testable import Podcasts

// MARK: - Fake downloader

final class FakeDownloader: EpisodeDownloading, @unchecked Sendable {
    final class Control: @unchecked Sendable {
        let url: URL
        let resumeData: Data?
        let onProgress: @Sendable (Int64, Int64) -> Void
        let onFinished: @Sendable (Result<URL, Error>) -> Void
        let pauseResumeData: Data?
        private let lock = NSLock()
        private var _cancelled = false
        var cancelled: Bool {
            self.lock.withLock { self._cancelled }
        }

        init(
            url: URL,
            resumeData: Data?,
            pauseResumeData: Data?,
            onProgress: @escaping @Sendable (Int64, Int64) -> Void,
            onFinished: @escaping @Sendable (Result<URL, Error>) -> Void
        ) {
            self.url = url
            self.resumeData = resumeData
            self.pauseResumeData = pauseResumeData
            self.onProgress = onProgress
            self.onFinished = onFinished
        }

        func markCancelled() {
            self.lock.withLock { self._cancelled = true }
        }
    }

    private let lock = NSLock()
    private var _controls: [Control] = []
    private let pauseResumeData: Data?

    init(pauseResumeData: Data? = Data([0xAA, 0xBB])) {
        self.pauseResumeData = pauseResumeData
    }

    var controls: [Control] {
        self.lock.withLock { self._controls }
    }

    func control(forGUIDFragment fragment: String) -> Control? {
        self.controls.first { $0.url.absoluteString.contains(fragment) }
    }

    func start(
        url: URL,
        resumeData: Data?,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void,
        onFinished: @escaping @Sendable (Result<URL, Error>) -> Void
    ) -> any EpisodeDownloadHandle {
        let control = Control(
            url: url,
            resumeData: resumeData,
            pauseResumeData: self.pauseResumeData,
            onProgress: onProgress,
            onFinished: onFinished
        )
        self.lock.withLock { self._controls.append(control) }
        return Handle(control: control)
    }

    private final class Handle: EpisodeDownloadHandle, @unchecked Sendable {
        let control: Control

        init(control: Control) {
            self.control = control
        }

        func cancel() {
            self.control.markCancelled()
        }

        func cancelProducingResumeData() async -> Data? {
            self.control.markCancelled()
            return self.control.pauseResumeData
        }
    }
}
