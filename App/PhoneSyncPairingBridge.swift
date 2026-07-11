import Foundation
import Observability
import SyncServer
import UI

/// Forwards the pairing ceremony (`PairingUIBridge`, driven by the
/// `PairingCoordinator`) to the UI view model (`PhoneSyncPairingReceiver`),
/// translating `PairingResult` into the UI's `PhoneSyncPairingOutcome`.
///
/// The `receiver` is assigned once at graph-build time, on the main actor,
/// before the server is ever started (breaking the `SyncServer` <-> view-model
/// construction cycle). `@unchecked Sendable` covers that one-time assignment.
final class PhoneSyncPairingBridge: PairingUIBridge, @unchecked Sendable {
    weak var receiver: (any PhoneSyncPairingReceiver)?

    func showCode(_ code: String) async {
        await self.receiver?.pairingPresentCode(code)
    }

    func requestConfirmation(deviceName: String, fingerprintTail: String) async -> Bool {
        await self.receiver?.pairingRequestConfirmation(
            deviceName: deviceName,
            fingerprintTail: fingerprintTail
        ) ?? false
    }

    func pairingEnded(result: PairingResult) async {
        await self.receiver?.pairingFinished(Self.outcome(from: result))
    }

    private static func outcome(from result: PairingResult) -> PhoneSyncPairingOutcome {
        switch result {
        case let .paired(deviceName):
            .paired(deviceName: deviceName)

        case .failed:
            .failed

        case .timedOut:
            .timedOut

        case .cancelled:
            .cancelled
        }
    }
}
