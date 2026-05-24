import AppKit
import Foundation
import Observability

// MARK: - SubsonicConnectionMonitor

/// Maintains a per-server ping loop and publishes live `SubsonicConnectionStatus`
/// updates over an `AsyncStream`.
///
/// ## Backoff schedule
/// On failure: 5 s → 10 s → 20 s → 40 s → 80 s → 160 s → 300 s (cap).
/// On success: resets to the normal 60-second polling interval.
///
/// ## Wake from sleep
/// `NSWorkspace.didWakeNotification` triggers an immediate re-ping of all
/// servers so status is refreshed as soon as the Mac comes back online.
public actor SubsonicConnectionMonitor {
    // MARK: - Types

    public typealias StatusUpdate = (serverID: UUID, status: SubsonicConnectionStatus)

    // MARK: - Constants

    private static let pollInterval: TimeInterval = 60
    private static let backoffSteps: [TimeInterval] = [5, 10, 20, 40, 80, 160, 300]

    // MARK: - State

    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var statuses: [UUID: SubsonicConnectionStatus] = [:]
    private let service: SubsonicService
    private let log = AppLogger.make(.subsonic)
    private var (stream, continuation) = AsyncStream<StatusUpdate>.makeStream()

    // MARK: - Init

    public init(service: SubsonicService) {
        self.service = service
        Task { await self.installWakeObserver() }
    }

    // MARK: - Public API

    /// Async stream of status updates.  New subscribers immediately receive the
    /// current status of every known server via `currentStatuses()`.
    public var updates: AsyncStream<StatusUpdate> {
        self.stream
    }

    /// Returns a snapshot of all current statuses.
    public func currentStatuses() -> [UUID: SubsonicConnectionStatus] {
        self.statuses
    }

    /// Starts monitoring a server (no-op if already being monitored).
    public func startMonitoring(serverID: UUID) {
        guard self.tasks[serverID] == nil else { return }
        self.tasks[serverID] = Task { await self.runLoop(serverID: serverID) }
        self.log.info("subsonic.monitor.start", ["id": serverID.uuidString])
    }

    /// Stops monitoring a server and cleans up its loop task.
    public func stopMonitoring(serverID: UUID) {
        self.tasks[serverID]?.cancel()
        self.tasks.removeValue(forKey: serverID)
        self.statuses.removeValue(forKey: serverID)
        self.log.info("subsonic.monitor.stop", ["id": serverID.uuidString])
    }

    /// Stops all monitoring loops (call on shutdown).
    public func stopAll() {
        for task in self.tasks.values {
            task.cancel()
        }
        self.tasks = [:]
        self.statuses = [:]
    }

    /// Triggers an immediate re-ping of all monitored servers (e.g. after wake).
    public func wakeAll() {
        for serverID in self.tasks.keys {
            self.tasks[serverID]?.cancel()
            self.tasks[serverID] = Task { await self.runLoop(serverID: serverID) }
        }
        self.log.info("subsonic.monitor.wake", ["count": self.tasks.count])
    }

    // MARK: - Loop

    private func runLoop(serverID: UUID) async {
        var backoffIndex = 0
        self.emit(serverID: serverID, status: .connecting)

        while !Task.isCancelled {
            do {
                try await self.service.ping(serverID: serverID)
                let now = Date()
                self.emit(serverID: serverID, status: .online(lastPing: now))
                backoffIndex = 0
                self.log.debug("subsonic.monitor.ping.ok", ["id": serverID.uuidString])
                try await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
            } catch let error as SubsonicError {
                if error.isAuthenticationFailure {
                    let msg = error.localizedDescription
                    self.emit(serverID: serverID, status: .authFailed(msg))
                    self.log.warning(
                        "subsonic.monitor.auth.fail",
                        ["id": serverID.uuidString, "err": msg]
                    )
                    // Stop the loop; user must edit the server to recover.
                    self.tasks.removeValue(forKey: serverID)
                    return
                }

                let msg = error.localizedDescription
                let isServerErr = if case let .transport(inner) = error, case .httpError = inner {
                    true
                } else {
                    false
                }
                if isServerErr {
                    self.emit(serverID: serverID, status: .serverError(msg))
                } else {
                    self.emit(serverID: serverID, status: .unreachable(msg))
                }

                let delay = Self.backoffSteps[min(backoffIndex, Self.backoffSteps.count - 1)]
                self.log.info(
                    "subsonic.monitor.backoff",
                    ["id": serverID.uuidString, "delay": delay, "attempt": backoffIndex + 1]
                )
                backoffIndex = min(backoffIndex + 1, Self.backoffSteps.count - 1)
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    return // cancelled
                }
            } catch {
                // Unexpected non-SubsonicError; stop silently.
                return
            }
        }
    }

    // MARK: - Emission

    private func emit(serverID: UUID, status: SubsonicConnectionStatus) {
        self.statuses[serverID] = status
        self.continuation.yield((serverID: serverID, status: status))
    }

    // MARK: - Wake observer

    private func installWakeObserver() {
        NotificationCenter.default.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task {
                await self?.wakeAll()
            }
        }
    }
}
