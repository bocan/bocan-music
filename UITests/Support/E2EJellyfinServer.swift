import Foundation
import Network

// MARK: - E2EJellyfinServer

/// A loopback fake Jellyfin server for the ADR-097 slice 9 journey: public
/// info, password sign-in, the signed-in ping, the music lists, the audio
/// stream, favourites, play reports and sign-out. It answers only what the
/// app asks for, in the shapes the Jellyfin SDK decodes.
///
/// It has the same shape as `E2EPodcastServer` (ADR-085): a plain class with
/// a queue-confined `NWListener`, bound to loopback only, where every answer is
/// `Content-Length` terminated. It also keeps a log of the calls that change
/// something on a real server, so a journey can prove the app reached it:
/// sign-in, favourites, play reports and sign-out.
final class E2EJellyfinServer {
    /// The server's address, as a user types it into Settings.
    let baseURL: URL

    private let listener: NWListener
    private let queue: DispatchQueue
    private let state: JellyfinServerState

    /// - Parameter songSeconds: the length of each song's audio. Long enough
    ///   that the song is still playing when the journey looks, short enough
    ///   that the stream cache downloads it at once.
    init(songSeconds: Double = 30) throws {
        let audio = PodcastFixtureAudio.makeWAV(seconds: songSeconds)
        let queue = DispatchQueue(label: "e2e.jellyfin-server")
        let state = JellyfinServerState(songAudio: audio, songSeconds: songSeconds)

        // Loopback only, as E2EPodcastServer: an all-interfaces listener trips
        // the local-network consent prompt and stalls on an unattended runner.
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)

        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { newState in
            if case .ready = newState {
                ready.signal()
            }
        }
        listener.newConnectionHandler = { connection in
            state.accept(connection, queue: queue)
        }
        listener.start(queue: queue)

        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port else {
            listener.cancel()
            throw E2EJellyfinServerError.neverBecameReady
        }
        guard let base = URL(string: "http://127.0.0.1:\(port.rawValue)") else {
            listener.cancel()
            throw E2EJellyfinServerError.neverBecameReady
        }

        self.listener = listener
        self.queue = queue
        self.state = state
        self.baseURL = base
    }

    func stop() {
        self.queue.sync { self.state.cancelAll() }
        self.listener.cancel()
    }

    deinit {
        self.listener.cancel()
    }

    // MARK: - What the app did

    /// Every call that changes something on a real server, oldest first, as
    /// `"<METHOD> <path>"` (no query): sign-in, favourites, play reports,
    /// sign-out.
    var actions: [String] {
        self.queue.sync { self.state.actions }
    }

    /// Item ids the app has fetched audio for.
    var streamedItemIDs: [String] {
        self.queue.sync { self.state.streamedItemIDs }
    }

    /// Item ids that are favourites now.
    var favouriteItemIDs: Set<String> {
        self.queue.sync { self.state.favourites }
    }
}

// MARK: - Fixture data

/// The fixed world the fake server serves. The journey finds rows by these names.
enum E2EJellyfinFixture {
    static let serverName = "E2E Jellyfin"
    // Ids are 32 hex digits with no dashes, as the real server sends them.
    static let serverID = "e2e0000000000000000000000000000a"
    static let userID = "e2e0000000000000000000000000000b"
    static let username = "listener"
    static let password = "e2e-password"
    static let accessToken = "e2e-jellyfin-access-token"

    static let artistID = "e2e0000000000000000000000000000c"
    static let artistName = "E2E Stub Artist"
    static let albumID = "e2e0000000000000000000000000000d"
    static let albumName = "E2E Stub Album"
    static let genreID = "e2e0000000000000000000000000000e"
    static let playlistID = "e2e0000000000000000000000000000f"

    /// The two songs, in table order.
    static let songs: [E2EJellyfinSong] = [
        E2EJellyfinSong(id: "e2e00000000000000000000000000001", title: "Jellyfin Tone One", track: 1),
        E2EJellyfinSong(id: "e2e00000000000000000000000000002", title: "Jellyfin Tone Two", track: 2),
    ]
}

/// One song on the fake server.
struct E2EJellyfinSong {
    let id: String
    let title: String
    let track: Int
}

// MARK: - E2EJellyfinServerError

enum E2EJellyfinServerError: Error {
    case neverBecameReady
}
