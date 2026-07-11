import Foundation
import Observability
import SyncServer

/// Placeholder pairing UI bridge for Phone Sync.
///
/// Phase 22-7 wires the `SyncServer` into the app lifecycle; the pairing sheet
/// that shows the six-digit code and asks the user to confirm a new device is
/// built in phase 22-8, which replaces this with a real bridge driven by the
/// Settings scene. Until then this logs the ceremony and **declines** every
/// trust request, so no device can be paired without the human-confirmation UI.
/// Phone Sync is off by default, so at rest this is never exercised.
final class PhoneSyncPairingBridge: PairingUIBridge, @unchecked Sendable {
    private let log = AppLogger.make(.sync)

    func showCode(_ code: String) async {
        self.log.debug("pairing.showCode", ["digits": String(code.count)])
    }

    func requestConfirmation(deviceName _: String, fingerprintTail _: String) async -> Bool {
        // No confirmation UI yet (phase 22-8); never auto-trust.
        self.log.warning("pairing.confirm.declined", ["reason": "no pairing UI until 22-8"])
        return false
    }

    func pairingEnded(result: PairingResult) async {
        self.log.debug("pairing.ended", ["result": String(reflecting: result)])
    }
}
