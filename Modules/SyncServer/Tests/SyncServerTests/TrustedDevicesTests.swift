import Foundation
import Persistence
import Testing
@testable import SyncServer

@Suite("TrustedDevices")
struct TrustedDevicesTests {
    private func sample(_ fingerprint: String, name: String = "Phone") -> TrustedDevice {
        TrustedDevice(fingerprint: fingerprint, certDER: Data([0x01]), deviceName: name, pairedAt: 0)
    }

    @Test("isTrusted reflects a device present before start")
    func seedsSnapshot() async throws {
        let db = try await Database(location: .inMemory)
        let repo = TrustedDeviceRepository(database: db)
        try await repo.upsert(self.sample("aa"))

        let trusted = TrustedDevices(repository: repo)
        try await trusted.start()

        #expect(trusted.fingerprints.contains("aa"))
        #expect(!trusted.fingerprints.contains("bb"))
        await trusted.stop()
    }

    @Test("trust and revoke update the snapshot immediately")
    func trustRevoke() async throws {
        let db = try await Database(location: .inMemory)
        let repo = TrustedDeviceRepository(database: db)
        let trusted = TrustedDevices(repository: repo)
        try await trusted.start()

        #expect(!trusted.fingerprints.contains("aa"))
        try await trusted.trust(self.sample("aa"))
        #expect(trusted.fingerprints.contains("aa"))
        try await trusted.revoke(fingerprint: "aa")
        #expect(!trusted.fingerprints.contains("aa"))
        await trusted.stop()
    }

    @Test("list returns the persisted devices")
    func listReturnsDevices() async throws {
        let db = try await Database(location: .inMemory)
        let repo = TrustedDeviceRepository(database: db)
        let trusted = TrustedDevices(repository: repo)
        try await trusted.start()
        try await trusted.trust(self.sample("aa", name: "Pixel"))

        let devices = try await trusted.list()
        #expect(devices.map(\.fingerprint) == ["aa"])
        #expect(devices.first?.deviceName == "Pixel")
        await trusted.stop()
    }

    @Test("an external revoke propagates to the snapshot via observation")
    func externalChangePropagates() async throws {
        let db = try await Database(location: .inMemory)
        let repo1 = TrustedDeviceRepository(database: db)
        let repo2 = TrustedDeviceRepository(database: db)
        try await repo1.upsert(self.sample("aa"))

        let trusted = TrustedDevices(repository: repo1)
        try await trusted.start()
        #expect(trusted.fingerprints.contains("aa"))

        // Revoke through a different repository handle: only the observation can
        // carry this into the in-memory snapshot.
        try await repo2.delete(fingerprint: "aa")
        try await self.pollUntil { !trusted.fingerprints.contains("aa") }
        await trusted.stop()
    }

    /// Polls `condition` until it holds or the timeout elapses, sleeping between
    /// checks rather than blocking on a fixed real-time wait.
    private func pollUntil(
        timeout: Duration = .seconds(2),
        _ condition: @Sendable () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition(), "condition not met before the timeout")
    }
}
