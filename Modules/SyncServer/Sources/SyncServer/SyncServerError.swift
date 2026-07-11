import Foundation

/// The single error type for the `SyncServer` module. Cases carry context (never
/// bare) and grow as later phase-22 slices add identity, listener, pairing,
/// manifest, and file-serving failure modes.
public enum SyncServerError: Error, Sendable {
    /// A pairing-ceremony step failed. `reason` is a short, non-sensitive token
    /// describing which invariant was violated (never a code, nonce, or proof).
    case pairing(reason: String)
}
