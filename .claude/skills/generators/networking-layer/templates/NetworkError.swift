import Foundation

/// Errors that can occur during network requests.
///
/// Use these typed errors for better error handling and user messaging.
enum NetworkError: Error, LocalizedError {
    /// The URL could not be constructed.
    case invalidURL

    /// The response was not an HTTP response.
    case invalidResponse

    /// No data was received.
    case noData

    /// Failed to decode the response.
    case decodingFailed(Error)

    /// HTTP error with status code.
    case httpError(statusCode: Int, data: Data?)

    /// Network is unavailable.
    case networkUnavailable

    /// Request timed out.
    case timeout

    /// Authentication required (401).
    case unauthorized

    /// Access forbidden (403).
    case forbidden

    /// Resource not found (404).
    case notFound

    /// Server error (5xx).
    case serverError(String)

    /// Request was cancelled.
    case cancelled

    // MARK: - LocalizedError

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Invalid URL"
        case .invalidResponse:
            "Invalid response from server"
        case .noData:
            "No data received"
        case let .decodingFailed(error):
            "Failed to decode response: \(error.localizedDescription)"
        case let .httpError(code, _):
            "Request failed with status \(code)"
        case .networkUnavailable:
            "Network unavailable. Please check your connection."
        case .timeout:
            "Request timed out. Please try again."
        case .unauthorized:
            "Please sign in to continue"
        case .forbidden:
            "You don't have permission to access this"
        case .notFound:
            "The requested resource was not found"
        case let .serverError(message):
            "Server error: \(message)"
        case .cancelled:
            "Request was cancelled"
        }
    }

    /// A user-friendly message for display in UI.
    var userMessage: String {
        switch self {
        case .networkUnavailable:
            "No internet connection. Please check your network settings."
        case .timeout:
            "The request took too long. Please try again."
        case .unauthorized:
            "Your session has expired. Please sign in again."
        case .serverError:
            "Something went wrong on our end. Please try again later."
        default:
            self.errorDescription ?? "An unexpected error occurred"
        }
    }

    /// Whether the error is retryable.
    var isRetryable: Bool {
        switch self {
        case .timeout, .networkUnavailable, .serverError:
            true
        case let .httpError(code, _):
            [408, 429, 500, 502, 503, 504].contains(code)
        default:
            false
        }
    }
}

// MARK: - Equatable (for testing)

extension NetworkError: Equatable {
    static func == (lhs: NetworkError, rhs: NetworkError) -> Bool {
        switch (lhs, rhs) {
        case (.invalidURL, .invalidURL),
             (.invalidResponse, .invalidResponse),
             (.noData, .noData),
             (.networkUnavailable, .networkUnavailable),
             (.timeout, .timeout),
             (.unauthorized, .unauthorized),
             (.forbidden, .forbidden),
             (.notFound, .notFound),
             (.cancelled, .cancelled):
            true
        case let (.httpError(lhsCode, _), .httpError(rhsCode, _)):
            lhsCode == rhsCode
        case let (.serverError(lhsMsg), .serverError(rhsMsg)):
            lhsMsg == rhsMsg
        case (.decodingFailed, .decodingFailed):
            true // Don't compare underlying errors
        default:
            false
        }
    }
}
