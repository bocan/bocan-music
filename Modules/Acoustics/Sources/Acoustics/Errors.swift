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
}
