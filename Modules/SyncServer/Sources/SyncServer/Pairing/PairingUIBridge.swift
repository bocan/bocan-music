import Foundation

/// The UI seam the pairing ceremony drives. Implemented by the settings pairing
/// sheet (phase 22-8); a test double drives the ceremony tests. This is the only
/// UI dependency the coordinator has.
public protocol PairingUIBridge: Sendable {
    /// Show the six-digit code on the Mac. Called when a phone starts pairing.
    func showCode(_ code: String) async

    /// The mandatory final confirmation (sync-protocol.md section 4 step 5):
    /// returns `true` only if the user clicks Trust. `fingerprintTail` is the last
    /// 8 hex chars of the phone certificate fingerprint, shown for verification.
    func requestConfirmation(deviceName: String, fingerprintTail: String) async -> Bool

    /// The ceremony ended (success, timeout, lockout, decline, or cancel); the
    /// sheet should dismiss or show the result.
    func pairingEnded(result: PairingResult) async
}
