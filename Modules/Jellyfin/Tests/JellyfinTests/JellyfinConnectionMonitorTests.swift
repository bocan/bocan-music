import Foundation
import Persistence
import Testing
@testable import Jellyfin

@Suite("JellyfinConnectionMonitor", .serialized)
struct JellyfinConnectionMonitorTests {
    private struct Harness {
        let monitor: JellyfinConnectionMonitor
        let service: JellyfinService
        let repository: JellyfinServerRepository
        let stub: StubJellyfinClient
        let serverID: UUID
        let statuses: Locked<[JellyfinConnectionStatus]>
        let reader: Task<Void, Never>
    }

    private static let fast = JellyfinConnectionMonitor.Timing(
        pollInterval: .milliseconds(20),
        backoff: [.milliseconds(10), .milliseconds(20)],
        persistInterval: 3600
    )

    private func makeHarness(timing: JellyfinConnectionMonitor.Timing = fast) async throws -> Harness {
        let database = try await Persistence.Database(location: .inMemory)
        let repository = JellyfinServerRepository(database: database)
        let store = JellyfinServerStore(
            repository: repository,
            keychainService: "io.cloudcauldron.bocan.jellyfin.test.\(UUID().uuidString)"
        )
        let id = UUID()
        try await repository.insert(JellyfinServerDTO(
            id: id,
            name: "Home-\(id.uuidString.prefix(6))",
            serverURL: URL(string: "https://jf.example.test") ?? URL(filePath: "/"),
            userID: "user-1",
            deviceID: "DEVICE-1"
        ))
        let stub = StubJellyfinClient()
        let service = JellyfinService(
            store: store,
            identity: JellyfinClientIdentity(client: "Bocan", deviceName: "Test", version: "1")
        ) { _ in stub }
        await service.registerClientForTesting(stub, serverID: id)
        let monitor = JellyfinConnectionMonitor(service: service, timing: timing, watchesNetwork: false)
        let statuses = Locked<[JellyfinConnectionStatus]>([])
        let updates = await monitor.updates
        let reader = Task {
            for await update in updates where update.serverID == id {
                statuses.update { $0.append(update.status) }
            }
        }
        return Harness(
            monitor: monitor,
            service: service,
            repository: repository,
            stub: stub,
            serverID: id,
            statuses: statuses,
            reader: reader
        )
    }

    private func pings(_ harness: Harness) -> Int {
        harness.stub.calls.value.filter { $0 == "ping" }.count
    }

    @Test("a healthy server goes connecting, then online, and keeps being pinged")
    func online() async throws {
        let harness = try await self.makeHarness()
        await harness.monitor.startMonitoring(serverID: harness.serverID)
        #expect(await eventually { self.pings(harness) >= 3 })
        await harness.monitor.stopAll()
        harness.reader.cancel()
        let statuses = harness.statuses.value
        #expect(statuses.first == .connecting)
        #expect(statuses.contains { $0.isOnline })
    }

    @Test("a revoked token reports authFailed once and stops pinging")
    func revokedToken() async throws {
        let harness = try await self.makeHarness()
        harness.stub.onPing = { throw JellyfinError.unauthorized }
        await harness.monitor.startMonitoring(serverID: harness.serverID)
        #expect(await eventually { harness.statuses.value.contains { $0.requiresUserAction } })
        let pingsAtStop = self.pings(harness)
        try await Task.sleep(for: .milliseconds(150))
        #expect(self.pings(harness) == pingsAtStop)
        #expect(pingsAtStop == 1)
        let status = await harness.monitor.currentStatuses()[harness.serverID]
        #expect(status?.requiresUserAction == true)
        harness.reader.cancel()
    }

    @Test("an unreachable server backs off, then recovers and goes online")
    func recovers() async throws {
        let harness = try await self.makeHarness()
        let failures = Locked(3)
        harness.stub.onPing = {
            var shouldFail = false
            failures.update {
                if $0 > 0 {
                    $0 -= 1
                    shouldFail = true
                }
            }
            if shouldFail {
                throw JellyfinError.network("down")
            }
        }
        await harness.monitor.startMonitoring(serverID: harness.serverID)
        #expect(await eventually { harness.statuses.value.contains { $0.isOnline } })
        await harness.monitor.stopAll()
        harness.reader.cancel()
        let statuses = harness.statuses.value
        #expect(statuses.filter(\.isUnreachable).count == 3)
        // The order is connecting, unreachable (x3), then online.
        let online = try #require(statuses.firstIndex { $0.isOnline })
        let lastUnreachable = try #require(statuses.lastIndex { $0.isUnreachable })
        #expect(lastUnreachable < online)
    }

