import Foundation
import os
import Persistence
import Testing
@testable import SyncServer

/// Test double for the pairing UI seam.
private final class TestPairingUIBridge: PairingUIBridge, @unchecked Sendable {
    private struct State {
        var shownCode: String?
        var confirmResult = true
        var confirmationRequested = false
        var endedResult: PairingResult?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var shownCode: String? {
        self.state.withLock { $0.shownCode }
    }

    var confirmationRequested: Bool {
        self.state.withLock { $0.confirmationRequested }
    }

    var endedResult: PairingResult? {
        self.state.withLock { $0.endedResult }
    }

    func setConfirmResult(_ value: Bool) {
        self.state.withLock { $0.confirmResult = value }
    }

    func showCode(_ code: String) async {
        self.state.withLock { $0.shownCode = code }
    }

    func requestConfirmation(deviceName _: String, fingerprintTail _: String) async -> Bool {
        self.state.withLock {
            $0.confirmationRequested = true
            return $0.confirmResult
        }
    }

    func pairingEnded(result: PairingResult) async {
        self.state.withLock { $0.endedResult = result }
    }
}

@Suite("PairingCoordinator")
struct PairingCoordinatorTests {
    private struct Harness {
        let coordinator: PairingCoordinator
        let ui: TestPairingUIBridge
        let trusted: TrustedDevices
        let serverFingerprint: String
        let clock: OSAllocatedUnfairLock<Date>
    }

