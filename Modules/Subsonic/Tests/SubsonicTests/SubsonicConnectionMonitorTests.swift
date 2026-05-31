import AppKit
import Foundation
import Persistence
import SwiftSonic
import Testing
@testable import Subsonic

// MARK: - File-local stub transport

private final class MonitorStubTransport: HTTPTransport, @unchecked Sendable {
    private var responses: [(Data, Int)] = []
    private(set) var pingCount = 0

    /// Re-supplies the same response indefinitely so the monitor's polling
    /// loop never starves the stub.
    private var perpetual: (Data, Int)?

    func enqueue(json: String, statusCode: Int = 200) {
        self.responses.append((Data(json.utf8), statusCode))
    }

    func setPerpetual(json: String, statusCode: Int = 200) {
        self.perpetual = (Data(json.utf8), statusCode)
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        self.pingCount += 1
        let (data, status): (Data, Int)
        if !self.responses.isEmpty {
            (data, status) = self.responses.removeFirst()
        } else if let p = self.perpetual {
            (data, status) = p
        } else {
            throw URLError(.badServerResponse)
        }
        let resp = HTTPURLResponse(
            url: request.url ?? URL(string: "https://test.local")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, resp)
    }
}

private let okEnvelope = """
{ "subsonic-response": { "status": "ok", "version": "1.16.1" } }
"""

private let authFailEnvelope = """
{ "subsonic-response": { "status": "failed", "version": "1.16.1",
"error": { "code": 40, "message": "Wrong username or password." } } }
"""

private let testServerURL = URL(string: "https://music.test.local")!

private func makeService() async throws -> (SubsonicService, UUID, MonitorStubTransport) {
    let db = try await Database(location: .inMemory)
    let repo = SubsonicServerRepository(database: db)
    let store = SubsonicServerStore(repository: repo)
    let id = UUID()
    try await repo.insert(SubsonicServerDTO(
        id: id,
        name: "Test",
        serverURL: testServerURL,
        authKind: "tokenSalt",
        username: "alice",
        keychainAccount: id.uuidString
    ))
    let transport = MonitorStubTransport()
    let client = SwiftSonicClient(
        configuration: ServerConfiguration(
            serverURL: testServerURL,
            auth: .tokenAuth(username: "alice", password: "s3cr3t", reusesSalt: false)
        ),
        transport: transport,
        retryPolicy: RetryPolicy(maxAttempts: 1, baseDelay: 0)
    )
    let service = SubsonicService(store: store)
    await service._registerClientForTesting(client, serverID: id)
    return (service, id, transport)
}

