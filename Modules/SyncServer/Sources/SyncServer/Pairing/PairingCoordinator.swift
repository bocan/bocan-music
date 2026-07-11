import Foundation
import Observability
import os
import Persistence
import Security

/// A thread-safe, synchronously-readable pairing-mode flag. The TLS verify block
/// reads it per handshake to decide whether to admit an unknown client cert; the
/// Bonjour advertiser reflects it in the TXT `pm` field.
public final class PairingModeFlag: Sendable {
    private let value = OSAllocatedUnfairLock(initialState: false)

    public init() {}

    public var isOn: Bool {
        self.value.withLock { $0 }
    }

    func set(_ on: Bool) {
        self.value.withLock { $0 = on }
    }
}

/// Server side of the pairing ceremony (sync-protocol.md section 4). Owns at most
/// one in-flight session, the pairing-mode window, the 3-strike lockout, and the
/// `pm` flag hygiene: pairing mode reverts to off on every exit path.
public actor PairingCoordinator {
    /// The synchronously-readable pairing-mode flag for the TLS verify block.
    public nonisolated let pairingMode = PairingModeFlag()

    private let identity: ServerIdentity
    private let trusted: TrustedDevices
    private let ui: any PairingUIBridge
    private let serverName: @Sendable () -> String
    private let serverId: @Sendable () async -> String
    private let now: @Sendable () -> Date
    private let timeout: TimeInterval
    private let log = AppLogger.make(.sync)

    private var armedDeadline: Date?
    private var session: PairingSession?
    private var deadlineTask: Task<Void, Never>?
    private var pairingModeObserver: (@Sendable (Bool) -> Void)?

    public init(
        identity: ServerIdentity,
        trusted: TrustedDevices,
        ui: any PairingUIBridge,
        serverName: @escaping @Sendable () -> String,
        serverId: @escaping @Sendable () async -> String,
        timeout: TimeInterval = 120,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.identity = identity
        self.trusted = trusted
        self.ui = ui
        self.serverName = serverName
        self.serverId = serverId
        self.timeout = timeout
        self.now = now
    }

    /// Whether the server is currently in a pairing window.
    public var isPairingMode: Bool {
        self.armedDeadline != nil
    }

    /// Registers an observer notified whenever pairing mode toggles (phase 22-7
    /// updates the Bonjour TXT record from it). Fires immediately with the
    /// current state.
    public func observePairingMode(_ observer: @escaping @Sendable (Bool) -> Void) {
        self.pairingModeObserver = observer
        observer(self.pairingMode.isOn)
    }

    /// The user clicked "Pair a phone": enter pairing mode for `timeout` seconds.
    public func arm() {
        self.resetState()
        let deadline = self.now().addingTimeInterval(self.timeout)
        self.armedDeadline = deadline
        self.setPairingMode(true)
        self.scheduleDeadline()
    }

    /// Force-exit the ceremony (settings toggle off, app teardown).
    public func cancel() async {
        guard self.isPairingMode else { return }
        await self.finish(.cancelled)
    }

    // MARK: - Endpoints

    /// `POST /v1/pair/start`. `peerFingerprint` / `peerCertDER` come from the TLS
    /// layer, never the JSON body.
    func start(
        request: PairStart,
        peerFingerprint: String,
        peerCertDER: Data
    ) async throws -> PairStartResponse {
        guard let deadline = self.armedDeadline else {
            throw PairingError.expired
        }
        guard self.now() < deadline else {
            await self.finish(.timedOut)
            throw PairingError.expired
        }
        guard request.protocolVersion == 1 else {
            throw PairingError.badRequest
        }
        guard let noncePhone = Data(base64Encoded: request.noncePhone), noncePhone.count == 32 else {
            throw PairingError.badRequest
        }

        let nonceMac = Self.randomNonce()
        let sessionId = UUID().uuidString
        let fpMac = try await self.identity.fingerprint().hex
        let code = PairingCode.code(
            fpMac: fpMac,
            fpPhone: peerFingerprint,
            noncePhone: noncePhone,
            nonceMac: nonceMac
        )

        self.session = PairingSession(
            sessionId: sessionId,
            noncePhone: noncePhone,
            nonceMac: nonceMac,
            fpPhone: peerFingerprint,
            peerCertDER: peerCertDER,
            deviceName: request.deviceName,
            code: code,
            deadline: deadline,
            failedProofs: 0
        )
        await self.ui.showCode(code)

        return PairStartResponse(
            protocolVersion: 1,
            serverName: self.serverName(),
            nonceMac: nonceMac.base64EncodedString(),
            sessionId: sessionId
        )
    }

    /// `POST /v1/pair/confirm`. Verifies the proof, then requires the mandatory
    /// human confirmation before trusting the device.
    func confirm(request: PairConfirm) async throws -> PairConfirmResponse {
        guard var session = self.session, self.armedDeadline != nil else {
            throw PairingError.expired
        }
        guard session.sessionId == request.sessionId else {
            throw PairingError.expired
        }
        guard self.now() < session.deadline else {
            await self.finish(.timedOut)
            throw PairingError.expired
        }

        let expected = PairingCode.proof(code: session.code, sessionId: session.sessionId)
        guard
            let provided = Data(base64Encoded: request.proof),
            let expectedData = Data(base64Encoded: expected),
            Self.constantTimeEqual(provided, expectedData) else {
            session.failedProofs += 1
            if session.failedProofs >= 3 {
                await self.finish(.failed)
                throw PairingError.rateLimited
            }
            self.session = session
            throw PairingError.badProof
        }

        // Mandatory human confirmation (never removed; see the protocol doc).
        let tail = String(session.fpPhone.suffix(8))
        let trust = await self.ui.requestConfirmation(deviceName: session.deviceName, fingerprintTail: tail)
        guard trust else {
            await self.finish(.failed)
            throw PairingError.badProof
        }

        let device = TrustedDevice(
            fingerprint: session.fpPhone,
            certDER: session.peerCertDER,
            deviceName: session.deviceName,
            pairedAt: self.now().timeIntervalSince1970
        )
        try await self.trusted.trust(device)
        let serverId = await self.serverId()
        let deviceName = session.deviceName
        await self.finish(.paired(deviceName: deviceName))
        self.log.debug("pairing.confirmed")
        return PairConfirmResponse(status: "paired", serverId: serverId)
    }

    // MARK: - Lifecycle helpers

    /// Clears pairing state and reverts `pm` to off, then reports the terminal
    /// `result` to the UI.
    private func finish(_ result: PairingResult) async {
        self.resetState()
        await self.ui.pairingEnded(result: result)
    }

    private func resetState() {
        self.armedDeadline = nil
        self.session = nil
        self.deadlineTask?.cancel()
        self.deadlineTask = nil
        self.setPairingMode(false)
    }

    private func setPairingMode(_ on: Bool) {
        self.pairingMode.set(on)
        self.pairingModeObserver?(on)
    }

    /// Real-time backstop: after `timeout`, revert `pm` even if no request ever
    /// arrived (so the Mac stops advertising pairing mode). Handler-entry `now()`
    /// checks cover the request paths; this covers the no-request path.
    private func scheduleDeadline() {
        let timeout = self.timeout
        self.deadlineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            await self?.deadlineFired()
        }
    }

    private func deadlineFired() async {
        guard let deadline = self.armedDeadline, self.now() >= deadline else { return }
        await self.finish(.timedOut)
    }

    private static func randomNonce() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }
}
