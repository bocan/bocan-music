import Foundation
import Persistence

// MARK: - UI-facing Phone Sync types

/// UI-local mirror of the sync profile selection (phase 22-5's `SyncProfile`).
/// Kept here so `UI` stays independent of the `SyncServer` module; the App
/// controller translates to and from the real `SyncProfile`.
public struct PhoneSyncProfile: Equatable, Sendable {
    public enum Mode: Sendable, Equatable {
        case everything
        case choosePlaylists
    }

    public var mode: Mode
    public var selectedPlaylistIDs: Set<Int64>
    public var includePodcasts: Bool

    public init(mode: Mode, selectedPlaylistIDs: Set<Int64> = [], includePodcasts: Bool = true) {
        self.mode = mode
        self.selectedPlaylistIDs = selectedPlaylistIDs
        self.includePodcasts = includePodcasts
    }

    public static let everything = Self(mode: .everything)
}

/// A playlist offered in the "Choose playlists" profile editor.
public struct PhoneSyncPlaylist: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let name: String

    public init(id: Int64, name: String) {
        self.id = id
        self.name = name
    }
}

/// The estimated on-disk cost of a sync profile (summed from the manifest the
/// profile would produce).
public struct PhoneSyncSizeEstimate: Equatable, Sendable {
    public let bytes: Int64
    public let trackCount: Int
    public let episodeCount: Int

    public init(bytes: Int64, trackCount: Int, episodeCount: Int) {
        self.bytes = bytes
        self.trackCount = trackCount
        self.episodeCount = episodeCount
    }

    public static let zero = Self(bytes: 0, trackCount: 0, episodeCount: 0)
}

/// The terminal result of a pairing ceremony, mirrored from `PairingResult` so
/// the sheet can show a clear outcome without importing `SyncServer`.
public enum PhoneSyncPairingOutcome: Equatable, Sendable {
    case paired(deviceName: String)
    case codeMismatch
    case timedOut
    case cancelled
    case failed
}

// MARK: - Seams

/// Server-control seam implemented by the App over `SyncServer` + repositories,
/// so `UI` does not depend on `SyncServer`. All operations are async; the view
/// model surfaces failures as inert (best-effort) rather than throwing into the
/// settings form.
public protocol PhoneSyncControlling: Sendable {
    /// The persisted enable toggle (default off).
    func isEnabled() -> Bool
    /// Persists the toggle and starts (true) or stops (false) the server.
    func setEnabled(_ enabled: Bool) async
    /// The persisted sync profile, or the default (everything, podcasts included).
    func loadProfile() async -> PhoneSyncProfile
    /// Persists the profile (which bumps the sync generation, per 22-5).
    func saveProfile(_ profile: PhoneSyncProfile) async
    /// Manual + smart + folder playlists offered in the profile editor.
    func availablePlaylists() async -> [PhoneSyncPlaylist]
    /// The on-disk cost of `profile`, summed from the manifest it would produce.
    func sizeEstimate(for profile: PhoneSyncProfile) async -> PhoneSyncSizeEstimate
    /// The currently paired phones, most recently paired first.
    func pairedDevices() async -> [TrustedDevice]
    /// Observes content-hash readiness (missing vs. total hashable tracks), so
    /// the pane can show how much of the library a paired phone can see.
    func observeHashingProgress() async -> AsyncThrowingStream<ContentHashProgress, Error>
    /// Revokes a paired phone; blocks it at the TLS layer on its next connect.
    func revoke(fingerprint: String) async
    /// Enters the pairing window (`pm` -> 1) for the coordinator's timeout.
    func armPairing() async
    /// Force-exits the pairing window (`pm` -> 0).
    func cancelPairing() async
}

/// The pairing-ceremony callbacks the App bridge (`PairingUIBridge`) forwards to
/// the view model. Declared in `UI` so the App can wire the ceremony to the
/// sheet without `UI` importing `SyncServer`.
public protocol PhoneSyncPairingReceiver: AnyObject, Sendable {
    /// Show the six-digit code the user types on the phone.
    func pairingPresentCode(_ code: String) async
    /// Await the mandatory human "Pair with '<device>'?" confirmation.
    func pairingRequestConfirmation(deviceName: String, fingerprintTail: String) async -> Bool
    /// The ceremony ended; show the outcome and let the sheet settle.
    func pairingFinished(_ outcome: PhoneSyncPairingOutcome) async
}