    @Test("an HTTP 5xx reports serverError, not unreachable")
    func serverError() async throws {
        let harness = try await self.makeHarness()
        harness.stub.onPing = { throw JellyfinError.http(status: 502) }
        await harness.monitor.startMonitoring(serverID: harness.serverID)
        #expect(await eventually { harness.statuses.value.contains { $0.isServerError } })
        await harness.monitor.stopAll()
        harness.reader.cancel()
    }

    @Test("a failure that keeps happening keeps backing off, without a tight loop")
    func backoffSlowsDown() async throws {
        let harness = try await self.makeHarness(timing: .init(
            pollInterval: .milliseconds(20),
            backoff: [.milliseconds(40), .milliseconds(80)],
            persistInterval: 3600
        ))
        harness.stub.onPing = { throw JellyfinError.network("down") }
        await harness.monitor.startMonitoring(serverID: harness.serverID)
        try await Task.sleep(for: .milliseconds(400))
        await harness.monitor.stopAll()
        harness.reader.cancel()
        // 40 + 80 + 80 + ... ms: at most about six tries in 400 ms, never one per few ms.
        #expect(self.pings(harness) >= 3)
        #expect(self.pings(harness) <= 8)
    }

    @Test("stopMonitoring ends the loop and forgets the status")
    func stop() async throws {
        let harness = try await self.makeHarness()
        await harness.monitor.startMonitoring(serverID: harness.serverID)
        #expect(await eventually { self.pings(harness) >= 1 })
        await harness.monitor.stopMonitoring(serverID: harness.serverID)
        try await Task.sleep(for: .milliseconds(60))
        let count = self.pings(harness)
        try await Task.sleep(for: .milliseconds(100))
        #expect(self.pings(harness) == count)
        #expect(await harness.monitor.currentStatuses()[harness.serverID] == nil)
        harness.reader.cancel()
    }

    @Test("starting a server twice runs one loop")
    func startTwice() async throws {
        let harness = try await self.makeHarness(timing: .init(pollInterval: .seconds(30), backoff: [.seconds(30)], persistInterval: 3600))
        await harness.monitor.startMonitoring(serverID: harness.serverID)
        await harness.monitor.startMonitoring(serverID: harness.serverID)
        #expect(await eventually { self.pings(harness) >= 1 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(self.pings(harness) == 1)
        await harness.monitor.stopAll()
        harness.reader.cancel()
    }

    @Test("wakeAll pings again at once, without waiting for the poll interval")
    func wake() async throws {
        let harness = try await self.makeHarness(timing: .init(pollInterval: .seconds(30), backoff: [.seconds(30)], persistInterval: 3600))
        await harness.monitor.startMonitoring(serverID: harness.serverID)
        #expect(await eventually { self.pings(harness) >= 1 })
        await harness.monitor.wakeAll()
        #expect(await eventually { self.pings(harness) >= 2 })
        await harness.monitor.stopAll()
        harness.reader.cancel()
    }

    @Test("wakeAll does not restart a server stopped by a revoked token")
    func wakeKeepsAuthFailedStopped() async throws {
        let harness = try await self.makeHarness()
        harness.stub.onPing = { throw JellyfinError.unauthorized }
        await harness.monitor.startMonitoring(serverID: harness.serverID)
        #expect(await eventually { harness.statuses.value.contains { $0.requiresUserAction } })
        await harness.monitor.wakeAll()
        try await Task.sleep(for: .milliseconds(100))
        #expect(self.pings(harness) == 1)
        harness.reader.cancel()
    }

    @Test("last_connected_at is written when the server first comes online, and not on every ping")
    func persistsLastConnected() async throws {
        let harness = try await self.makeHarness()
        await harness.monitor.startMonitoring(serverID: harness.serverID)
        #expect(await eventually { self.pings(harness) >= 4 })
        await harness.monitor.stopAll()
        harness.reader.cancel()
        let first = try #require(try await harness.repository.fetch(id: harness.serverID)?.lastConnectedAt)
        // Later pings, inside the persist interval, did not move the stored time.
        try await Task.sleep(for: .milliseconds(50))
        let second = try #require(try await harness.repository.fetch(id: harness.serverID)?.lastConnectedAt)
        #expect(first == second)
        #expect(abs(first.timeIntervalSinceNow) < 60)
    }
}
