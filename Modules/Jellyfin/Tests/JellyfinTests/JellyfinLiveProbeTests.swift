import Foundation
import Persistence
import Testing
@testable import Jellyfin

/// Opt-in live probe: does a token issued by this module keep working?
///
/// It signs in once against a real server and follows the app's own path: the
/// token goes through the Keychain store into `JellyfinService`, and the
/// connection monitor polls it. Every 15 s for 150 s it pings and makes a small
/// browse request, as scrolling does, and it records any refused sign-in the
/// monitor sees. A token that the server accepts for 150 s here, but that the
/// app loses, points at the app; one lost here points at this module.
///
/// It caught the `Authorization` header bug (docs/GOTCHAS.md, "Jellyfin"): a
/// non-ASCII computer name lost the token on about half of all requests.
///
/// Set `JELLYFIN_LIVE_URL`, `JELLYFIN_LIVE_USER` and `JELLYFIN_PASSWORD` to run
/// it, with `swift test --filter JellyfinLiveProbeTests`. The password is read
/// from the environment and is never printed or stored, and the probe signs out
/// at the end. Without the variables the suite is skipped.
private let liveEnvironment = ProcessInfo.processInfo.environment
private let liveURL: URL? = liveEnvironment["JELLYFIN_LIVE_URL"].flatMap { URL(string: $0) }
private let liveUser: String? = liveEnvironment["JELLYFIN_LIVE_USER"]
private let livePassword: String? = liveEnvironment["JELLYFIN_PASSWORD"]

@Suite(
    "Live token probe",
    .serialized,
    .enabled(if: liveURL != nil && liveUser != nil && livePassword != nil)
)
struct JellyfinLiveProbeTests {
    private static let rounds = 10
    private static let interval: Duration = .seconds(15)

    private func say(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    /// What one sign-in produced.
    private struct Probe {
        let service: JellyfinService
        let store: JellyfinServerStore
        let server: JellyfinServer
    }

    /// Signs in once and puts the token through the Keychain store into a service,
    /// as the add flow does.
    private func signedInService() async throws -> Probe {
        let url = try #require(liveURL)
        let endpoint = try JellyfinEndpoint(serverURL: url, deviceID: UUID().uuidString)
        let session = try await JellyfinAuth().signIn(
            endpoint,
            username: #require(liveUser),
            password: #require(livePassword)
        )

        let database = try await Persistence.Database(location: .inMemory)
        let store = JellyfinServerStore(
            repository: JellyfinServerRepository(database: database),
            keychainService: "io.cloudcauldron.bocan.jellyfin.live-probe.\(UUID().uuidString)"
        )
        let service = JellyfinService(store: store)
        let server = JellyfinServer(
            name: "probe-\(UUID().uuidString.prefix(6))",
            serverURL: url,
            userID: session.userID,
            username: session.username,
            deviceID: endpoint.deviceID
        )
        try await store.add(server, session: session)
        try await service.refreshClient(for: server)
        return Probe(service: service, store: store, server: server)
    }

    @Test("a token keeps working through the store, the service and the monitor")
    func tokenSurvives() async throws {
        let probe = try await self.signedInService()
        let service = probe.service
        let store = probe.store
        let server = probe.server
        let monitor = JellyfinConnectionMonitor(
            service: service,
            timing: .init(pollInterval: Self.interval, backoff: [.seconds(5)], persistInterval: 3600),
            watchesNetwork: false
        )
        let refusals = Refusals()
        let watcher = Task {
            for await update in await monitor.updates {
                if case let .authFailed(message) = update.status {
                    refusals.add(message)
                }
            }
        }
        await monitor.startMonitoring(serverID: server.id)

        self.say("Signed in. Checking every 15 s for \(Self.rounds * 15) s.")
        var failures: [String] = []
        for round in 0 ... Self.rounds {
            let ping = await Self.outcome { try await service.ping(serverID: server.id) }
            let browse = await Self.outcome { _ = try await service.songs(serverID: server.id, limit: 5) }
            self.say("  t=\(round * 15) s  ping: \(ping)  browse: \(browse)  monitor refusals: \(refusals.all.count)")
            if ping != "ok" || browse != "ok" {
                failures.append("t=\(round * 15) \(ping) / \(browse)")
            }
            if round < Self.rounds {
                try await Task.sleep(for: Self.interval)
            }
        }

        watcher.cancel()
        await monitor.stopAll()
        await service.endSession(serverID: server.id)
        try await store.remove(id: server.id)

        self.say("RESULT requests: \(failures.isEmpty ? "all ok" : failures.joined(separator: "; "))")
        self.say("RESULT monitor: \(refusals.all.isEmpty ? "all ok" : refusals.all.joined(separator: "; "))")
        #expect(failures.isEmpty, "a request lost the token")
        #expect(refusals.all.isEmpty, "the monitor saw a refused sign-in")
    }

    /// "ok", or the error's own description, which holds no URL and no token.
    private static func outcome(_ body: () async throws -> Void) async -> String {
        do {
            try await body()
            return "ok"
        } catch {
            return error.localizedDescription
        }
    }
}

/// A lock-guarded list of the refusals the monitor reported.
private final class Refusals: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    func add(_ message: String) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.messages.append(message)
    }

    var all: [String] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.messages
    }
}
