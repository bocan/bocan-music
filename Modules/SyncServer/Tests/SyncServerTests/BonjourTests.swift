import Foundation
import Network
import os
import Persistence
import Testing
@testable import SyncServer

/// A pairing bridge that does nothing; the pm-flip test drives pairing via the
/// server's arm/cancel, not the ceremony.
private final class SilentBridge: PairingUIBridge, @unchecked Sendable {
    func showCode(_: String) async {}
    func requestConfirmation(deviceName _: String, fingerprintTail _: String) async -> Bool {
        false
    }

    func pairingEnded(result _: PairingResult) async {}
}

@Suite("Bonjour advertising")
struct BonjourTests {
    // MARK: - Deterministic TXT construction

    private func string(_ txt: NWTXTRecord, _ key: String) -> String? {
        if case let .string(value) = txt.getEntry(for: key) { return value }
        return nil
    }

    @Test("TXT record carries v=1, the fingerprint, and the pairing-mode flag")
    func txtRecordShape() {
        let idle = SyncListener.txtRecord(fingerprint: "abc123", pairingMode: false)
        #expect(self.string(idle, "v") == "1")
        #expect(self.string(idle, "fp") == "abc123")
        #expect(self.string(idle, "pm") == "0")

        let pairing = SyncListener.txtRecord(fingerprint: "abc123", pairingMode: true)
        #expect(self.string(pairing, "pm") == "1")
    }

    // MARK: - End-to-end discovery over the local network

    /// Browses `_bocansync._tcp` until a service with `name` appears (or the
    /// deadline passes) and returns its TXT record. Bonjour resolution is
    /// inherently timing-sensitive, so this polls with a generous deadline.
    private func discover(name: String, timeout: Duration) async throws -> NWTXTRecord? {
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: SyncListener.serviceType, domain: nil),
            using: NWParameters()
        )
        defer { browser.cancel() }
        let found = OSAllocatedUnfairLock<NWTXTRecord?>(initialState: nil)
        browser.browseResultsChangedHandler = { results, _ in
            for result in results {
                guard case let .service(serviceName, _, _, _) = result.endpoint, serviceName == name else { continue }
                if case let .bonjour(txt) = result.metadata {
                    found.withLock { $0 = txt }
                }
            }
        }
        browser.start(queue: .global())

        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let txt = found.withLock({ $0 }) { return txt }
            try await Task.sleep(for: .milliseconds(100))
        }
        return found.withLock { $0 }
    }

    /// A long-lived browser that keeps the most recent TXT for `name`, so a test
    /// can watch the `pm` field flip as pairing mode toggles.
    private final class Watcher: @unchecked Sendable {
        private let name: String
        private let browser: NWBrowser
        private let latest = OSAllocatedUnfairLock<NWTXTRecord?>(initialState: nil)

        init(name: String) {
            self.name = name
            self.browser = NWBrowser(
                for: .bonjourWithTXTRecord(type: SyncListener.serviceType, domain: nil),
                using: NWParameters()
            )
            let latest = self.latest
            let wanted = name
            self.browser.browseResultsChangedHandler = { results, _ in
                for result in results {
                    guard case let .service(serviceName, _, _, _) = result.endpoint, serviceName == wanted else { continue }
                    if case let .bonjour(txt) = result.metadata {
                        latest.withLock { $0 = txt }
                    }
                }
            }
            self.browser.start(queue: .global())
        }

        func cancel() {
            self.browser.cancel()
        }

        /// Polls until the TXT `pm` field equals `expected`, or the deadline passes.
        func waitForPairingMode(_ expected: String, timeout: Duration) async throws -> Bool {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while ContinuousClock.now < deadline {
                if case let .string(pm) = self.latest.withLock({ $0 })?.getEntry(for: "pm"), pm == expected {
                    return true
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            return false
        }
    }

    @Test("pm TXT flips to 1 while pairing is armed and back to 0 when cancelled")
    func pairingModeFlips() async throws {
        let database = try await Database(location: .inMemory)
        let serverStore = KeychainIdentityStore(service: "io.cloudcauldron.bocan.sync.test.pm.\(UUID().uuidString)")
        defer { serverStore.deleteAll() }
        let serviceName = "BocanSyncPM-\(UUID().uuidString.prefix(8))"
        let server = SyncServer(
            database: database,
            identity: ServerIdentity(store: serverStore),
            ui: SilentBridge(),
            serverName: { serviceName }
        )
        try await server.start()
        defer { Task { await server.stop() } }

        let watcher = Watcher(name: serviceName)
        defer { watcher.cancel() }

        #expect(try await watcher.waitForPairingMode("0", timeout: .seconds(10)))
        await server.armPairing()
        #expect(try await watcher.waitForPairingMode("1", timeout: .seconds(10)))
        await server.cancelPairing()
        #expect(try await watcher.waitForPairingMode("0", timeout: .seconds(10)))
    }

    @Test("advertises the service so an NWBrowser can discover it with the fingerprint TXT")
    func discoverable() async throws {
        let store = KeychainIdentityStore(service: "io.cloudcauldron.bocan.sync.test.bonjour.\(UUID().uuidString)")
        defer { store.deleteAll() }
        let identity = ServerIdentity(store: store)
        let fingerprint = try await identity.fingerprint().hex

        let serviceName = "BocanSyncTest-\(UUID().uuidString.prefix(8))"
        let trusted = TrustedFingerprintSet()
        let router = Router(routes: [])
        let listener = SyncListener(
            identity: identity,
            router: router,
            trusted: trusted,
            pairingMode: { false },
            serviceName: { serviceName }
        )
        _ = try await listener.start(advertise: true)
        defer { Task { await listener.stop() } }

        let txt = try await self.discover(name: serviceName, timeout: .seconds(10))
        let resolved = try #require(txt, "the advertised service should be discoverable")
        #expect(self.string(resolved, "v") == "1")
        #expect(self.string(resolved, "fp") == fingerprint)
        #expect(self.string(resolved, "pm") == "0")
    }
}
