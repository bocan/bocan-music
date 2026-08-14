import Foundation
import Network

// MARK: - E2EStreamServer

/// A loopback fake ICY internet-radio station for E2E tests (phase 34): an
/// `/stream` endpoint serving a looping AAC/ADTS fixture with real
/// interleaved `StreamTitle` metadata and `icy-*` headers, plus a
/// `/playlist.m3u` endpoint for the playlist-indirection journey. Modeled
/// on `StallingListener`'s plain-class, queue-confined `NWListener` shape
/// (proven in this same target) rather than `SyncServer`'s actor-based HTTP
/// machinery, since that module isn't a UITests dependency.
///
/// Unlike `StallingListener`, this server is driven directly by Swift
/// method calls (`scriptTitle`, `dropConnections`, `refuseConnections`),
/// not HTTP control endpoints — it runs in the same process as the test
/// code that scripts it, so there is no need for a second network surface.
final class E2EStreamServer {
    /// The URL the app should be pointed at for the fake station.
    let streamURL: URL
    /// The URL serving a one-station `.m3u` playlist pointing at `streamURL`.
    let playlistURL: URL

    private let listener: NWListener
    private let queue: DispatchQueue
    private let state: ServerState

    /// - Parameters:
    ///   - stationName: value of `icy-name` and the `.m3u` entry's title.
    ///   - initialTitle: the very first `StreamTitle`, served from byte zero
    ///     of the interleave — FFmpeg's stream probe reads well past one
    ///     `metaint` interval at open, so the first real title must already
    ///     be there or the probe races it (phase 34 doc gotcha).
    ///   - metaintBytes: ICY metadata interval; real stations commonly use
    ///     8-16 KB, small enough here that a short fixture still carries a
    ///     handful of metadata boundaries.
    init(
        stationName: String = "E2E Test FM",
        genre: String = "Ambient",
        initialTitle: String = "E2E Fixtures - Opening Theme",
        metaintBytes: Int = 8192
    ) throws {
        let audio = try AacFixtureAudio.make(seconds: 3)
        let queue = DispatchQueue(label: "e2e.stream-server")
        let state = ServerState(
            audio: audio,
            metaintBytes: metaintBytes,
            currentTitle: initialTitle,
            stationName: stationName,
            genre: genre
        )

        // Loopback only, matching StallingListener: an all-interfaces
        // listener trips the macOS local-network consent prompt and stalls
        // in `.waiting` forever on an unattended runner.
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)

        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { newState in
            if case .ready = newState { ready.signal() }
        }
        listener.newConnectionHandler = { connection in
            state.accept(connection, queue: queue)
        }
        listener.start(queue: queue)

        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port else {
            listener.cancel()
            throw E2EStreamServerError.neverBecameReady
        }
        guard let base = URL(string: "http://127.0.0.1:\(port.rawValue)") else {
            listener.cancel()
            throw E2EStreamServerError.neverBecameReady
        }

        self.listener = listener
        self.queue = queue
        self.state = state
        self.streamURL = base.appendingPathComponent("stream")
        self.playlistURL = base.appendingPathComponent("playlist.m3u")
        state.streamURL = self.streamURL
    }

    func stop() {
        // Synchronous, not `.async` like the script-control methods below:
        // callers (test teardown) expect connections genuinely gone before
        // this returns. Matches `StallingListener.stop()`'s `queue.sync` —
        // without it, this races the same connection-handling closures that
        // already run on `self.queue` (found via ThreadSanitizer).
        self.queue.sync { self.state.cancelAll() }
        self.listener.cancel()
    }

    deinit {
        self.listener.cancel()
    }

    // MARK: - Script control

    /// Changes the title emitted at the next metadata boundary on every live
    /// stream connection. Real stations don't announce mid-interval, so a
    /// caller polling the app's displayed title should expect this to land
    /// within roughly one `metaintBytes` worth of audio, not immediately.
    func scriptTitle(_ text: String) {
        self.queue.async { self.state.currentTitle = text }
    }

    /// Cancels every currently-open `/stream` connection without warning —
    /// a bare connection drop, the shorter half of the reconnect journey
    /// pair.
    func dropConnections() {
        self.queue.async { self.state.cancelAllStreamConnections() }
    }

    /// Makes every new connection for the next `seconds` fail immediately
    /// (cancelled right after accept, before any bytes are sent) — stands
    /// in for "server unreachable" so the reconnect-exhaustion journey can
    /// outlast the app's retry budget without an indefinite hang.
    func refuseConnections(for seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        self.queue.async { self.state.refuseUntil = until }
    }
}

// MARK: - E2EStreamServerError

enum E2EStreamServerError: Error {
    case neverBecameReady
}
