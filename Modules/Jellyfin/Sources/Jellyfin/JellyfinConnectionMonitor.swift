import Foundation
import Network
import Observability

// MARK: - JellyfinConnectionMonitor

/// Maintains a per-server ping loop and publishes live `JellyfinConnectionStatus`
/// updates over an `AsyncStream`. It mirrors `SubsonicConnectionMonitor`.
///
/// ## Backoff schedule
/// On failure: 5 s, 10 s, 20 s, 40 s, 80 s, 160 s, then 300 s (cap).
/// On success: back to the normal 60-second polling interval.
///
/// ## Revoked token
/// A 401 stops the loop and emits `.authFailed`. The user must sign in again.
///
/// ## Wake from sleep
/// The app target observes the wake notification and calls `wakeAll()`. This
/// module must not import AppKit, so the subscription lives in the app.
public actor JellyfinConnectionMonitor {
    // MARK: - Types

    /// One element of `updates`: a server and the status it has just changed to.
    public typealias StatusUpdate = (serverID: UUID, status: JellyfinConnectionStatus)

    /// The loop's timing. The defaults are the product values; tests shorten them.
    struct Timing: Sendable {
        var pollInterval: Duration = .seconds(60)
        var backoff: [Duration] = [5, 10, 20, 40, 80, 160, 300].map { .seconds($0) }
        /// How long a successful ping stays unwritten before `last_connected_at` is written again.
        var persistInterval: TimeInterval = 600
    }

    // MARK: - State

    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var statuses: [UUID: JellyfinConnectionStatus] = [:]
    private var lastPersisted: [UUID: Date] = [:]
    private let service: JellyfinService
    private let timing: Timing
    private let log = AppLogger.make(.jellyfin)
    private var (stream, continuation) = AsyncStream<StatusUpdate>.makeStream()
    private let pathMonitor: NWPathMonitor?

    // MARK: - Init

    /// Creates a monitor that pings through `service` and starts its network
    /// path monitor. No server is pinged until `startMonitoring(serverID:)`.
    public init(service: JellyfinService) {
        self.init(service: service, timing: Timing(), watchesNetwork: true)
    }

    init(service: JellyfinService, timing: Timing, watchesNetwork: Bool) {
        self.service = service
        self.timing = timing
        guard watchesNetwork else {
            self.pathMonitor = nil
            return
        }
        let monitor = NWPathMonitor()
        self.pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            if path.status == .satisfied {
                // Network came back: re-ping every server at once.
                Task { await self.wakeAll() }
            } else {
                // Network dropped: flip statuses without waiting for the next poll.
                Task { await self.handleNetworkLost() }
            }
        }
        monitor.start(queue: DispatchQueue(
            label: "io.cloudcauldron.bocan.jellyfin.monitor.path",
            qos: .utility
        ))
    }

    deinit {
        self.pathMonitor?.cancel()
    }

    // MARK: - Public API

    /// Async stream of status updates.
    public var updates: AsyncStream<StatusUpdate> {
        self.stream
    }

    /// Returns a snapshot of all current statuses.
    public func currentStatuses() -> [UUID: JellyfinConnectionStatus] {
        self.statuses
    }

    /// Starts monitoring a server (no-op if already being monitored).
    public func startMonitoring(serverID: UUID) {
        guard self.tasks[serverID] == nil else { return }
        self.tasks[serverID] = Task { await self.runLoop(serverID: serverID) }
        self.log.info("jellyfin.monitor.start", ["id": serverID.uuidString])
    }

    /// Stops monitoring a server and cleans up its loop task.
    public func stopMonitoring(serverID: UUID) {
        self.tasks[serverID]?.cancel()
        self.tasks.removeValue(forKey: serverID)
        self.statuses.removeValue(forKey: serverID)
        self.lastPersisted.removeValue(forKey: serverID)
        self.log.info("jellyfin.monitor.stop", ["id": serverID.uuidString])
    }

    /// Stops all monitoring loops (call on shutdown).
    public func stopAll() {
        for task in self.tasks.values {
            task.cancel()
        }
        self.tasks = [:]
        self.statuses = [:]
        self.lastPersisted = [:]
    }

    /// Re-pings every monitored server at once (after wake or network restore).
    /// A server stopped by a 401 stays stopped: waking cannot fix a revoked token.
    public func wakeAll() {
        for serverID in self.tasks.keys {
            self.tasks[serverID]?.cancel()
            self.tasks[serverID] = Task { await self.runLoop(serverID: serverID) }
        }
        self.log.info("jellyfin.monitor.wake", ["count": self.tasks.count])
    }

    /// Pings one server again at once. Another path calls it when the server
    /// refused its token (a play report answered 401), so the status follows
    /// from the monitor's own authenticated ping, not from that one answer:
    /// a 401 is not always a revoked token (docs/GOTCHAS.md, "Jellyfin").
    /// A server stopped by an earlier 401 is checked again too.
    public func recheck(serverID: UUID) {
        self.tasks[serverID]?.cancel()
        self.tasks[serverID] = Task { await self.runLoop(serverID: serverID) }
        self.log.info("jellyfin.monitor.recheck", ["id": serverID.uuidString])
    }

    /// Called when `NWPathMonitor` reports the path is no longer satisfied.
    /// Cancels the ping loops and emits `.unreachable` at once, so the UI does
    /// not wait up to 60 s for the next poll.
    private func handleNetworkLost() {
        guard !self.tasks.isEmpty else { return }
        for serverID in self.tasks.keys {
            self.tasks[serverID]?.cancel()
            // The key stays in `tasks` so `wakeAll()` can restart the loop.
            self.emit(serverID: serverID, status: .unreachable("Network unavailable"))
        }
        self.log.info("jellyfin.monitor.network.lost", ["count": self.tasks.count])
    }

    // MARK: - Loop

    /// One server's loop. Every `await` lets `stopMonitoring`, `recheck` or
    /// `wakeAll` run on this actor, and they cancel this loop and may start
    /// another for the same server. So after each one, a cancelled loop
    /// returns before it touches any state. Otherwise a stopped server's
    /// status came back, and a refused ping deleted the new loop's entry,
    /// leaving that loop running untracked.
    private func runLoop(serverID: UUID) async {
        var backoffIndex = 0
        // A stop can run between `startMonitoring` and this task's first step.
        guard !Task.isCancelled else { return }
        self.emit(serverID: serverID, status: .connecting)

        while !Task.isCancelled {
            do {
                try await self.service.ping(serverID: serverID)
                guard !Task.isCancelled else { return }
                self.emit(serverID: serverID, status: .online(lastPing: Date()))
                await self.persistConnected(serverID: serverID)
                backoffIndex = 0
                self.log.debug("jellyfin.monitor.ping.ok", ["id": serverID.uuidString])
                try await Task.sleep(for: self.timing.pollInterval)
            } catch is CancellationError {
                return
            } catch let error as JellyfinError {
                guard !Task.isCancelled else { return }
                if error.isAuthenticationFailure {
                    let message = error.localizedDescription
                    self.emit(serverID: serverID, status: .authFailed(message))
                    self.log.warning("jellyfin.monitor.auth.fail", ["id": serverID.uuidString, "err": message])
                    // Stop the loop. The user must sign in again to recover.
                    self.tasks.removeValue(forKey: serverID)
                    return
                }

                let message = error.localizedDescription
                if case .http = error {
                    self.emit(serverID: serverID, status: .serverError(message))
                } else {
                    self.emit(serverID: serverID, status: .unreachable(message))
                }

                let steps = self.timing.backoff
                let delay = steps[min(backoffIndex, steps.count - 1)]
                self.log.info(
                    "jellyfin.monitor.backoff",
                    ["id": serverID.uuidString, "delay": "\(delay)", "attempt": backoffIndex + 1]
                )
                backoffIndex = min(backoffIndex + 1, steps.count - 1)
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return // cancelled
                }
            } catch {
                // A non-Jellyfin error means the service failed in an unexpected
                // way. Stop quietly, as the Subsonic monitor does.
                self.log.warning("jellyfin.monitor.unexpected", ["id": serverID.uuidString, "error": String(reflecting: error)])
                return
            }
        }
    }

    /// Writes `last_connected_at` when the server just came online, and again
    /// at most every `persistInterval`, so a 60-second ping does not write the
    /// database every minute.
    private func persistConnected(serverID: UUID) async {
        let now = Date()
        if let last = self.lastPersisted[serverID], now.timeIntervalSince(last) < self.timing.persistInterval {
            return
        }
        self.lastPersisted[serverID] = now
        await self.service.recordConnected(serverID: serverID, at: now)
    }

    // MARK: - Emission

    private func emit(serverID: UUID, status: JellyfinConnectionStatus) {
        self.statuses[serverID] = status
        self.continuation.yield((serverID: serverID, status: status))
    }
}
