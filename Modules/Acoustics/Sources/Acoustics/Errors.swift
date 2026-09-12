import Foundation

/// Errors produced by the Acoustics module.
public enum AcousticsError: Error, Sendable, Equatable {
    public static func == (lhs: AcousticsError, rhs: AcousticsError) -> Bool {
        switch (lhs, rhs) {
        case let (.fpcalcFailed(lc, ls), .fpcalcFailed(rc, rs)): lc == rc && ls == rs
        case (.networkError, .networkError): true
        case (.rateLimitExceeded, .rateLimitExceeded): true
        case (.noResults, .noResults): true
        case let (.invalidResponse(l), .invalidResponse(r)): l == r
        case (.tagWritebackFailed, .tagWritebackFailed): true
        case let (.invalidInput(l), .invalidInput(r)): l == r
        default: false
        }
    }

    /// `fpcalc` exited with a non-zero status.
    case fpcalcFailed(exitCode: Int32, stderr: String)
    /// A network request failed.
    case networkError(underlying: Error)
    /// The API returned HTTP 429 or the local rate-limiter was saturated.
    case rateLimitExceeded
    /// The lookup returned no usable results.
    case noResults
    /// The server returned data that could not be parsed.
    case invalidResponse(reason: String)
    /// Applying the chosen candidate's tags to the file failed.
    case tagWritebackFailed(underlying: Error)
    /// The supplied URL or path is not valid for the requested operation.
    case invalidInput(reason: String)
}

// MARK: - AcousticsError + CustomStringConvertible

extension AcousticsError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .fpcalcFailed(exitCode, stderr):
            "Fingerprinting failed: fpcalc exited with status \(exitCode). \(stderr)"
        case let .networkError(underlying):
            "The fingerprint lookup could not reach the service: \(underlying.localizedDescription)"
        case .rateLimitExceeded:
            "The fingerprint service is rate limiting requests. Try again shortly."
        case .noResults:
            "No matching recording was found for this track."
        case let .invalidResponse(reason):
            "The fingerprint service returned data that could not be read: \(reason)"
        case let .tagWritebackFailed(underlying):
            "The chosen match could not be written to the file: \(underlying.localizedDescription)"
        case let .invalidInput(reason):
            "This item cannot be fingerprinted: \(reason)"
        }
    }
}

// MARK: - AcousticsError + LocalizedError

/// Without this, `localizedDescription` is Foundation's fallback, which reads
/// "(Acoustics.AcousticsError error 3.)" and tells the user nothing (#471).
extension AcousticsError: LocalizedError {
    public var errorDescription: String? {
        self.description
    }
}
