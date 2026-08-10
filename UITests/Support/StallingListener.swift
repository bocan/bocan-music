import Foundation
import Network

// MARK: - StallingListener

/// A loopback TCP listener that accepts connections and then never sends a
/// byte. It stands in for a dead-but-reachable radio stream in the
/// launch-wedge regression journey: the phase 27 bug was the app seeking a
/// live stream at server pace while holding the transport gate, so playback
/// wedged exactly when the "server" behaved like this.
final class StallingListener {
    /// Queue-confined storage so accepted connections stay open (and get
    /// cancelled on stop) without capturing the listener in its own handler.
    private final class ConnectionBag: @unchecked Sendable {
        private let queue: DispatchQueue
        private var connections: [NWConnection] = []

        init(queue: DispatchQueue) {
            self.queue = queue
        }

        func hold(_ connection: NWConnection) {
            self.queue.async {
                self.connections.append(connection)
                connection.start(queue: self.queue)
                // Swallow the HTTP request so the client blocks awaiting a
                // response that never comes.
                connection.receive(
                    minimumIncompleteLength: 1,
                    maximumLength: 65536
                ) { _, _, _, _ in }
            }
        }

        func cancelAll() {
            self.queue.sync {
                self.connections.forEach { $0.cancel() }
                self.connections.removeAll()
            }
        }
    }

    private let listener: NWListener
    private let bag: ConnectionBag

    /// The URL the app should be pointed at, e.g. `http://127.0.0.1:PORT/stream`.
    let url: URL

    init() throws {
        let queue = DispatchQueue(label: "e2e.stalling-listener")
        let bag = ConnectionBag(queue: queue)
        // Bind loopback only: an all-interfaces listener trips the macOS
        // local-network consent prompt, which stalls the listener in
        // `.waiting` forever on an unattended runner.
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)

        let ready = DispatchSemaphore(value: 0)
        let states = StateLog()
        listener.stateUpdateHandler = { state in
            states.record("\(state)")
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { connection in
            bag.hold(connection)
        }
        listener.start(queue: queue)

        guard ready.wait(timeout: .now() + 5) == .success,
              let port = listener.port,
              let url = URL(string: "http://127.0.0.1:\(port.rawValue)/stream") else {
            listener.cancel()
            throw StallingListenerError.neverBecameReady(states: states.dump())
        }

        self.listener = listener
        self.bag = bag
        self.url = url
    }

    func stop() {
        self.bag.cancelAll()
        self.listener.cancel()
    }

    deinit {
        self.listener.cancel()
    }
}

// MARK: - StallingListenerError

enum StallingListenerError: Error {
    case neverBecameReady(states: String)
}

// MARK: - StateLog

/// Lock-guarded capture of listener state transitions, so a startup failure
/// reports what the listener actually did instead of a bare timeout.
private final class StateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [String] = []

    func record(_ state: String) {
        self.lock.withLock { self.states.append(state) }
    }

    func dump() -> String {
        self.lock.withLock { self.states.joined(separator: " -> ") }
    }
}
