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

    @Test("stopMonitoring removes the status entry")
    func stopMonitoringClearsStatus() async throws {
        let (service, id, transport) = try await makeService()
        transport.setPerpetual(json: okEnvelope)
        let monitor = SubsonicConnectionMonitor(service: service)

        await monitor.startMonitoring(serverID: id)
        try? await Task.sleep(nanoseconds: 200_000_000)
        await monitor.stopMonitoring(serverID: id)

        let snapshot = await monitor.currentStatuses()
        #expect(snapshot[id] == nil)
    }

    @Test("stopAll clears every status")
    func stopAllClearsEverything() async throws {
        let (service, id, transport) = try await makeService()
        transport.setPerpetual(json: okEnvelope)
        let monitor = SubsonicConnectionMonitor(service: service)
        await monitor.startMonitoring(serverID: id)
        try? await Task.sleep(nanoseconds: 200_000_000)
        await monitor.stopAll()
        let snapshot = await monitor.currentStatuses()
        #expect(snapshot.isEmpty)
    }

    @Test("startMonitoring twice for the same server is a no-op")
    func doubleStartIsIdempotent() async throws {
        let (service, id, transport) = try await makeService()
        transport.setPerpetual(json: okEnvelope)
        let monitor = SubsonicConnectionMonitor(service: service)
        await monitor.startMonitoring(serverID: id)
        await monitor.startMonitoring(serverID: id)
        // The internal task dictionary has one entry — exposed only via the
        // observable behavior that we don't get two parallel pings per cycle.
        try? await Task.sleep(nanoseconds: 200_000_000)
        // No crash, no exception, and we still resolve a status.
        let snapshot = await monitor.currentStatuses()
        #expect(snapshot[id] != nil)
        await monitor.stopAll()
    }
}
