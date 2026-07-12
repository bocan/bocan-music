import Combine
import Foundation
import Observability
import Persistence
import SwiftUI

// MARK: - PairingSheetState

/// The four states of the pairing sheet (sync-protocol.md section 4).
public enum PairingSheetState: Equatable, Sendable {
    /// Armed and waiting for the phone to connect.
    case waiting
    /// Showing the six-digit code the user types on the phone.
    case code(String)
    /// The mandatory human confirmation before trusting the device.
    case confirm(deviceName: String, fingerprintTail: String)
    /// The ceremony finished; showing the outcome.
    case result(PhoneSyncPairingOutcome)
}

// MARK: - PhoneSyncViewModel

/// State-store for Settings -> Phone Sync (phase 22-8). Wraps the
/// `PhoneSyncControlling` seam (implemented by the App over `SyncServer`) and
/// is itself the pairing-ceremony receiver, driving the sheet through its
/// states. All mutation is async and best-effort.
@MainActor
public final class PhoneSyncViewModel: ObservableObject, PhoneSyncPairingReceiver {
    // MARK: - Published state

    @Published public private(set) var enabled = false
    @Published public private(set) var profile: PhoneSyncProfile = .everything
    @Published public private(set) var playlists: [PhoneSyncPlaylist] = []
    @Published public private(set) var sizeEstimate: PhoneSyncSizeEstimate = .zero
    @Published public private(set) var pairedDevices: [TrustedDevice] = []
    /// Content-hash readiness for the "Ready to sync" row, `nil` until the
    /// observation's first emission. `internal(set)` so snapshot tests can pin
    /// a state directly.
    @Published public internal(set) var hashingProgress: ContentHashProgress?
    /// The pairing sheet's current state, or `nil` when not presented.
    /// `internal(set)` so snapshot tests can pin a state directly.
    @Published public internal(set) var pairingSheet: PairingSheetState?

    // MARK: - Dependencies

    private let control: any PhoneSyncControlling
    private let log = AppLogger.make(.ui)
    private var confirmationContinuation: CheckedContinuation<Bool, Never>?

    public init(control: any PhoneSyncControlling) {
        self.control = control
    }

    // MARK: - Loading

    /// Loads the toggle, profile, playlist choices, size estimate, and paired
    /// devices. Call from the view's `.task`.
    public func load() async {
        self.enabled = self.control.isEnabled()
        self.profile = await self.control.loadProfile()
        self.playlists = await self.control.availablePlaylists()
        self.pairedDevices = await self.control.pairedDevices()
        await self.recomputeEstimate()
    }

    /// Refreshes the paired-devices list (after a revoke or a successful pair).
    public func refreshDevices() async {
        self.pairedDevices = await self.control.pairedDevices()
    }

    /// Follows the content-hash backfill so the pane's readiness row counts up
    /// live. Call from the view's `.task` after `load()`; it runs until that
    /// task is cancelled (the stream ends without throwing on cancellation).
    public func watchHashingProgress() async {
        let stream = await self.control.observeHashingProgress()
        do {
            for try await progress in stream {
                self.hashingProgress = progress
            }
        } catch {
            self.log.warning("sync.hash_progress.observe.failed", ["error": String(reflecting: error)])
        }
    }

    // MARK: - Enable toggle

    public func setEnabled(_ enabled: Bool) async {
        self.enabled = enabled
        await self.control.setEnabled(enabled)
    }

    // MARK: - Profile editing

    public func setMode(_ mode: PhoneSyncProfile.Mode) async {
        self.profile.mode = mode
        await self.persistProfile()
    }

    public func setIncludePodcasts(_ include: Bool) async {
        self.profile.includePodcasts = include
        await self.persistProfile()
    }

    public func togglePlaylist(_ id: Int64) async {
        await self.setPlaylistSelected(id, !self.isPlaylistSelected(id))
    }

    /// Idempotent form backing the checkbox binding: setting an already-set
    /// state persists nothing new but stays correct if SwiftUI re-fires it.
    public func setPlaylistSelected(_ id: Int64, _ selected: Bool) async {
        if selected {
            self.profile.selectedPlaylistIDs.insert(id)
        } else {
            self.profile.selectedPlaylistIDs.remove(id)
        }
        await self.persistProfile()
    }

    public func isPlaylistSelected(_ id: Int64) -> Bool {
        self.profile.selectedPlaylistIDs.contains(id)
    }

    private func persistProfile() async {
        await self.control.saveProfile(self.profile)
        await self.recomputeEstimate()
    }

    private func recomputeEstimate() async {
        self.sizeEstimate = await self.control.sizeEstimate(for: self.profile)
    }

    // MARK: - Paired devices

    public func revoke(_ device: TrustedDevice) async {
        await self.control.revoke(fingerprint: device.fingerprint)
        await self.refreshDevices()
    }

    // MARK: - Pairing ceremony

    /// "Pair a phone": arm pairing and present the sheet in its waiting state.
    public func startPairing() async {
        self.pairingSheet = .waiting
        await self.control.armPairing()
    }

    /// Resolve the human confirmation step (Trust / Cancel).
    public func confirmTrust(_ trust: Bool) {
        let continuation = self.confirmationContinuation
        self.confirmationContinuation = nil
        continuation?.resume(returning: trust)
    }

    /// Dismiss the sheet: resolve any pending confirmation as declined, cancel
    /// the pairing window, and refresh the device list.
    public func dismissPairing() async {
        self.confirmTrust(false)
        await self.control.cancelPairing()
        self.pairingSheet = nil
        await self.refreshDevices()
    }

    // MARK: - PhoneSyncPairingReceiver

    public func pairingPresentCode(_ code: String) async {
        self.pairingSheet = .code(code)
    }

    public func pairingRequestConfirmation(deviceName: String, fingerprintTail: String) async -> Bool {
        self.pairingSheet = .confirm(deviceName: deviceName, fingerprintTail: fingerprintTail)
        return await withCheckedContinuation { continuation in
            self.confirmationContinuation = continuation
        }
    }

    public func pairingFinished(_ outcome: PhoneSyncPairingOutcome) async {
        self.confirmTrust(false)
        self.pairingSheet = .result(outcome)
        await self.refreshDevices()
    }
}
