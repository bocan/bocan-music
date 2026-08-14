import Foundation
import Network

// MARK: - PodcastServerState

/// Queue-confined mutable state and connection handling for
/// `E2EPodcastServer`. Everything here runs on the server's single serial
/// `DispatchQueue`, matching `E2EStreamServerState`'s pattern, so none of
/// this needs its own locking.
final class PodcastServerState: @unchecked Sendable {
    let showTitle: String
    let episodeAudio: Data

    /// Flips true once `publishThirdEpisode()` is called; the next
    /// `/feed.xml` response includes episode 3.
    var thirdEpisodePublished = false

    /// Set by `E2EPodcastServer` right after the listener becomes ready —
    /// episode/chapter URLs in the feed body are self-referencing absolute
    /// URLs, and the port isn't known until then.
    var baseURL: URL?

    private var allConnections: [NWConnection] = []

    init(showTitle: String, episodeAudio: Data) {
        self.showTitle = showTitle
        self.episodeAudio = episodeAudio
    }

    // MARK: - Accept

    func accept(_ connection: NWConnection, queue: DispatchQueue) {
        queue.async {
            self.allConnections.append(connection)
            connection.start(queue: queue)
            self.readRequest(connection, queue: queue, buffer: Data())
        }
    }

    func cancelAll() {
        self.allConnections.forEach { $0.cancel() }
        self.allConnections.removeAll()
    }

    // MARK: - Request parsing

    /// Accumulates bytes until the blank line ending the request headers,
    /// then dispatches on the request line's path. Real clients here send a
    /// small header-only GET with no body, so a handful of `receive` calls
    /// is always enough.
    private func readRequest(_ connection: NWConnection, queue: DispatchQueue, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerBlock = buffer[..<range.lowerBound]
                self.dispatch(connection, requestLine: Self.firstLine(of: headerBlock))
                return
            }
            guard error == nil, !isComplete, buffer.count < 65536 else {
                connection.cancel()
                return
            }
            self.readRequest(connection, queue: queue, buffer: buffer)
        }
    }

    private static func firstLine(of headerBlock: Data.SubSequence) -> String {
        let text = String(bytes: headerBlock, encoding: .utf8) ?? ""
        return text.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
    }

    /// The request line's path: `"GET /feed.xml HTTP/1.1"` -> `"/feed.xml"`.
    private static func path(fromRequestLine line: String) -> String {
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return "" }
        return String(parts[1])
    }

    private func dispatch(_ connection: NWConnection, requestLine: String) {
        switch Self.path(fromRequestLine: requestLine) {
        case "/feed.xml":
            self.sendResponse(
                connection,
                status: "200 OK",
                headers: ["Content-Type": "application/rss+xml; charset=utf-8"],
                body: Data(self.feedXML.utf8)
            )

        case "/ep1-chapters.json":
            self.sendResponse(
                connection,
                status: "200 OK",
                headers: ["Content-Type": "application/json+chapters"],
                body: Data(Self.chaptersJSON.utf8)
            )

        case "/ep1.wav", "/ep2.wav", "/ep3.wav":
            self.sendResponse(
                connection,
                status: "200 OK",
                headers: ["Content-Type": "audio/wav"],
                body: self.episodeAudio
            )

        default:
            self.sendResponse(connection, status: "404 Not Found", headers: [:], body: Data())
        }
    }

    private func sendResponse(_ connection: NWConnection, status: String, headers: [String: String], body: Data) {
        var text = "HTTP/1.1 \(status)\r\n"
        for (name, value) in headers {
            text += "\(name): \(value)\r\n"
        }
        text += "Content-Length: \(body.count)\r\n\r\n"
        var payload = Data(text.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: - Feed content

    /// A `podcast:` namespace RSS feed: episode 1 carries `podcast:chapters`
    /// (exercising `PodcastNamespaceSupplement`, per the module's own
    /// fixture conventions in `rss-podcast-namespace.xml`), episode 2 does
    /// not. Episode 3 only appears once `publishThirdEpisode()` flips
    /// `thirdEpisodePublished` — the refresh journey's new-content check.
    private var feedXML: String {
        let base = self.baseURL?.absoluteString ?? ""
        var items = """
            <item>
              <title>Episode One</title>
              <guid isPermaLink="false">e2e-ep1</guid>
              <pubDate>Mon, 10 Jun 2024 10:00:00 +0000</pubDate>
              <enclosure url="\(base)/ep1.wav" type="audio/wav" length="\(self.episodeAudio.count)"/>
              <podcast:chapters url="\(base)/ep1-chapters.json" type="application/json+chapters"/>
            </item>
            <item>
              <title>Episode Two</title>
              <guid isPermaLink="false">e2e-ep2</guid>
              <pubDate>Mon, 17 Jun 2024 10:00:00 +0000</pubDate>
              <enclosure url="\(base)/ep2.wav" type="audio/wav" length="\(self.episodeAudio.count)"/>
            </item>
        """
        if self.thirdEpisodePublished {
            items += """

                <item>
                  <title>Episode Three</title>
                  <guid isPermaLink="false">e2e-ep3</guid>
                  <pubDate>Mon, 24 Jun 2024 10:00:00 +0000</pubDate>
                  <enclosure url="\(base)/ep3.wav" type="audio/wav" length="\(self.episodeAudio.count)"/>
                </item>
            """
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0"
             xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"
             xmlns:podcast="https://podcastindex.org/namespace/1.0">
          <channel>
            <title>\(self.showTitle)</title>
            <link>\(base)</link>
            <description>Phase 34 loopback fixture feed.</description>
        \(items)
          </channel>
        </rss>
        """
    }

    private static let chaptersJSON = """
    {
      "version": "1.2.0",
      "chapters": [
        { "startTime": 0, "title": "Intro" },
        { "startTime": 10.0, "title": "Main Topic" }
      ]
    }
    """
}
