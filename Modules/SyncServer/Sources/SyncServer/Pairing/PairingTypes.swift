import Foundation

// MARK: - Wire DTOs (sync-protocol.md section 4)

/// `POST /v1/pair/start` request body.
struct PairStart: Codable {
    let protocolVersion: Int
    let deviceName: String
    let noncePhone: String // base64, 32 bytes
}

/// `POST /v1/pair/start` response body.
struct PairStartResponse: Codable {
    let protocolVersion: Int
    let serverName: String
    let nonceMac: String // base64, 32 bytes
    let sessionId: String
}

/// `POST /v1/pair/confirm` request body.
struct PairConfirm: Codable {
    let sessionId: String
    let proof: String // base64 HMAC
}

/// `POST /v1/pair/confirm` response body.
struct PairConfirmResponse: Codable {
    let status: String
    let serverId: String
}

// MARK: - Outcomes

/// The terminal outcome of a pairing attempt, reported to the UI so it can
/// dismiss or update the sheet.
public enum PairingResult: Sendable, Equatable {
    case paired(deviceName: String)
    case failed
    case timedOut
    case cancelled
}

/// A pairing-ceremony failure, mapped to an HTTP status + machine code by the
/// route handlers.
enum PairingError: Error, Equatable {
    /// No active pairing session (never armed, wrong session id, or expired).
    case expired
    /// The confirm proof did not match.
    case badProof
    /// Too many bad proofs; the session is locked out.
    case rateLimited
    /// The request body was malformed or violated the protocol.
    case badRequest
}

// MARK: - In-flight session

/// One in-flight pairing ceremony. Held by the `PairingCoordinator` between
/// `start` and `confirm`.
struct PairingSession {
    let sessionId: String
    let noncePhone: Data
    let nonceMac: Data
    let fpPhone: String
    let peerCertDER: Data
    let deviceName: String
    let code: String
    let deadline: Date
    var failedProofs: Int
}
