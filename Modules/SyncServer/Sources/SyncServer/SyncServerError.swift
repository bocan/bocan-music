import Foundation

/// The single error type for the `SyncServer` module. Cases carry context (never
/// bare) and grow as later ADR-060 slices add identity, listener, pairing,
/// manifest, and file-serving failure modes.
public enum SyncServerError: Error, Sendable {
    /// A pairing-ceremony step failed. `reason` is a short, non-sensitive token
    /// describing which invariant was violated (never a code, nonce, or proof).
    case pairing(reason: String)

    /// Creating, loading, or storing the server's TLS identity failed. `reason`
    /// is a short token; `status` is the underlying `OSStatus` when a Keychain or
    /// Security call failed, else `nil`.
    case identity(reason: String, status: Int32?)

    /// The transcode coordinator could not reach a track's source file: the
    /// stored file URL was unparsable and no bookmark exists (ADR-088).
    case transcodeSourceUnavailable(trackID: Int64)
}

// MARK: - SyncServerError + CustomStringConvertible

/// `reason` is a short non-sensitive token by the contract on the cases above,
/// so it is safe to show. Nothing here widens that: no code, nonce or proof.
extension SyncServerError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .pairing(reason):
            "Pairing failed: \(reason)"
        case let .identity(reason, status):
            if let status {
                "The sync server's identity could not be prepared: \(reason) (status \(status))"
            } else {
                "The sync server's identity could not be prepared: \(reason)"
            }
        case let .transcodeSourceUnavailable(trackID):
            "The source file for track \(trackID) could not be found."
        }
    }
}

// MARK: - SyncServerError + LocalizedError

/// Without this, `localizedDescription` is Foundation's fallback, which reads
/// "(SyncServer.SyncServerError error 3.)" and tells the user nothing (#471).
extension SyncServerError: LocalizedError {
    public var errorDescription: String? {
        self.description
    }
}