    private func makeHarness(timeout: TimeInterval = 120) async throws -> Harness {
        let identity = try ServerIdentity(store: InMemoryIdentityStore())
        let serverFingerprint = try await identity.fingerprint().hex
        let database = try await Database(location: .inMemory)
        let trusted = TrustedDevices(repository: TrustedDeviceRepository(database: database))
        try await trusted.start()
        let ui = TestPairingUIBridge()
        let clock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1000))
        let coordinator = PairingCoordinator(
            identity: identity,
            trusted: trusted,
            ui: ui,
            serverName: { "Test Mac" },
            serverId: { "server-xyz" },
            timeout: timeout,
            now: { clock.withLock { $0 } }
        )
        return Harness(coordinator: coordinator, ui: ui, trusted: trusted, serverFingerprint: serverFingerprint, clock: clock)
    }

    private func randomNonce() -> Data {
        Data((0 ..< 32).map { _ in UInt8.random(in: .min ... .max) })
    }

    private func peerFingerprint(_ character: Character) -> String {
        String(repeating: character, count: 64)
    }

    /// Runs arm + start and returns the start response and the nonce used.
    private func armAndStart(
        _ harness: Harness,
        peer: String,
        deviceName: String = "Pixel"
    ) async throws -> (response: PairStartResponse, noncePhone: Data) {
        await harness.coordinator.arm()
        let noncePhone = self.randomNonce()
        let response = try await harness.coordinator.start(
            request: PairStart(protocolVersion: 1, deviceName: deviceName, noncePhone: noncePhone.base64EncodedString()),
            peerFingerprint: peer,
            peerCertDER: Data([0x01, 0x02])
        )
        return (response, noncePhone)
    }

    @Test("arm then start produces the golden pairing code and shows it")
    func startProducesCode() async throws {
        let harness = try await self.makeHarness()
        let peer = self.peerFingerprint("a")
        let (response, noncePhone) = try await self.armAndStart(harness, peer: peer)

        let nonceMac = try #require(Data(base64Encoded: response.nonceMac))
        let expectedCode = PairingCode.code(
            fpMac: harness.serverFingerprint,
            fpPhone: peer,
            noncePhone: noncePhone,
            nonceMac: nonceMac
        )
        #expect(harness.ui.shownCode == expectedCode)
        #expect(response.serverName == "Test Mac")
        #expect(await harness.coordinator.isPairingMode)
    }

    @Test("a correct proof plus Trust pairs the device and ends pairing mode")
    func confirmSucceeds() async throws {
        let harness = try await self.makeHarness()
        let peer = self.peerFingerprint("b")
        let (response, _) = try await self.armAndStart(harness, peer: peer)
        let code = try #require(harness.ui.shownCode)

        let proof = PairingCode.proof(code: code, sessionId: response.sessionId)
        let confirm = try await harness.coordinator.confirm(
            request: PairConfirm(sessionId: response.sessionId, proof: proof)
        )

        #expect(confirm.status == "paired")
        #expect(confirm.serverId == "server-xyz")
        #expect(harness.trusted.fingerprints.contains(peer))
        #expect(await harness.coordinator.isPairingMode == false)
        #expect(harness.ui.endedResult == .paired(deviceName: "Pixel"))
    }

    @Test("three bad proofs lock out the session and revert pairing mode")
    func lockoutAfterThreeBadProofs() async throws {
        let harness = try await self.makeHarness()
        let peer = self.peerFingerprint("c")
        let (response, _) = try await self.armAndStart(harness, peer: peer)

        for _ in 0 ..< 2 {
            await #expect(throws: PairingError.badProof) {
                _ = try await harness.coordinator.confirm(
                    request: PairConfirm(sessionId: response.sessionId, proof: "AAAA")
                )
            }
        }
        await #expect(throws: PairingError.rateLimited) {
            _ = try await harness.coordinator.confirm(
                request: PairConfirm(sessionId: response.sessionId, proof: "AAAA")
            )
        }
        #expect(await harness.coordinator.isPairingMode == false)
        #expect(harness.trusted.fingerprints.contains(peer) == false)
        #expect(harness.ui.endedResult == .failed)
    }

    @Test("declining the human confirmation does not trust the device")
    func declineConfirmation() async throws {
        let harness = try await self.makeHarness()
        harness.ui.setConfirmResult(false)
        let peer = self.peerFingerprint("e")
        let (response, _) = try await self.armAndStart(harness, peer: peer)
        let code = try #require(harness.ui.shownCode)

        let proof = PairingCode.proof(code: code, sessionId: response.sessionId)
        await #expect(throws: PairingError.badProof) {
            _ = try await harness.coordinator.confirm(
                request: PairConfirm(sessionId: response.sessionId, proof: proof)
            )
        }
        #expect(harness.ui.confirmationRequested)
        #expect(harness.trusted.fingerprints.contains(peer) == false)
        #expect(await harness.coordinator.isPairingMode == false)
    }

    @Test("start after the deadline is rejected and reverts pairing mode")
    func deadlineElapsed() async throws {
        let harness = try await self.makeHarness()
        await harness.coordinator.arm()
        // Advance the injected clock past the 120 s window.
        harness.clock.withLock { $0 = $0.addingTimeInterval(121) }

        await #expect(throws: PairingError.expired) {
            _ = try await harness.coordinator.start(
                request: PairStart(protocolVersion: 1, deviceName: "Pixel", noncePhone: self.randomNonce().base64EncodedString()),
                peerFingerprint: self.peerFingerprint("f"),
                peerCertDER: Data([0x01])
            )
        }
        #expect(await harness.coordinator.isPairingMode == false)
    }

    @Test("start without arming is rejected")
    func startWhenNotArmed() async throws {
        let harness = try await self.makeHarness()
        await #expect(throws: PairingError.expired) {
            _ = try await harness.coordinator.start(
                request: PairStart(protocolVersion: 1, deviceName: "Pixel", noncePhone: self.randomNonce().base64EncodedString()),
                peerFingerprint: self.peerFingerprint("g"),
                peerCertDER: Data([0x01])
            )
        }
        #expect(await harness.coordinator.isPairingMode == false)
    }

    @Test("the real-time backstop reverts pairing mode when no request arrives")
    func backstopTimeout() async throws {
        let harness = try await self.makeHarness(timeout: 0.2)
        await harness.coordinator.arm()
        #expect(await harness.coordinator.isPairingMode)
        // Advance the injected clock past the deadline so the real-time backstop
        // task, which fires after 0.2 s, sees the window as expired.
        harness.clock.withLock { $0 = $0.addingTimeInterval(1) }

        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline, harness.coordinator.pairingMode.isOn {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(harness.coordinator.pairingMode.isOn == false)
        #expect(harness.ui.endedResult == .timedOut)
    }
}