/// Awaits the first status update for `serverID` matching `predicate` on
/// `stream`, or returns `nil` after `timeoutNanos`. The monitor emits from a
/// detached loop task, so consumers must await the emission rather than guess a
/// fixed `Task.sleep` delay that races under load (#322).
private func awaitStatus(
    for serverID: UUID,
    on stream: AsyncStream<SubsonicConnectionMonitor.StatusUpdate>,
    matching predicate: @escaping @Sendable (SubsonicConnectionStatus) -> Bool = { _ in true },
    timeoutNanos: UInt64 = 2_000_000_000
) async -> SubsonicConnectionStatus? {
    await withTaskGroup(of: SubsonicConnectionStatus?.self) { group in
        group.addTask {
            for await update in stream where update.serverID == serverID && predicate(update.status) {
                return update.status
            }
            return nil
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: timeoutNanos)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

/// True when a status is `.online`.
private let isOnline: @Sendable (SubsonicConnectionStatus) -> Bool = {
    if case .online = $0 { true } else { false }
}

// MARK: - Tests

@Suite("SubsonicConnectionMonitor")
struct SubsonicConnectionMonitorTests {
    @Test("currentStatuses is empty initially")
    func startsEmpty() async throws {
        let (service, _, _) = try await makeService()
        let monitor = SubsonicConnectionMonitor(service: service)
        let snapshot = await monitor.currentStatuses()
        #expect(snapshot.isEmpty)
    }

    @Test("startMonitoring then a successful ping flips status to .online")
    func transitionsToOnline() async throws {
        let (service, id, transport) = try await makeService()
        transport.setPerpetual(json: okEnvelope)
        let monitor = SubsonicConnectionMonitor(service: service)

        await monitor.startMonitoring(serverID: id)

        // Drain the updates stream until we see online (bounded by a deadline).
        let updates = await monitor.updates
        let onlineSeen = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await update in updates where update.serverID == id {
                    if case .online = update.status { return true }
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(onlineSeen)
        #expect(transport.pingCount >= 1)

        await monitor.stopAll()
    }

    @Test("auth failure surfaces .authFailed and terminates the loop")
    func authFailureTerminatesLoop() async throws {
        let (service, id, transport) = try await makeService()
        transport.setPerpetual(json: authFailEnvelope)
        let monitor = SubsonicConnectionMonitor(service: service)

        await monitor.startMonitoring(serverID: id)

        let updates = await monitor.updates
        let authSeen = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await update in updates where update.serverID == id {
                    if case .authFailed = update.status { return true }
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(authSeen)

        await monitor.stopAll()
    }

    @Test("a workspace wake notification restarts the loop via wakeAll (#274)")
    func wakeNotificationTriggersReping() async throws {
        let (service, id, transport) = try await makeService()
        transport.setPerpetual(json: okEnvelope)
        let monitor = SubsonicConnectionMonitor(service: service)

        await monitor.startMonitoring(serverID: id)
        let updates = await monitor.updates

        // Post the wake notification repeatedly rather than guessing a single
        // fixed delay for the loop to reach .online and the asynchronously
        // installed wake observer to register (both of which race under load).
        // Each post that lands triggers wakeAll(), which cancels and restarts
        // the loop and re-emits .connecting. A 200ms cadence is slower than a
        // stub ping, so .online settles between posts and the consumer reliably
        // sees .online followed by a fresh .connecting (#322).
        let poster = Task {
            while !Task.isCancelled {
                NSWorkspace.shared.notificationCenter.post(
                    name: NSWorkspace.didWakeNotification,
                    object: nil
                )
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }

        // Watch the stream for: .online (loop ran) then a fresh .connecting,
        // which only happens because wakeAll() cancelled and restarted the
        // loop. If the observer were still on NotificationCenter.default (or
        // never wired) the post would be ignored and we would time out.
        let restarted = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                var sawOnline = false
                for await update in updates where update.serverID == id {
                    switch update.status {
                    case .online:
                        sawOnline = true
                    case .connecting where sawOnline:
                        return true
                    default:
                        break
                    }
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        poster.cancel()

        #expect(restarted, "wakeAll() should restart the monitor loop after a wake notification")
        await monitor.stopAll()
    }

    @Test("stopMonitoring removes the status entry")
    func stopMonitoringClearsStatus() async throws {
        let (service, id, transport) = try await makeService()
        transport.setPerpetual(json: okEnvelope)
        let monitor = SubsonicConnectionMonitor(service: service)

        let updates = await monitor.updates
        await monitor.startMonitoring(serverID: id)
        // Wait until the loop has settled on .online (then idle for a poll cycle)
        // before stopping, so no late emission repopulates the status afterwards.
        _ = await awaitStatus(for: id, on: updates, matching: isOnline)
        await monitor.stopMonitoring(serverID: id)

        let snapshot = await monitor.currentStatuses()
        #expect(snapshot[id] == nil)
    }

    @Test("stopAll clears every status")
    func stopAllClearsEverything() async throws {
        let (service, id, transport) = try await makeService()
        transport.setPerpetual(json: okEnvelope)
        let monitor = SubsonicConnectionMonitor(service: service)
        let updates = await monitor.updates
        await monitor.startMonitoring(serverID: id)
        _ = await awaitStatus(for: id, on: updates, matching: isOnline)
        await monitor.stopAll()
        let snapshot = await monitor.currentStatuses()
        #expect(snapshot.isEmpty)
    }

    @Test("startMonitoring twice for the same server is a no-op")
    func doubleStartIsIdempotent() async throws {
        let (service, id, transport) = try await makeService()
        transport.setPerpetual(json: okEnvelope)
        let monitor = SubsonicConnectionMonitor(service: service)
        let updates = await monitor.updates
        await monitor.startMonitoring(serverID: id)
        await monitor.startMonitoring(serverID: id)
        // The internal task dictionary has one entry — exposed only via the
        // observable behavior that we don't get two parallel pings per cycle.
        // Await the loop's first published status instead of guessing a delay.
        _ = await awaitStatus(for: id, on: updates)
        // No crash, no exception, and we still resolve a status.
        let snapshot = await monitor.currentStatuses()
        #expect(snapshot[id] != nil)
        await monitor.stopAll()
    }
}
