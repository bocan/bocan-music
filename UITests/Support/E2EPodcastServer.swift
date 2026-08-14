import Foundation
import Network

// MARK: - E2EPodcastServer

/// A loopback fake podcast host for E2E tests (phase 34): serves a fixture
/// RSS feed (two episodes, one with `podcast:chapters`), the episode audio
/// files, and a chapters JSON — plus a `publishThirdEpisode()` script hook
/// so the refresh journey can prove a later fetch discovers new content.
///
/// Modeled on `E2EStreamServer`'s plain-class, queue-confined `NWListener`
/// shape, but far simpler: every response here is an ordinary
/// `Content-Length`-terminated HTTP response (episode downloads and feed
/// fetches are finite `URLSession` requests, not an open-ended stream), so
/// there is no ICY interleave and no persistent-connection pacing to get
/// right.
final class E2EPodcastServer {
    let feedURL: URL

    private let listener: NWListener
    private let queue: DispatchQueue
    private let state: PodcastServerState

    /// - Parameters:
    ///   - showTitle: the feed's `<title>`, shown in the subscribe/episode-list UI.
    ///   - episodeSeconds: duration of each synthesized episode fixture. Long
    ///     enough that a mid-clip seek (the resume-across-relaunch journey)
    ///     lands well short of the natural end, short enough that a real
    ///     `xcodebuild test` run isn't paying for minutes of audio it never
    ///     needs.
    init(showTitle: String = "E2E Test Cast", episodeSeconds: Double = 20) throws {
        let audio = PodcastFixtureAudio.makeWAV(seconds: episodeSeconds)
        let queue = DispatchQueue(label: "e2e.podcast-server")
        let state = PodcastServerState(showTitle: showTitle, episodeAudio: audio)

        // Loopback only, matching E2EStreamServer/StallingListener: an
        // all-interfaces listener trips the macOS local-network consent
        // prompt and stalls in `.waiting` forever on an unattended runner.
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
            throw E2EPodcastServerError.neverBecameReady
        }
        guard let base = URL(string: "http://127.0.0.1:\(port.rawValue)") else {
            listener.cancel()
            throw E2EPodcastServerError.neverBecameReady
        }

        self.listener = listener
        self.queue = queue
        self.state = state
        self.feedURL = base.appendingPathComponent("feed.xml")
        state.baseURL = base
    }

    func stop() {
        // Synchronous, matching E2EStreamServer.stop(): callers (test
        // teardown) expect connections genuinely gone before this returns.
        self.queue.sync { self.state.cancelAll() }
        self.listener.cancel()
    }

    deinit {
        self.listener.cancel()
    }

    // MARK: - Script control

    /// Adds a third episode to the feed content a later fetch will see —
    /// the refresh journey's "discovers newly published content" scenario.
    /// Does not affect any response already in flight.
    func publishThirdEpisode() {
        self.queue.async { self.state.thirdEpisodePublished = true }
    }
}

// MARK: - E2EPodcastServerError

enum E2EPodcastServerError: Error {
    case neverBecameReady
}
