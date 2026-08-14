import Foundation
import Network

// MARK: - ServerState

/// Queue-confined mutable state and connection handling for
/// `E2EStreamServer`. Everything here runs on the server's single serial
/// `DispatchQueue` (the same queue the listener was started on, matching
/// `StallingListener`'s `ConnectionBag` pattern), so none of this needs its
/// own locking.
final class ServerState: @unchecked Sendable {
    let audio: Data
    let metaintBytes: Int
    let stationName: String
    let genre: String

    /// The title the next metadata boundary should announce.
    var currentTitle: String
    /// The title last actually written into the interleave — real stations
    /// only send a fresh `StreamTitle` block when this changes, and the
    /// very first boundary (this starts `nil`) always counts as a change so
    /// the initial title lands from byte zero (phase 34 doc gotcha).
    private var lastEmittedTitle: String?
    /// New connections are cancelled immediately, before any bytes are
    /// sent, while `Date() < refuseUntil` — stands in for "server down".
    var refuseUntil: Date?

    private var streamConnections: [NWConnection] = []
    private var allConnections: [NWConnection] = []

    init(audio: Data, metaintBytes: Int, currentTitle: String, stationName: String, genre: String) {
        self.audio = audio
        self.metaintBytes = metaintBytes
        self.currentTitle = currentTitle
        self.stationName = stationName
        self.genre = genre
    }

    // MARK: - Accept

    func accept(_ connection: NWConnection, queue: DispatchQueue) {
        queue.async {
            if let refuseUntil = self.refuseUntil, Date() < refuseUntil {
                connection.start(queue: queue)
                connection.cancel()
                return
            }
            self.allConnections.append(connection)
            connection.start(queue: queue)
            self.readRequest(connection, queue: queue, buffer: Data())
        }
    }

    func cancelAll() {
        self.allConnections.forEach { $0.cancel() }
        self.allConnections.removeAll()
        self.streamConnections.removeAll()
    }

    func cancelAllStreamConnections() {
        self.streamConnections.forEach { $0.cancel() }
        self.streamConnections.removeAll()
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
                self.dispatch(connection, queue: queue, requestLine: Self.firstLine(of: headerBlock))
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

    /// The request line's path: `"GET /stream HTTP/1.1"` -> `"/stream"`.
    private static func path(fromRequestLine line: String) -> String {
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return "" }
        return String(parts[1])
    }

    private func dispatch(_ connection: NWConnection, queue: DispatchQueue, requestLine: String) {
        switch Self.path(fromRequestLine: requestLine) {
        case "/stream":
            self.streamConnections.append(connection)
            self.beginStreaming(connection, queue: queue)

        case "/playlist.m3u":
            self.sendPlaylist(connection)

        default:
            self.sendNotFound(connection)
        }
    }

    // MARK: - /playlist.m3u

    /// Set by `E2EStreamServer` right after the listener becomes ready — the
    /// port (needed for a self-referencing absolute URL in the playlist
    /// body) isn't known until then, so this can't be constructor-injected.
    var streamURL: URL?

    private func sendPlaylist(_ connection: NWConnection) {
        let streamURLText = self.streamURL?.absoluteString ?? ""
        let body = "#EXTM3U\n#EXTINF:-1,\(self.stationName)\n\(streamURLText)\n"
        self.sendResponse(
            connection,
            status: "200 OK",
            headers: ["Content-Type": "audio/x-mpegurl"],
            body: Data(body.utf8),
            thenClose: true
        )
    }

    private func sendNotFound(_ connection: NWConnection) {
        self.sendResponse(connection, status: "404 Not Found", headers: [:], body: Data(), thenClose: true)
    }

    private func sendResponse(
        _ connection: NWConnection,
        status: String,
        headers: [String: String],
        body: Data,
        thenClose: Bool
    ) {
        var text = "HTTP/1.1 \(status)\r\n"
        for (name, value) in headers {
            text += "\(name): \(value)\r\n"
        }
        text += "Content-Length: \(body.count)\r\n\r\n"
        var payload = Data(text.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            if thenClose { connection.cancel() }
        })
    }

    // MARK: - /stream

    private func beginStreaming(_ connection: NWConnection, queue: DispatchQueue) {
        var headerText = "HTTP/1.1 200 OK\r\n"
        headerText += "icy-name: \(self.stationName)\r\n"
        headerText += "icy-genre: \(self.genre)\r\n"
        headerText += "icy-pub: 1\r\n"
        headerText += "icy-metaint: \(self.metaintBytes)\r\n"
        headerText += "icy-br: 128\r\n"
        headerText += "Content-Type: audio/aac\r\n\r\n"
        connection.send(content: Data(headerText.utf8), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { return }
            self.streamChunk(connection, queue: queue, audioOffset: 0, bytesUntilMetadata: self.metaintBytes)
        })
    }

    /// Sends one slice of the looping audio fixture, capped so a send never
    /// crosses a metadata boundary, then either the metadata frame (at a
    /// boundary) or the next audio slice — recursing on each send's
    /// completion so a slow/dead reader backpressures the loop instead of
    /// buffering unboundedly.
    private func streamChunk(
        _ connection: NWConnection,
        queue: DispatchQueue,
        audioOffset: Int,
        bytesUntilMetadata: Int
    ) {
        guard self.streamConnections.contains(where: { $0 === connection }) else { return }
        let chunkLength = min(bytesUntilMetadata, self.audio.count - audioOffset)
        let chunk = self.audio.subdata(in: audioOffset ..< (audioOffset + chunkLength))
        let nextAudioOffset = (audioOffset + chunkLength) % self.audio.count
        let nextBytesUntilMetadata = bytesUntilMetadata - chunkLength

        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else {
                self?.removeStreamConnection(connection)
                return
            }
            queue.asyncAfter(deadline: .now() + Self.pacingDelay(forBytes: chunkLength)) {
                if nextBytesUntilMetadata == 0 {
                    self.sendMetadataFrame(connection, queue: queue, nextAudioOffset: nextAudioOffset)
                } else {
                    self.streamChunk(
                        connection,
                        queue: queue,
                        audioOffset: nextAudioOffset,
                        bytesUntilMetadata: nextBytesUntilMetadata
                    )
                }
            }
        })
    }

    /// Paces sends to roughly the advertised `icy-br: 128` (128 kbps = 16
    /// KB/s), matching how a real station streams. Sending as fast as the
    /// loopback pipe allows let a client end up with a large backlog of
    /// already-buffered audio, which is unrealistic and, worse, meant a
    /// dropped connection wasn't actually noticed for a long time -- the
    /// client just kept consuming what it had already received.
    private static func pacingDelay(forBytes count: Int) -> DispatchTimeInterval {
        .milliseconds(Int((Double(count) / 16000) * 1000))
    }

    private func sendMetadataFrame(_ connection: NWConnection, queue: DispatchQueue, nextAudioOffset: Int) {
        let titleChanged = self.currentTitle != self.lastEmittedTitle
        let frame = IcyMetadataFramer.frame(title: titleChanged ? self.currentTitle : nil)
        if titleChanged { self.lastEmittedTitle = self.currentTitle }
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else {
                self?.removeStreamConnection(connection)
                return
            }
            self.streamChunk(
                connection,
                queue: queue,
                audioOffset: nextAudioOffset,
                bytesUntilMetadata: self.metaintBytes
            )
        })
    }

    private func removeStreamConnection(_ connection: NWConnection) {
        self.streamConnections.removeAll { $0 === connection }
    }
}
