import Foundation
import Observability
import Persistence

/// Fetches a transcript body over HTTP and stores it in the transcript cache.
///
/// Mirrors `FeedFetcher`: shared `User-Agent`, size cap, cancellation, http/https
/// only. It does not parse: the raw body is stored verbatim and parsed at view
/// time. The format is inferred from the URL extension and HTTP `Content-Type`.
public actor TranscriptFetcher {
    private let http: any HTTPClient
    private let repo: TranscriptRepository
    private let maxBytes: Int
    private let now: @Sendable () -> Date
    private let log = AppLogger.make(.podcasts)

    public init(
        http: any HTTPClient = URLSession.shared,
        repo: TranscriptRepository,
        maxBytes: Int = 5 * 1024 * 1024,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.http = http
        self.repo = repo
        self.maxBytes = maxBytes
        self.now = now
    }

    /// Fetches the transcript body for an episode and persists it. Returns the row.
    public func fetchAndStore(
        podcastID: Int64,
        guid: String,
        transcriptURL: URL,
        language: String?
    ) async throws -> PodcastTranscript {
        try Task.checkCancellation()

        guard let scheme = transcriptURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw PodcastsError.invalidFeedURL(transcriptURL.absoluteString)
        }

        var request = URLRequest(url: transcriptURL, timeoutInterval: 20)
        request.setValue(UserAgent.string, forHTTPHeaderField: "User-Agent")

        self.log.debug("transcript.fetch.start", ["url": transcriptURL.absoluteString])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await self.http.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            self.log.error(
                "transcript.fetch.failed",
                ["url": transcriptURL.absoluteString, "error": String(reflecting: error)]
            )
            throw PodcastsError.network(underlying: error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw PodcastsError.network(underlying: URLError(.badServerResponse))
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw PodcastsError.httpStatus(code: http.statusCode, url: transcriptURL)
        }
        if data.count > self.maxBytes {
            throw PodcastsError.feedTooLarge(bytes: data.count)
        }

        // Decode UTF-8 strictly, falling back to a lossy decode rather than failing.
        let content = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let mime = http.value(forHTTPHeaderField: "Content-Type")
        let format = TranscriptFormat.infer(fromURL: transcriptURL, mime: mime)

        let record = PodcastTranscript(
            podcastID: podcastID,
            guid: guid,
            content: content,
            format: format,
            language: language,
            sourceURL: transcriptURL.absoluteString,
            fetchedAt: self.now().timeIntervalSince1970
        )
        try await self.repo.upsert(record)

        self.log.debug(
            "transcript.fetch.end",
            ["url": transcriptURL.absoluteString, "bytes": data.count, "format": format.rawValue]
        )
        return record
    }
}
